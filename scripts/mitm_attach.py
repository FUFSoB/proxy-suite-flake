"""mitmproxy addon: the flows mitmproxy reads, handed as they come to programs attached on a
Unix socket (`proxy-ctl mitm attach`, mitm.attach): HTTP requests and answers, WebSocket,
TCP and UDP messages, each when its hook runs.

An attached program is a mitmdump, mitmproxy or mitmweb of its user's own, with the
client addon (mitm_attach_client.py) and that user's addons: they see the flows as this
mitmproxy's own addons do, live. One that only reads gets copies and holds nothing up. One
that changes traffic (modify) is asked in turn, after this mitmproxy's own addons, and what it
answers is what is sent on: a request or answer changed or made, a message changed or (a
WebSocket one) dropped, a flow killed. An answer that is late (attach_timeout, or what
the program asked for) lets the flow go on unchanged and detaches the program; so does one
that falls behind by more than ATTACH_BACKLOG of copies.

Options, set in config.yaml by the module or with --set:
  attach_socket       the socket's path; empty, none is made
  attach_timeout      seconds a program that changes traffic has to answer each hook
  attach_group_access the socket 0660, for its directory's group; else 0600

The wire, both ways: tnetstrings (mitmproxy.io.tnetstring), one dict each.
  program -> {"hello": PROTOCOL, "flow_format": N, "version": "12.3.1", "modify": bool,
              "timeout": seconds or 0, "filter": "a mitmproxy filter expression" or ""}
  service -> {"welcome": PROTOCOL, "flow_format": N, "version": "...", "timeout": seconds}
             or {"refused": "why"}
  service -> {"n": N, "event": hook name, "id": flow id, "flow": flow state} for the flow
             hooks, its messages left out; {"n", "event", "id", "message": state} for
             *_message, the message just read. A program that comes in partway through a
             flow is sent its *_start first.
  program -> {"n": N, ...} for each event, when it changes traffic: "request", "response"
             (states), "content" (bytes), "drop", "kill", "marked", "comment", each only
             if it changed.
"""

import asyncio
import contextlib
import itertools
import logging
import os
import socket
import stat
import struct

from mitmproxy import ctx, flowfilter, http, version
from mitmproxy.io import tnetstring

PROTOCOL = 1
# The largest frame either side reads: a whole request or answer, bodies included.
MAX_FRAME = 1 << 30
# A program's first frame, its hello.
MAX_HELLO = 1 << 16
# Copies queued for a program that only reads, before it counts as fallen behind.
ATTACH_BACKLOG = 64 << 20

# The hooks handed on, by kind of flow.
HTTP_EVENTS = ("request", "response", "error")
MESSAGE_EVENTS = ("websocket_message", "tcp_message", "udp_message")
# What a program that missed a flow's start is sent first.
START_OF = {
    "websocket_message": "websocket_start",
    "websocket_end": "websocket_start",
    "tcp_message": "tcp_start",
    "tcp_end": "tcp_start",
    "tcp_error": "tcp_start",
    "udp_message": "udp_start",
    "udp_end": "udp_start",
    "udp_error": "udp_start",
}

log = logging.getLogger(__name__)


def encode(value):
    return tnetstring.dumps(value)


async def read_frame(reader, limit):
    """One tnetstring off the stream, at most `limit` bytes of payload."""
    head = await reader.readuntil(b":")
    if len(head) > 11 or not head[:-1].isdigit():
        raise ValueError("not a tnetstring")
    size = int(head[:-1])
    if size > limit:
        raise ValueError(f"a frame of {size} bytes, more than {limit}")
    rest = await reader.readexactly(size + 1)
    return tnetstring.loads(head + rest)


def portable(metadata):
    """What of a flow's metadata goes over the wire: an addon may keep anything there."""
    kept = {}
    for key, value in metadata.items():
        try:
            encode({key: value})
        except (TypeError, ValueError):
            continue
        kept[key] = value
    return kept


def flow_state(flow):
    """The flow's state, without its messages (they go one by one) or its backup."""
    state = flow.get_state()
    state["backup"] = None
    state["metadata"] = portable(state.get("metadata") or {})
    if "messages" in state:
        state["messages"] = []
    if state.get("websocket"):
        state["websocket"]["messages"] = []
    return state


def last_message(flow):
    if isinstance(flow, http.HTTPFlow):
        return flow.websocket.messages[-1]
    return flow.messages[-1]


def ends(event, flow):
    """Whether this hook is the flow's last."""
    if event == "response":
        return flow.websocket is None
    return event in ("error", "websocket_end", "tcp_end", "tcp_error", "udp_end", "udp_error")


