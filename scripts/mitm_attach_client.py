"""mitmproxy addon: attaches this mitmdump, mitmproxy or mitmweb to proxy-suite's mitmproxy
(mitm.attach), and runs the flows it reads through this one's addons, live: the same hooks,
as they come. `proxy-ctl mitm attach` starts it so:

  proxy-ctl mitm attach -- mitmdump -s my_addon.py           # reads
  proxy-ctl mitm attach --modify -- mitmdump -s my_addon.py  # also changes traffic

or, by hand, `mitmdump -n -s "$(proxy-ctl mitm attach --addon)" -s my_addon.py`.

What the addons change is sent back with --modify (attach_modify): a request or answer, one
made in `request` (flow.response = ...), a message's content, a WebSocket message dropped, a
flow killed or intercepted (mitmproxy's and mitmweb's own intercept, held until resumed).
Without, they work on copies and hold nothing up. Each flow is kept from its first hook to its
last, so what an addon keeps in flow.metadata between them is still there.

Options (--set):
  attach_socket        the service's socket; proxy-ctl sets it
  attach_modify        change traffic: each hook waits for this one's addons
  attach_timeout       seconds the service waits for each answer; 0, its own (mitm.attach.timeout)
  attach_filter        only the flows this mitmproxy filter expression matches, e.g. "~udp"
  attach_keep_messages at most this many messages kept on each TCP, UDP or WebSocket flow; 0, all
  attach_reconnect     attach again when the service restarts, rather than stop
"""

import asyncio
import logging
import os

from mitm_attach import MAX_FRAME, PROTOCOL, encode, read_frame
from mitmproxy import ctx, flow, http, tcp, udp, version, websocket
from mitmproxy.io import compat
from mitmproxy.proxy.layers import http as http_layer
from mitmproxy.proxy.layers import tcp as tcp_layer
from mitmproxy.proxy.layers import udp as udp_layer
from mitmproxy.proxy.layers import websocket as websocket_layer

HOOKS = {
    "request": http_layer.HttpRequestHook,
    "response": http_layer.HttpResponseHook,
    "error": http_layer.HttpErrorHook,
    "websocket_start": websocket_layer.WebsocketStartHook,
    "websocket_message": websocket_layer.WebsocketMessageHook,
    "websocket_end": websocket_layer.WebsocketEndHook,
    "tcp_start": tcp_layer.TcpStartHook,
    "tcp_message": tcp_layer.TcpMessageHook,
    "tcp_end": tcp_layer.TcpEndHook,
    "tcp_error": tcp_layer.TcpErrorHook,
    "udp_start": udp_layer.UdpStartHook,
    "udp_message": udp_layer.UdpMessageHook,
    "udp_end": udp_layer.UdpEndHook,
    "udp_error": udp_layer.UdpErrorHook,
}
ENDS = ("error", "websocket_end", "tcp_end", "tcp_error", "udp_end", "udp_error")
RECONNECT_DELAY = 1.0

log = logging.getLogger(__name__)


class Refused(Exception):
    pass


def messages_of(replica):
    """The list a flow keeps its messages in, or None."""
    if isinstance(replica, (tcp.TCPFlow, udp.UDPFlow)):
        return replica.messages
    if isinstance(replica, http.HTTPFlow) and replica.websocket is not None:
        return replica.websocket.messages
    return None


def message_class(replica):
    if isinstance(replica, tcp.TCPFlow):
        return tcp.TCPMessage
    if isinstance(replica, udp.UDPFlow):
        return udp.UDPMessage
    return websocket.WebSocketMessage


def merge_state(replica, state):
    """The service's newer state, keeping what is this side's: metadata, messages, live.

    Not named after a hook: mitmproxy calls a script's module-level functions as its addon's
    (an `update` here would be called with every flow updated)."""
    metadata, messages, live = replica.metadata, messages_of(replica), replica.live
    replica.set_state(state)
    replica.metadata, replica.live = metadata, live
    if messages is not None:
        kept = messages_of(replica)
        if kept is not None:
            kept[:] = messages


def snapshot(event, replica):
    """What an answer compares against: only what changed is sent back."""
    killed = replica.error is not None and replica.error.msg == flow.Error.KILLED_MESSAGE
    seen = {"marked": replica.marked, "comment": replica.comment, "killed": killed}
    if event in ("request", "response"):
        seen["request"] = replica.request.get_state() if replica.request else None
        seen["response"] = replica.response.get_state() if replica.response else None
    if event.endswith("_message"):
        message = messages_of(replica)[-1]
        seen["content"] = message.content
        seen["dropped"] = getattr(message, "dropped", False)
    return seen


def answer(event, before, after):
    reply = {}
    if after["killed"] and not before["killed"]:
        reply["kill"] = True
    for key in ("marked", "comment"):
        if after[key] != before[key]:
            reply[key] = after[key]
    for key in ("request", "response"):
        if key in after and after[key] != before[key] and after[key] is not None:
            reply[key] = after[key]
    if "content" in after and after["content"] != before["content"]:
        reply["content"] = after["content"]
    if after.get("dropped") and not before.get("dropped"):
        reply["drop"] = True
    return reply


async def until_resumed(replica):
    """Held while intercepted, in mitmproxy's or mitmweb's view, until resumed or killed."""
    while replica.intercepted:
        try:
            await asyncio.wait_for(replica.wait_for_resume(), 0.5)
        except TimeoutError:
            pass


