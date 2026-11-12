#!/usr/bin/env python3
"""mitm_request_log.py: a line per request, written once, headers only when asked.

mitmproxy itself is not imported: its ctx is a stand-in, and the flows carry only what the
addon reads.
"""

import json
import os
import sys
import tempfile
import types
import unittest

ctx = types.SimpleNamespace(
    options=types.SimpleNamespace(
        request_log_file="",
        request_log_flows_file="",
        request_log_max_bytes=0,
        request_log_headers=False,
        request_log_group_read=False,
    )
)


class FlowWriter:
    """mitmproxy.io's, in a form the tests read back: one record per flow, in one write."""

    def __init__(self, fo):
        self.fo = fo

    def add(self, flow):
        self.fo.write(f"<{flow.request.pretty_url}>".encode())


sys.modules["mitmproxy"] = types.SimpleNamespace(ctx=ctx, io=types.SimpleNamespace(FlowWriter=FlowWriter))

import mitm_request_log as addon  # noqa: E402


class Headers:
    """mitmproxy's: a name may come more than once."""

    def __init__(self, *fields):
        self.fields = fields

    def items(self, multi=False):
        assert multi
        return list(self.fields)

    def get(self, name):
        return next((v for k, v in self.fields if k.lower() == name.lower()), None)


def flow(response=True, error=None):
    request = types.SimpleNamespace(
        timestamp_start=100.0,
        method="GET",
        pretty_url="https://example.com/a?b=1",
        pretty_host="example.com",
        http_version="HTTP/2.0",
        raw_content=b"",
        headers=Headers(("Cookie", "a=1"), ("Accept", "*/*")),
    )
    answer = None
    if response:
        answer = types.SimpleNamespace(
            status_code=404,
            reason="Not Found",
            timestamp_end=100.25,
            raw_content=b"nope",
            headers=Headers(("Content-Type", "text/plain"), ("Set-Cookie", "x=1"), ("Set-Cookie", "y=2")),
        )
    return types.SimpleNamespace(
        request=request,
        response=answer,
        error=types.SimpleNamespace(msg=error) if error else None,
        client_conn=types.SimpleNamespace(peername=("192.0.2.7", 51000)),
        metadata={},
    )


class RequestLogTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "requests.jsonl")
        ctx.options.request_log_file = self.path
        ctx.options.request_log_flows_file = ""
        ctx.options.request_log_max_bytes = 0
        ctx.options.request_log_headers = False
        ctx.options.request_log_group_read = False
        self.log = addon.RequestLog()
        self.log.configure({"request_log_file"})
        self.addCleanup(self.log.done)

    def lines(self):
        with open(self.path, encoding="utf-8") as f:
            return [json.loads(line) for line in f]

    def test_an_answer(self):
        f = flow()
        self.log.response(f)
        [line] = self.lines()
        self.assertEqual(
            line,
            {
                "ts": 100.0,
                "client": "192.0.2.7",
                "method": "GET",
                "url": "https://example.com/a?b=1",
                "host": "example.com",
                "http": "HTTP/2.0",
                "status": 404,
                "reason": "Not Found",
                "error": None,
                "ms": 250,
                "request_bytes": 0,
                "response_bytes": 4,
                "content_type": "text/plain",
            },
        )
        # Nothing is left on the flow: it would be saved with it.
        self.assertEqual(f.metadata, {})

    def test_headers_when_asked_every_one(self):
        ctx.options.request_log_headers = True
        self.log.response(flow())
        [line] = self.lines()
        self.assertEqual(line["request_headers"], [["Cookie", "a=1"], ["Accept", "*/*"]])
        self.assertEqual(
            line["response_headers"], [["Content-Type", "text/plain"], ["Set-Cookie", "x=1"], ["Set-Cookie", "y=2"]]
        )

    def test_an_error_once(self):
        self.log.error(flow(response=False, error="connection refused"))
        # Broken off after its answer: that one was written with the answer.
        answered = flow(error="client disconnected")
        self.log.response(answered)
        self.log.error(answered)
        first, second = self.lines()
        self.assertEqual((first["status"], first["error"], first["ms"], first["response_bytes"]), (None, "connection refused", None, None))
        self.assertEqual(second["status"], 404)

    def test_no_file_no_lines(self):
        ctx.options.request_log_file = ""
        self.log.configure({"request_log_file"})
        self.log.response(flow())
        self.assertEqual(self.lines(), [])
        # Other options leave the file as it is.
        ctx.options.request_log_file = self.path
        self.log.configure({"request_log_headers"})
        self.log.response(flow())
        self.assertEqual(self.lines(), [])

    def test_rotated_at_its_size(self):
        self.log.response(flow())
        one = os.path.getsize(self.path)
        # Rotated once a line takes it to the limit, counting what was there as it opened.
        self.log.done()
        ctx.options.request_log_max_bytes = 2 * one
        self.log.configure({"request_log_file"})
        self.log.response(flow())
        self.assertEqual(os.path.getsize(self.path), 0)
        self.assertEqual(len(self.lines_of(self.path + ".1")), 2)
        # The next lines go to the new file; another rotation replaces the old one.
        self.log.response(flow())
        self.log.response(flow())
        self.assertEqual(os.path.getsize(self.path), 0)
        self.assertEqual(len(self.lines_of(self.path + ".1")), 2)

    def test_group_read_whatever_the_umask(self):
        old = os.umask(0o077)
        self.addCleanup(os.umask, old)
        self.log.done()
        os.remove(self.path)
        self.log.configure({"request_log_file"})
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        # Asked: 0640, and so is the one begun as it rotates.
        self.log.done()
        ctx.options.request_log_group_read = True
        ctx.options.request_log_max_bytes = 1
        self.log.configure({"request_log_file"})
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o640)
        self.log.response(flow())
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o640)
        self.assertEqual(os.stat(self.path + ".1").st_mode & 0o777, 0o640)

    def test_flows_whole_once_and_rotated_between_them(self):
        flows = os.path.join(self.dir.name, "requests.mitm")
        ctx.options.request_log_flows_file = flows
        ctx.options.request_log_max_bytes = 50
        self.log.configure({"request_log_flows_file"})
        self.log.error(flow(response=False, error="refused"))
        answered = flow()
        self.log.response(answered)
        self.log.error(answered)

        def read(path):
            with open(path, "rb") as f:
                return f.read()

        record = b"<https://example.com/a?b=1>"
        # Two records reach 50 bytes: rotated after the second, never inside one.
        self.assertEqual(read(flows + ".1"), record * 2)
        self.assertEqual(read(flows), b"")
        # Without a file, no flows.
        ctx.options.request_log_flows_file = ""
        self.log.configure({"request_log_flows_file"})
        self.log.response(flow())
        self.assertEqual(read(flows), b"")

    def lines_of(self, path):
        with open(path, encoding="utf-8") as f:
            return [json.loads(line) for line in f]

    def test_appended_a_line_at_a_time(self):
        self.log.response(flow())
        # Seen before the addon closes it: tail -f follows as requests end.
        self.assertEqual(len(self.lines()), 1)
        self.log.done()
        again = addon.RequestLog()
        again.configure({"request_log_file"})
        again.response(flow())
        again.done()
        self.assertEqual(len(self.lines()), 2)


if __name__ == "__main__":
    unittest.main()
