#!/usr/bin/env python3
"""mitm_attach.py and mitm_attach_client.py, with mitmproxy itself: each side against a
stand-in for the other that speaks the wire by hand.
"""

import asyncio
import os
import tempfile
import unittest

import mitm_attach as service
import mitm_attach_client as client
from mitmproxy import http, version
from mitmproxy.test import taddons, tflow


async def connect(path, **hello):
    """The reader, the writer (kept by the caller: a StreamWriter collected closes the
    connection) and the welcome."""
    reader, writer = await asyncio.open_unix_connection(path)
    writer.write(
        service.encode(
            {"hello": service.PROTOCOL, "flow_format": version.FLOW_FORMAT_VERSION, "version": version.VERSION, **hello}
        )
    )
    welcome = await service.read_frame(reader, service.MAX_FRAME)
    return reader, writer, welcome


async def frame(reader):
    return await asyncio.wait_for(service.read_frame(reader, service.MAX_FRAME), 5)


def leave(tctx):
    """The test master gone, its log handler with it: the next test has a loop of its own."""
    tctx.master._legacy_log_events.uninstall()
    tctx.__exit__(None, None, None)


class ServiceTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "attach.sock")
        self.addon = service.Attach()
        self.tctx = taddons.context(self.addon)
        self.tctx.__enter__()
        self.tctx.configure(self.addon, attach_socket=self.path, attach_timeout=5.0)
        await self.addon.running()

    async def asyncTearDown(self):
        self.addon.done()
        leave(self.tctx)
        self.dir.cleanup()

    async def settle(self):
        """Until the service has counted the peers that said hello."""
        for _ in range(100):
            await asyncio.sleep(0.01)

    async def test_socket_is_private(self):
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    async def test_reads_copies(self):
        reader, self.writer, welcome = await connect(self.path)
        self.assertEqual(welcome["welcome"], service.PROTOCOL)
        await self.settle()
        f = tflow.tflow(resp=True)
        await self.addon.request(f)
        await self.addon.response(f)
        got = await frame(reader)
        self.assertEqual((got["event"], got["id"]), ("request", f.id))
        self.assertEqual(got["flow"]["request"]["path"], b"/path")
        self.assertEqual((await frame(reader))["event"], "response")

    async def test_changes_a_request_and_makes_an_answer(self):
        reader, writer, _ = await connect(self.path, modify=True)
        await self.settle()
        f = tflow.tflow()

        async def program():
            got = await frame(reader)
            request = http.Request.from_state(got["flow"]["request"])
            request.path = "/changed"
            answer = http.Response.make(200, b"made here")
            writer.write(
                service.encode({"n": got["n"], "request": request.get_state(), "response": answer.get_state()})
            )

        task = asyncio.ensure_future(program())
        await self.addon.request(f)
        await task
        self.assertEqual(f.request.path, "/changed")
        self.assertEqual(f.response.content, b"made here")

    async def test_udp_from_partway(self):
        reader, writer, _ = await connect(self.path, modify=True)
        await self.settle()
        f = tflow.tudpflow()

        async def program():
            start = await frame(reader)
            self.assertEqual(start["event"], "udp_start")
            self.assertEqual(start["flow"]["messages"], [])
            writer.write(service.encode({"n": start["n"]}))
            message = await frame(reader)
            self.assertEqual(message["event"], "udp_message")
            self.assertEqual(message["message"][1], f.messages[-1].content)
            writer.write(service.encode({"n": message["n"], "content": b"rewritten"}))

        task = asyncio.ensure_future(program())
        await self.addon.udp_message(f)
        await task
        self.assertEqual(f.messages[-1].content, b"rewritten")

    async def test_kill(self):
        reader, writer, _ = await connect(self.path, modify=True)
        await self.settle()
        f = tflow.tflow()

        async def program():
            got = await frame(reader)
            writer.write(service.encode({"n": got["n"], "kill": True}))

        task = asyncio.ensure_future(program())
        await self.addon.request(f)
        await task
        self.assertEqual(f.error.msg, "Connection killed.")

    async def test_late_answer_detaches(self):
        reader, self.writer, welcome = await connect(self.path, modify=True, timeout=0.2)
        self.assertEqual(welcome["timeout"], 0.2)
        await self.settle()
        f = tflow.tflow()
        await self.addon.request(f)
        self.assertEqual(f.request.path, "/path")
        await frame(reader)
        self.assertEqual(await reader.read(), b"")
        await self.settle()
        self.assertEqual(self.addon.peers, [])

    async def test_filter(self):
        reader, self.writer, _ = await connect(self.path, filter="~udp")
        await self.settle()
        await self.addon.request(tflow.tflow())
        f = tflow.tudpflow()
        await self.addon.udp_start(f)
        self.assertEqual((await frame(reader))["event"], "udp_start")

    async def test_bad_filter_refused(self):
        _, _, welcome = await connect(self.path, filter="~nonsense(")
        self.assertIn("filter", welcome["refused"])

    async def test_older_mitmproxy_refused(self):
        reader, writer = await asyncio.open_unix_connection(self.path)
        writer.write(service.encode({"hello": service.PROTOCOL, "flow_format": 1, "version": "1.0"}))
        welcome = await frame(reader)
        self.assertIn("older", welcome["refused"])