class AttachClient:
    def __init__(self):
        self.task = None
        self.writer = None
        self.replicas = {}
        self.queues = {}
        self.workers = set()
        # The service's flows are older than this mitmproxy's: brought up to date as they come.
        self.migrate = False

    def load(self, loader):
        loader.add_option(
            "attach_socket",
            str,
            os.environ.get("PROXY_SUITE_MITM_ATTACH", ""),
            "proxy-suite's mitmproxy socket to attach to (proxy-ctl mitm attach sets it).",
        )
        loader.add_option("attach_modify", bool, False, "Change traffic: each hook waits for this mitmproxy's addons.")
        loader.add_option(
            "attach_timeout", float, 0.0, "Seconds the service waits for each answer; 0, its own (mitm.attach.timeout)."
        )
        loader.add_option("attach_filter", str, "", "Only the flows this filter expression matches; empty, all.")
        loader.add_option(
            "attach_keep_messages", int, 0, "Keep at most this many messages on each TCP, UDP or WebSocket flow; 0, all."
        )
        loader.add_option("attach_reconnect", bool, True, "Attach again when the service restarts, rather than stop.")

    def running(self):
        if not ctx.options.attach_socket:
            log.error("attach: no socket (attach_socket): start this through proxy-ctl mitm attach")
            ctx.master.shutdown()
            return
        if getattr(ctx.options, "server", False):
            log.warning("attach: this mitmproxy also listens as a proxy of its own; -n turns that off")
        self.task = asyncio.get_running_loop().create_task(self.run())

    def done(self):
        if self.task is not None:
            self.task.cancel()
            self.task = None
        if self.writer is not None:
            self.writer.close()

    async def run(self):
        while True:
            try:
                await self.session()
            except Refused as e:
                log.error(f"attach: refused: {e}")
                ctx.master.shutdown()
                return
            except (OSError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError) as e:
                log.warning(f"attach: not attached ({e or type(e).__name__})")
            if not ctx.options.attach_reconnect:
                ctx.master.shutdown()
                return
            await asyncio.sleep(RECONNECT_DELAY)

    async def session(self):
        reader, writer = await asyncio.open_unix_connection(ctx.options.attach_socket)
        self.writer = writer
        try:
            writer.write(
                encode(
                    {
                        "hello": PROTOCOL,
                        "flow_format": version.FLOW_FORMAT_VERSION,
                        "version": version.VERSION,
                        "modify": ctx.options.attach_modify,
                        "timeout": ctx.options.attach_timeout,
                        "filter": ctx.options.attach_filter,
                    }
                )
            )
            welcome = await read_frame(reader, MAX_FRAME)
            if not isinstance(welcome, dict) or "welcome" not in welcome:
                raise Refused((welcome or {}).get("refused", "no welcome") if isinstance(welcome, dict) else "no welcome")
            self.migrate = welcome.get("flow_format") != version.FLOW_FORMAT_VERSION
            mode = f"changing traffic, {welcome.get('timeout', 0):g}s per answer" if ctx.options.attach_modify else "reading"
            log.info(f"attach: attached to mitmproxy {welcome.get('version')} ({mode})")
            while True:
                try:
                    frame = await read_frame(reader, MAX_FRAME)
                except asyncio.IncompleteReadError:
                    raise ConnectionResetError("the service went away") from None
                if isinstance(frame, dict) and isinstance(frame.get("id"), str) and frame.get("event") in HOOKS:
                    self.enqueue(frame)
        finally:
            for worker in list(self.workers):
                worker.cancel()
            self.workers.clear()
            self.queues.clear()
            self.replicas.clear()
            writer.close()
            self.writer = None

    def enqueue(self, frame):
        """Each flow's hooks in order, one flow's never waiting on another's."""
        flow_id = frame["id"]
        queue = self.queues.get(flow_id)
        if queue is None:
            queue = self.queues[flow_id] = asyncio.Queue()
            worker = asyncio.get_running_loop().create_task(self.work(flow_id, queue))
            self.workers.add(worker)
            worker.add_done_callback(self.workers.discard)
        queue.put_nowait(frame)

    async def work(self, flow_id, queue):
        while True:
            frame = await queue.get()
            try:
                ended = await self.handle(frame)
            except Exception:  # noqa: BLE001 - one flow's trouble is not the others'
                log.exception(f"attach: {frame.get('event')} of {flow_id}")
                ended = frame.get("event") in ENDS
            if ended and queue.empty():
                self.queues.pop(flow_id, None)
                return

    async def handle(self, frame):
        event, flow_id = frame["event"], frame["id"]
        replica = self.replicas.get(flow_id)
        if "flow" in frame:
            state = frame["flow"]
            if self.migrate:
                state = compat.migrate_flow(state)
            if replica is None:
                replica = flow.Flow.from_state(state)
                replica.live = True
                self.replicas[flow_id] = replica
            else:
                merge_state(replica, state)
        elif replica is None or messages_of(replica) is None:
            # A message of a flow not seen: the service sends the start first.
            return event in ENDS
        else:
            messages = messages_of(replica)
            messages.append(message_class(replica).from_state(frame["message"]))
            keep = ctx.options.attach_keep_messages
            if keep > 0 and len(messages) > keep:
                del messages[: len(messages) - keep]
        before = snapshot(event, replica)
        await ctx.master.addons.handle_lifecycle(HOOKS[event](replica))
        await until_resumed(replica)
        if ctx.options.attach_modify and self.writer is not None:
            self.writer.write(encode({"n": frame.get("n", 0), **answer(event, before, snapshot(event, replica))}))
        ended = event in ENDS or (event == "response" and replica.websocket is None)
        if ended:
            self.replicas.pop(flow_id, None)
        return ended


addons = [AttachClient()]
