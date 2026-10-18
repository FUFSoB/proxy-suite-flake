#!/usr/bin/env python3
"""per_app_dns.py: the question in a log line, and a lost UDP query asked again."""

import asyncio
import struct
import unittest
from unittest import mock

import per_app_dns as dns


def query(name: str, qtype: int = 1) -> bytes:
    labels = b"".join(bytes([len(p)]) + p.encode() for p in name.split("."))
    return struct.pack("!HHHHHH", 7, 0x100, 1, 0, 0, 0) + labels + b"\0" + struct.pack("!HH", qtype, 1)


class QuestionTest(unittest.TestCase):
    def test_question(self):
        self.assertEqual(dns.question(query("pbs.twimg.com", 65)), "pbs.twimg.com HTTPS")
        self.assertEqual(dns.question(query("x.com", 999)), "x.com 999")
        # The app's name, shown safely; garbage is "?".
        self.assertEqual(dns.question(query("a\x1bb.com")), "a?b.com A")
        self.assertEqual(dns.question(b"\0" * 5), "?")
        self.assertEqual(dns.question(query("x.com")[:-3]), "?")


class AskUdpTest(unittest.TestCase):
    def ask(self, behaviours, servers=("192.0.2.53",)):
        """ask_udp with each attempt, in order, answering after its delay (None: never, an
        exception: failing)."""
        behaviours = iter(behaviours)

        async def once(q, server, mark):
            delay, result = next(behaviours)
            await asyncio.sleep(delay)
            if isinstance(result, Exception):
                raise result
            if result is None:
                await asyncio.sleep(3600)
            return result

        async def run():
            loop = asyncio.get_running_loop()
            started = loop.time()
            reply = await dns.ask_udp(b"q", list(servers), 0)
            return reply, loop.time() - started

        with mock.patch.object(dns, "ask_udp_once", once), mock.patch.multiple(dns, TIMEOUT=0.4, RESEND_AFTER=0.15):
            return asyncio.run(run())

    def check(self, behaviours, reply, asked, took, **kw):
        result, elapsed = self.ask(behaviours, **kw)
        self.assertEqual(result, (reply, asked))
        # A busy builder runs late, never early.
        self.assertGreaterEqual(elapsed, took - 0.01)
        self.assertLess(elapsed, took + 0.1)

    def test_answered_at_once(self):
        self.check([(0, b"a")], b"a", 1, 0)

    def test_lost_query_is_asked_again(self):
        # The first never answers; the second, sent at 0.15, answers 0.05 later.
        self.check([(0, None), (0.05, b"b")], b"b", 2, 0.2)

    def test_the_first_may_still_answer(self):
        self.check([(0.3, b"late"), (1, b"never")], b"late", 2, 0.3)

    def test_failing_socket_is_asked_again_at_once(self):
        self.check([(0, OSError()), (0, b"b")], b"b", 2, 0)

    def test_silence(self):
        # Asked twice at most per server, then the next server.
        self.check([(0, None), (0, None)], None, 2, 0.4)
        self.check([(0, None), (0, None), (0, b"c")], b"c", 3, 0.4, servers=("192.0.2.53", "192.0.2.54"))


if __name__ == "__main__":
    unittest.main()