class Recorder:
    """An addon of the program's: changes the request, the datagram, and remembers."""

    def __init__(self):
        self.seen = []

    def request(self, f):
        self.seen.append(("request", f.request.path))
        f.metadata["mine"] = "kept"
        f.request.path = "/mine"

    def response(self, f):
        self.seen.append(("response", f.metadata.get("mine")))

    def udp_message(self, f):
        self.seen.append(("udp_message", len(f.messages)))
        f.messages[-1].content = f.messages[-1].content.upper()


class ClientTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "attach.sock")
        self.hello = asyncio.get_running_loop().create_future()
        self.connection = asyncio.get_running_loop().create_future()

        async def accept(reader, writer):
            self.hello.set_result(await service.read_frame(reader, service.MAX_HELLO))
            writer.write(
                service.encode(
                    {"welcome": 1, "flow_format": version.FLOW_FORMAT_VERSION, "version": version.VERSION, "timeout": 5.0}
                )
            )
            self.connection.set_result((reader, writer))

        self.server = await asyncio.start_unix_server(accept, self.path)
        self.addon = client.AttachClient()
        self.recorder = Recorder()
        self.tctx = taddons.context(self.addon, self.recorder)
        self.tctx.__enter__()

    async def asyncTearDown(self):
        self.addon.done()
        self.server.close()
        leave(self.tctx)
        self.dir.cleanup()

    async def attach(self, **options):
        self.tctx.configure(self.addon, attach_socket=self.path, attach_reconnect=False, **options)
        self.addon.running()
        hello = await asyncio.wait_for(self.hello, 5)
        reader, writer = await asyncio.wait_for(self.connection, 5)
        return hello, reader, writer

    async def test_changes_traffic(self):
        hello, reader, writer = await self.attach(attach_modify=True, attach_filter="~d example.com")
        self.assertEqual((hello["modify"], hello["filter"]), (True, "~d example.com"))
        f = tflow.tflow(resp=True)
        writer.write(service.encode({"n": 7, "event": "request", "id": f.id, "flow": service.flow_state(f)}))
        reply = await frame(reader)
        self.assertEqual(reply["n"], 7)
        self.assertEqual(reply["request"]["path"], b"/mine")
        self.assertNotIn("kill", reply)
        writer.write(service.encode({"n": 8, "event": "response", "id": f.id, "flow": service.flow_state(f)}))
        self.assertEqual((await frame(reader))["n"], 8)
        self.assertEqual(self.recorder.seen, [("request", "/path"), ("response", "kept")])
        self.assertEqual(self.addon.replicas, {})

    async def test_udp_messages(self):
        _, reader, writer = await self.attach(attach_modify=True, attach_keep_messages=1)
        f = tflow.tudpflow()
        writer.write(service.encode({"n": 1, "event": "udp_start", "id": f.id, "flow": service.flow_state(f)}))
        self.assertEqual(await frame(reader), {"n": 1})
        for n in (2, 3):
            writer.write(
                service.encode({"n": n, "event": "udp_message", "id": f.id, "message": [True, b"hi", 1.0]})
            )
            self.assertEqual((await frame(reader))["content"], b"HI")
        # Kept to one, so the addon saw one each time.
        self.assertEqual(self.recorder.seen, [("udp_message", 1), ("udp_message", 1)])

    async def test_reading_sends_nothing_back(self):
        hello, reader, writer = await self.attach()
        self.assertFalse(hello["modify"])
        f = tflow.tflow()
        writer.write(service.encode({"n": 0, "event": "request", "id": f.id, "flow": service.flow_state(f)}))
        for _ in range(50):
            if self.recorder.seen:
                break
            await asyncio.sleep(0.01)
        self.assertEqual(self.recorder.seen, [("request", "/path")])
        with self.assertRaises(TimeoutError):
            await asyncio.wait_for(reader.read(1), 0.2)


class NoStrayHooksTest(unittest.TestCase):
    """mitmproxy calls a script's module-level functions named after hooks as its addon's."""

    def test_no_function_is_named_after_a_hook(self):
        import ast

        import mitmproxy.addons  # noqa: F401 - registers the addons' hooks
        import mitmproxy.proxy.layers  # noqa: F401 - registers the layers' hooks
        from mitmproxy import hooks

        for module in (service, client):
            with open(module.__file__) as f:
                tree = ast.parse(f.read())
            names = {n.name for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
            self.assertEqual(names & set(hooks.all_hooks), set(), module.__name__)


if __name__ == "__main__":
    unittest.main()