def apply(event, flow, reply):
    """What a program that changes traffic answered, onto the flow itself."""
    if reply.get("kill"):
        if flow.killable:
            flow.kill()
        return
    if isinstance(reply.get("marked"), str):
        flow.marked = reply["marked"]
    if isinstance(reply.get("comment"), str):
        flow.comment = reply["comment"]
    if event == "request" and isinstance(reply.get("request"), dict):
        flow.request = http.Request.from_state(reply["request"])
    if event in ("request", "response") and isinstance(reply.get("response"), dict):
        flow.response = http.Response.from_state(reply["response"])
    if event in MESSAGE_EVENTS:
        message = last_message(flow)
        if isinstance(reply.get("content"), bytes):
            message.content = reply["content"]
        if reply.get("drop") and hasattr(message, "drop"):
            message.drop()


def peer_credentials(writer):
    """(pid, uid) of the program on the other end, for the log."""
    sock = writer.get_extra_info("socket")
    try:
        pid, uid, _ = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    except (OSError, AttributeError, struct.error):
        return None, None
    return pid, uid


class Refused(Exception):
    pass


class Peer:
    """One attached program."""

    def __init__(self, reader, writer, hello, default_timeout):
        self.reader, self.writer = reader, writer
        self.pid, self.uid = peer_credentials(writer)
        self.modify = bool(hello.get("modify"))
        timeout = hello.get("timeout")
        self.timeout = float(timeout) if isinstance(timeout, (int, float)) and timeout > 0 else default_timeout
        expression = hello.get("filter") or ""
        if not isinstance(expression, str):
            raise Refused("the filter is not a string")
        try:
            self.filter = flowfilter.parse(expression) if expression else None
        except ValueError as e:
            raise Refused(f"not a filter expression: {expression} ({e})") from e
        self.expression = expression
        self.pending = {}
        # Flows it was sent the start of, and those its filter took.
        self.seen = set()
        self.taken = {}
        self.closed = False

    def __str__(self):
        who = f"uid {self.uid} pid {self.pid}" if self.pid is not None else "a program"
        mode = "changing traffic" if self.modify else "reading"
        return f"{who} ({mode}{', ' + self.expression if self.expression else ''})"

    def wants(self, flow, event):
        """Its filter, from the flow's first hook that matches: messages ask no more."""
        taken = self.taken.get(flow.id)
        if taken or (taken is not None and event in MESSAGE_EVENTS):
            return taken
        try:
            taken = self.filter is None or bool(self.filter(flow))
        except Exception:  # noqa: BLE001 - a filter that cannot judge this flow takes none of it
            taken = False
        self.taken[flow.id] = taken
        return taken

    def forget(self, flow_id):
        self.seen.discard(flow_id)
        self.taken.pop(flow_id, None)

    def send(self, data):
        if self.closed:
            return
        self.writer.write(data)
        transport = self.writer.transport
        if not self.modify and transport is not None and transport.get_write_buffer_size() > ATTACH_BACKLOG:
            log.warning(f"attach: {self} fell behind by more than {ATTACH_BACKLOG >> 20} MiB: detached")
            self.close()

    async def ask(self, payload):
        """Its answer to the hook, or None: traffic goes on unchanged without one."""
        if self.closed:
            return None
        future = asyncio.get_running_loop().create_future()
        self.pending[payload["n"]] = future
        self.send(encode(payload))
        try:
            return await asyncio.wait_for(future, self.timeout)
        except TimeoutError:
            log.warning(
                f"attach: {self} did not answer {payload['event']} within {self.timeout:g}s:"
                " detached, and the flow goes on unchanged"
            )
            self.close()
            return None
        finally:
            self.pending.pop(payload["n"], None)

    async def serve(self):
        """Its answers, until it goes."""
        while not self.closed:
            try:
                frame = await read_frame(self.reader, MAX_FRAME)
            except (asyncio.IncompleteReadError, ConnectionError, asyncio.LimitOverrunError):
                break
            except ValueError as e:
                log.warning(f"attach: {self} sent what is not an answer ({e}): detached")
                break
            if not isinstance(frame, dict):
                continue
            future = self.pending.get(frame.get("n"))
            if future is not None and not future.done():
                future.set_result(frame)

    def close(self):
        if self.closed:
            return
        self.closed = True
        for future in self.pending.values():
            if not future.done():
                future.set_result(None)
        self.writer.close()


