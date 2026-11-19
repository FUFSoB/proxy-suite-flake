"""mitmproxy addon: a line of JSON for each request it has read (mitm.requestLog), and each
request whole for an addon of your own (mitm.requestLog.bodies). WebSocket, TCP and UDP
flows too: a line each once it has ended, with what went each way; whole, in parts as it goes.

Options, set in config.yaml by the module or with --set:
  request_log_file       the file the lines are appended to; empty, none are written
  request_log_flows_file the file the requests are appended to whole, bodies included, as
                         mitmproxy's flows; empty, none are written
  request_log_max_bytes  at this size each becomes <file>.1, replacing the one there, and a new
                         one is begun; 0, they grow until deleted
  request_log_headers    the requests' and answers' headers in the lines, cookies and logins
                         among them
  request_log_group_read the files 0640 whatever the umask, for the directory's group to read
  request_log_part_bytes a WebSocket, TCP or UDP flow is written whole in parts as it goes: one
                         each time this much has come since the last
  request_log_part_seconds or this long has passed since the last, at its next message

The flows, as they come, go to another mitmdump and its addons:
  proxy-ctl mitm requests follow --bodies | mitmdump -nr - -s your_addon.py

A part is the flow with the messages since the last part and the same id: the addon there sees
its start, those messages and its end for each part. The last has the flow's end or error.

Also for flows saved before:
  mitmdump -nr flows.mitm -s mitm_request_log.py --set request_log_file=requests.jsonl
"""

import io
import json
import os
import time

from mitmproxy import ctx, http, udp
from mitmproxy import io as flowio


def _headers(headers):
    """[[name, value], ...]: a name may come more than once (Set-Cookie)."""
    return [[k, v] for k, v in headers.items(multi=True)]


def _ms(start, end):
    return round((end - start) * 1000) if start and end else None


def record(flow, headers=False):
    """What is written for flow, an HTTP flow that has an answer, an error or both."""
    req, resp = flow.request, flow.response
    peer = flow.client_conn.peername
    line = {
        "kind": "http",
        "ts": req.timestamp_start,
        # The program or device; with the proxy on, the backend on loopback.
        "client": peer[0] if peer else None,
        "method": req.method,
        "url": req.pretty_url,
        "host": req.pretty_host,
        "http": req.http_version,
        "status": resp.status_code if resp else None,
        "reason": resp.reason if resp else None,
        "error": flow.error.msg if flow.error else None,
        # From the first byte of the request to the last of the answer.
        "ms": _ms(req.timestamp_start, resp.timestamp_end if resp else None),
        "request_bytes": len(req.raw_content or b""),
        "response_bytes": len(resp.raw_content or b"") if resp else None,
        "content_type": resp.headers.get("content-type") if resp else None,
    }
    if headers:
        line["request_headers"] = _headers(req.headers)
        line["response_headers"] = _headers(resp.headers) if resp else None
    return line


def messages_of(flow):
    """A WebSocket's, TCP or UDP flow's messages; an HTTP flow has none."""
    if isinstance(flow, http.HTTPFlow):
        return flow.websocket.messages if flow.websocket is not None else []
    return flow.messages


def _address(address):
    if not address:
        return None
    host, port = address[0], address[1]
    return f"[{host}]:{port}" if ":" in str(host) else f"{host}:{port}"


def stream_record(flow, headers=False):
    """What is written for a WebSocket, TCP or UDP flow once it has ended: what went each way."""
    messages = messages_of(flow)
    if isinstance(flow, http.HTTPFlow):
        line = record(flow, headers)
        line["kind"] = "websocket"
        line["close_code"] = flow.websocket.close_code
        line["close_reason"] = flow.websocket.close_reason or None
        start = flow.request.timestamp_start
    else:
        peer = flow.client_conn.peername
        line = {
            "kind": "udp" if isinstance(flow, udp.UDPFlow) else "tcp",
            "ts": flow.client_conn.timestamp_start,
            "client": peer[0] if peer else None,
            "server": _address(flow.server_conn.address),
            "sni": flow.server_conn.sni,
            "error": flow.error.msg if flow.error else None,
        }
        start = flow.client_conn.timestamp_start
    sent = [m for m in messages if m.from_client]
    received = [m for m in messages if not m.from_client]
    line.update(
        {
            # From the flow's first byte to its last message.
            "ms": _ms(start, messages[-1].timestamp if messages else None),
            "messages_from_client": len(sent),
            "messages_from_server": len(received),
            "bytes_from_client": sum(len(m.content) for m in sent),
            "bytes_from_server": sum(len(m.content) for m in received),
        }
    )
    return line


# The key a flow written in parts carries in each part's metadata: its number, from 1.
PART_KEY = "proxy-suite-part"


class Parts:
    """Where each WebSocket, TCP or UDP flow being written in parts is: the first message not
    written yet, the bytes since and when the last part was."""

    def __init__(self):
        self.state = {}

    def next(self, flow, size, now):
        """The (start, stop, number) of a part due now, or None."""
        start, pending, since, number = self.state.get(flow.id, (0, 0, now, 0))
        pending += size
        stop = len(messages_of(flow))
        if pending >= ctx.options.request_log_part_bytes or now - since >= ctx.options.request_log_part_seconds:
            self.state[flow.id] = (stop, 0, now, number + 1)
            return start, stop, number + 1
        self.state[flow.id] = (start, pending, since, number)
        return None

    def last(self, flow):
        """The (start, stop, number) of the flow's last part; number 0 when it was never split."""
        start, _, _, number = self.state.pop(flow.id, (0, 0, 0, 0))
        return start, len(messages_of(flow)), number + 1 if number else 0


