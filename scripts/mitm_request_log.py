"""mitmproxy addon: a line of JSON for each request it has read (mitm.requestLog), and each
request whole for an addon of your own (mitm.requestLog.bodies).

Options, set in config.yaml by the module or with --set:
  request_log_file       the file the lines are appended to; empty, none are written
  request_log_flows_file the file the requests are appended to whole, bodies included, as
                         mitmproxy's flows; empty, none are written
  request_log_max_bytes  at this size each becomes <file>.1, replacing the one there, and a new
                         one is begun; 0, they grow until deleted
  request_log_headers    the requests' and answers' headers in the lines, cookies and logins
                         among them
  request_log_group_read the files 0640 whatever the umask, for the directory's group to read

The flows, as they come, go to another mitmdump and its addons:
  proxy-ctl mitm requests follow --bodies | mitmdump -nr - -s your_addon.py

Also for flows saved before:
  mitmdump -nr flows.mitm -s mitm_request_log.py --set request_log_file=requests.jsonl
"""

import io
import json
import os

from mitmproxy import ctx
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

    def configure(self, updated):
        self.lines.configure(updated)
        self.flows.configure(updated)

    def response(self, flow):
        self.write(flow)

    def error(self, flow):
        # One that broke off after its answer was written with it. Nothing is kept on the
        # flow to tell: it would be saved with it (flows.mitm) and shown in mitmweb.
        if flow.response is None:
            self.write(flow)

    def write(self, flow):
        if self.lines.out is not None:
            line = json.dumps(record(flow, ctx.options.request_log_headers), ensure_ascii=False, separators=(",", ":"))
            self.lines.write((line + "\n").encode("utf-8"))
        if self.flows.out is not None:
            # One write for the whole flow, as `mitmdump -r` reads them.
            buffer = io.BytesIO()
            flowio.FlowWriter(buffer).add(flow)
            self.flows.write(buffer.getvalue())

    def done(self):
        self.lines.close()
        self.flows.close()


addons = [RequestLog()]