class Attach:
    def __init__(self):
        self.server = None
        self.path = None
        self.peers = []
        self.counter = itertools.count(1)

    def load(self, loader):
        loader.add_option(
            "attach_socket", str, "", "Unix socket programs attach to, to read and change the flows; empty, none."
        )
        loader.add_option(
            "attach_timeout",
            float,
            5.0,
            "Seconds a program attached to change traffic has to answer each hook; then it is detached.",
        )
        loader.add_option(
            "attach_group_access", bool, False, "Make the socket 0660, for its directory's group; else 0600."
        )

    async def running(self):
        path = ctx.options.attach_socket
        if not path:
            return
        try:
            mode = os.lstat(path).st_mode
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISSOCK(mode):
                log.error(f"attach: {path} is there and not a socket: nothing attaches")
                return
            os.unlink(path)
        # 0600 until the chmod, whatever is around it.
        umask = os.umask(0o177)
        try:
            self.server = await asyncio.start_unix_server(self.accept, path)
        finally:
            os.umask(umask)
        os.chmod(path, 0o660 if ctx.options.attach_group_access else 0o600)
        self.path = path
        log.info(f"attach: programs attach on {path}")

    def done(self):
        for peer in list(self.peers):
            peer.close()
        if self.server is not None:
            self.server.close()
            self.server = None
        if self.path:
            with contextlib.suppress(OSError):
                os.unlink(self.path)
            self.path = None

    async def accept(self, reader, writer):
        try:
            hello = await asyncio.wait_for(read_frame(reader, MAX_HELLO), 10)
            if not isinstance(hello, dict) or hello.get("hello") != PROTOCOL:
                raise Refused(f"not proxy-suite's attach protocol {PROTOCOL}: use the client addon of this host")
            flow_format = hello.get("flow_format")
            if not isinstance(flow_format, int) or flow_format < version.FLOW_FORMAT_VERSION:
                raise Refused(
                    f"this mitmproxy ({hello.get('version')}) is older than the service's ({version.VERSION}):"
                    " use one no older"
                )
            if hello.get("modify") and flow_format != version.FLOW_FORMAT_VERSION:
                raise Refused(f"to change traffic, use the service's mitmproxy version ({version.VERSION})")
            peer = Peer(reader, writer, hello, ctx.options.attach_timeout)
        except Refused as e:
            writer.write(encode({"refused": str(e)}))
            writer.close()
            return
        except (TimeoutError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
            writer.close()
            return
        writer.write(
            encode(
                {
                    "welcome": PROTOCOL,
                    "flow_format": version.FLOW_FORMAT_VERSION,
                    "version": version.VERSION,
                    "timeout": peer.timeout,
                }
            )
        )
        self.peers.append(peer)
        log.info(f"attach: {peer} attached")
        try:
            await peer.serve()
        finally:
            peer.close()
            self.peers.remove(peer)
            log.info(f"attach: {peer} detached")

    async def dispatch(self, event, flow):
        if not self.peers:
            return
        # Those that change traffic first, in the order they came; then the copies, of
        # what is sent on.
        copies = {}
        for peer in sorted(self.peers, key=lambda p: not p.modify):
            if peer.closed or not peer.wants(flow, event):
                continue
            if flow.id not in peer.seen:
                peer.seen.add(flow.id)
                start = START_OF.get(event)
                if start is not None:
                    await self.deliver(peer, start, flow, copies)
            await self.deliver(peer, event, flow, copies)
            if ends(event, flow):
                peer.forget(flow.id)

    async def deliver(self, peer, event, flow, copies):
        payload = {"event": event, "id": flow.id}
        if event in MESSAGE_EVENTS:
            payload["message"] = list(last_message(flow).get_state())
        else:
            payload["flow"] = flow_state(flow)
        if peer.modify:
            payload["n"] = next(self.counter)
            reply = await peer.ask(payload)
            if reply:
                try:
                    apply(event, flow, reply)
                except Exception as e:  # noqa: BLE001 - a bad answer changes nothing
                    log.warning(f"attach: {peer} answered {event} with what does not apply ({e!r}): ignored")
            return
        if event not in copies:
            payload["n"] = 0
            copies[event] = encode(payload)
        peer.send(copies[event])

    async def request(self, flow):
        await self.dispatch("request", flow)

    async def response(self, flow):
        await self.dispatch("response", flow)

    async def error(self, flow):
        await self.dispatch("error", flow)

    async def websocket_start(self, flow):
        await self.dispatch("websocket_start", flow)

    async def websocket_message(self, flow):
        await self.dispatch("websocket_message", flow)

    async def websocket_end(self, flow):
        await self.dispatch("websocket_end", flow)

    async def tcp_start(self, flow):
        await self.dispatch("tcp_start", flow)

    async def tcp_message(self, flow):
        await self.dispatch("tcp_message", flow)

    async def tcp_end(self, flow):
        await self.dispatch("tcp_end", flow)

    async def tcp_error(self, flow):
        await self.dispatch("tcp_error", flow)

    async def udp_start(self, flow):
        await self.dispatch("udp_start", flow)

    async def udp_message(self, flow):
        await self.dispatch("udp_message", flow)

    async def udp_end(self, flow):
        await self.dispatch("udp_end", flow)

    async def udp_error(self, flow):
        await self.dispatch("udp_error", flow)


addons = [Attach()]