class Sink:
    """The file an option names: appended to, rotated at request_log_max_bytes, 0640 if asked."""

    def __init__(self, option):
        self.option = option
        self.out = None
        self.size = 0

    @property
    def path(self):
        return getattr(ctx.options, self.option)

    def configure(self, updated):
        if self.option in updated:
            self.close()
            if self.path:
                self.open()

    def open(self):
        # Unbuffered: each record is whole in the file once written, for a follower.
        self.out = open(self.path, "ab", buffering=0)
        self.size = os.fstat(self.out.fileno()).st_size
        if ctx.options.request_log_group_read:
            # By fd, and after the open: the umask has had its say on the mode it made.
            os.fchmod(self.out.fileno(), 0o640)

    def write(self, data):
        if self.out is None:
            return
        view = memoryview(data)
        while view:
            view = view[self.out.write(view) :]
        self.size += len(data)
        limit = ctx.options.request_log_max_bytes
        if limit > 0 and self.size >= limit:
            self.rotate()

    def rotate(self):
        """A new file under the name, the full one as <file>.1: a follower reads the old one
        to its end through what it has open, then the new one. Always between two records."""
        path = self.path
        self.close()
        os.replace(path, path + ".1")
        self.open()

    def close(self):
        if self.out is not None:
            self.out.close()
            self.out = None


class RequestLog:
    def __init__(self):
        self.lines = Sink("request_log_file")
        self.flows = Sink("request_log_flows_file")
        self.parts = Parts()

    def load(self, loader):
        loader.add_option("request_log_file", str, "", "Append a line of JSON for each request to this file.")
        loader.add_option(
            "request_log_flows_file",
            str,
            "",
            "Append each request whole, bodies included, as mitmproxy's flows to this file.",
        )
        loader.add_option(
            "request_log_max_bytes", int, 0, "Rotate each file to <file>.1 at this size; 0, never."
        )
        loader.add_option(
            "request_log_headers", bool, False, "Put the headers in the lines too: cookies and logins among them."
        )
        loader.add_option(
            "request_log_group_read", bool, False, "Make the files readable by their group (0640), whatever the umask."
        )
        loader.add_option(
            "request_log_part_bytes",
            int,
            1 << 20,
            "Write a WebSocket, TCP or UDP flow whole in parts as it goes, one each time this much has come.",
        )
        loader.add_option(
            "request_log_part_seconds",
            float,
            10.0,
            "Or this long after the last part, at the flow's next message.",
        )

    def configure(self, updated):
        self.lines.configure(updated)
        self.flows.configure(updated)

    def response(self, flow):
        # A WebSocket's is written as it ends, with its messages.
        if flow.websocket is None:
            self.write(flow)

    def error(self, flow):
        # One that broke off after its answer was written with it. Nothing is kept on the
        # flow to tell: it would be saved with it (flows.mitm) and shown in mitmweb.
        if flow.response is None:
            self.write(flow)

    def websocket_message(self, flow):
        self.message(flow)

    def tcp_message(self, flow):
        self.message(flow)

    def udp_message(self, flow):
        self.message(flow)

    def websocket_end(self, flow):
        self.end(flow)

    def tcp_end(self, flow):
        self.end(flow)

    def tcp_error(self, flow):
        self.end(flow)

    def udp_end(self, flow):
        self.end(flow)

    def udp_error(self, flow):
        self.end(flow)

    def message(self, flow):
        if self.flows.out is None:
            return
        part = self.parts.next(flow, len(messages_of(flow)[-1].content), time.monotonic())
        if part is not None:
            self.write_flow(flow, *part)

    def end(self, flow):
        start, stop, number = self.parts.last(flow)
        if self.lines.out is not None:
            self.write_line(stream_record(flow, ctx.options.request_log_headers))
        if self.flows.out is not None:
            self.write_flow(flow, start, stop, number)

    def write(self, flow):
        if self.lines.out is not None:
            self.write_line(record(flow, ctx.options.request_log_headers))
        if self.flows.out is not None:
            self.write_flow(flow)

    def write_line(self, line):
        text = json.dumps(line, ensure_ascii=False, separators=(",", ":"))
        self.lines.write((text + "\n").encode("utf-8"))

    def write_flow(self, flow, start=0, stop=None, number=0):
        """One write for the flow, as `mitmdump -r` reads them: with its messages from start
        to stop only, and its part's number, when it goes in parts. The flow is as it was after."""
        holder = flow.websocket if isinstance(flow, http.HTTPFlow) else flow
        messages = holder.messages if holder is not None else None
        metadata = flow.metadata
        if number:
            flow.metadata = {**metadata, PART_KEY: number}
        if messages is not None:
            holder.messages = messages[start:stop]
        try:
            buffer = io.BytesIO()
            flowio.FlowWriter(buffer).add(flow)
        finally:
            flow.metadata = metadata
            if messages is not None:
                holder.messages = messages
        self.flows.write(buffer.getvalue())

    def done(self):
        self.lines.close()
        self.flows.close()


addons = [RequestLog()]
