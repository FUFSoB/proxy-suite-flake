#!/usr/bin/env python3

import contextlib
import datetime
import io
import json
import os
import socket
import tempfile
import unittest
from unittest import mock

import proxy_ctl as ctl


def run(fn, *args):
    """(exit status, stdout, stderr) of a proxy-ctl function."""
    out, err = io.StringIO(), io.StringIO()
    status = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            fn(*args)
        except SystemExit as e:
            status = e.code
    return status, out.getvalue(), err.getvalue()


def ok(fn, *args):
    status, out, err = run(fn, *args)
    assert status == 0, (status, out, err)
    return out


class EnvTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        patcher = mock.patch.dict(os.environ, {}, clear=False)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def path(self, name):
        return os.path.join(self.dir, name)

    def write(self, name, content):
        path = self.path(name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content if isinstance(content, str) else json.dumps(content))
        return path

    def patch(self, name, value):
        patcher = mock.patch.object(ctl, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)


# The verdict table, fed tuples measured on a real censored network.
class ProbeVerdictTest(unittest.TestCase):
    def expect(self, want, direct, via):
        self.assertEqual(ctl._probe_verdict(direct, via), want, (direct, via))

    def test_table(self):
        # Origin refuses direct, accepts the proxy: chatgpt.com/robots.txt.
        self.expect("destination", "0|0.146175|403|6633|", "0|0.230116|200|4302|")
        # The same through a redirect: claude.ai/robots.txt.
        self.expect("destination", "0|0.141625|302|143|https://claude.com/app-unavailable-in-region", "0|0.181276|200|281|")
        # TLS never completed: censorship, zapret's job.
        self.expect("censor", "35|0.000000|000|0|", "0|0.119348|200|6258|")
        # Handshake, then silence: the post-handshake throttle.
        self.expect("censor", "0|0.125029|000|0|", "0|0.143772|200|32881|")
        # Direct works. Nothing to do, whoever else also works.
        self.expect("ok", "0|0.099546|200|2678|", "0|0.146822|200|2678|")
        # robots.txt legitimately absent is not a failure.
        self.expect("ok", "0|0.161330|404|559|", "0|0.214667|404|559|")
        # An ordinary redirect must not read as a block.
        self.expect("ok", "0|0.10|301|0|https://www.example.com/robots.txt", "0|0.20|301|0|https://www.example.com/robots.txt")
        # Refused everywhere: not an egress problem.
        self.expect("both-fail", "0|0.10|403|100|", "0|0.20|403|100|")
        # Nothing reaches it at all - a dead name, not a blocked one.
        self.expect("unreachable", "6|0.000000|000|0|", "35|0.000000|000|0|")


class ProbeFetchTest(EnvTest):
    def test_redirect_chains(self):
        calls = []
        table = {
            "https://spotify.test/": "0|0.1|301|0|https://www.spotify.test/",
            "https://www.spotify.test/": "0|0.1|301|0|https://open.spotify.test/",
            "https://open.spotify.test/": "0|0.1|302|93|https://accounts.spotify.test/login",
            "https://accounts.spotify.test/login": "0|0.1|301|0|https://www.spotify.test/int/why-not-available/",
            "https://redir.test/": "0|0.1|301|0|https://elsewhere.example/",
            "https://loop.test/": "0|0.1|301|0|https://loop.test/",
        }

        def curl(argv):
            calls.append(argv[-1])
            return 0, table.get(argv[-1], "0|0.1|200|10|")

        self.patch("run_curl", curl)
        # spotify.com: the block is four same-site hops in.
        self.assertEqual(ctl._probe_exit_verdict(ctl._probe_fetch("spotify.test", "/", "--noproxy", "*")), "blocked")
        # Leaving the site ends the walk.
        self.assertEqual(ctl._probe_exit_verdict(ctl._probe_fetch("redir.test", "/", "--noproxy", "*")), "ok")
        # A redirect loop inside the site still stops.
        calls.clear()
        ctl._probe_fetch("loop.test", "/", "--noproxy", "*")
        self.assertLessEqual(len(calls), 6)

    def test_curl_that_cannot_start(self):
        # An error, not a dead site.
        os.environ.update(PROBE_CURL="/nonexistent", PROBE_EXITS_FILE="/nonexistent")
        self.patch("svc_active", lambda unit: True)
        status, _, err = run(ctl.cmd_proxy_probe, "--json", "x.test")
        self.assertNotEqual(status, 0)
        self.assertIn("Cannot run /nonexistent", err)


class ProbeWalkTest(EnvTest):
    def setUp(self):
        super().setUp()
        self.patch("svc_active", lambda unit: True)
        os.environ["PROBE_EXITS_FILE"] = "/nonexistent"

    def probe(self, *args):
        return json.loads(ok(ctl.cmd_proxy_probe, "--json", *args))

    def probe_with(self, apex_direct, apex_proxy, robots_direct, robots_proxy):
        """No listener index: only this host and the local proxy."""

        def fetch(domain, path, flag, url):
            if path == "/":
                return apex_direct if flag == "--noproxy" else apex_proxy
            return robots_direct if flag == "--noproxy" else robots_proxy

        self.patch("_probe_fetch", fetch)
        return self.probe("example.test")

    # --- which path decides: the apex, robots.txt only breaks ties ---
    def test_apex_decides(self):
        # last.fm: apex geo-blocked, robots.txt served everywhere.
        out = self.probe_with("0|0.11|403|424|", "0|0.17|200|59809|", "0|0.11|200|400|", "0|0.17|200|400|")
        self.assertEqual((out["verdict"], out["url"]), ("destination", "https://example.test/"))

    def test_robots_breaks_ties(self):
        # chatgpt.com: apex 403 everywhere, robots.txt separates.
        out = self.probe_with("0|0.14|403|6633|", "0|0.23|403|8442|", "0|0.14|403|6633|", "0|0.23|200|4302|")
        self.assertEqual((out["verdict"], out["url"]), ("destination", "https://example.test/robots.txt"))

    def test_working_apex_is_not_second_guessed(self):
        out = self.probe_with("0|0.10|200|500|", "0|0.20|200|500|", "0|0.10|403|10|", "0|0.20|200|10|")
        self.assertEqual(out["verdict"], "ok")

    # --- walking more than two exits ---
    def use_exits(self, fetch):
        os.environ["PROBE_EXITS_FILE"] = self.write(
            "exits.json",
            [{"i": 0, "tag": "direct", "port": 18540}, {"i": 1, "tag": "fi", "port": 18541}, {"i": 2, "tag": "de", "port": 18542}],
        )
        self.patch("_probe_fetch", fetch)

    def test_multi_exit(self):
        # Direct and the first proxy share a WAF; only the third exit gets through.
        # Every exit, direct included, goes through its pinned listener.
        self.use_exits(lambda domain, path, flag, url: "0|0.10|200|500|" if url.endswith(":18542") else "0|0.10|403|919|")
        out = self.probe("sekai.test")
        self.assertEqual((out["verdict"], out["exit"]), ("destination", "de"))

        # --keep-going tries every exit but keeps the first that worked.
        out = self.probe("--keep-going", "--exits", "de,fi", "sekai.test")
        self.assertEqual(out["exit"], "de")
        self.assertEqual([e["tag"] for e in out["exits"]], ["direct", "de", "fi", "direct", "de", "fi"])

        # --exits restricts and orders the walk; direct is always tried first.
        out = self.probe("--exits", "de", "sekai.test")
        self.assertEqual([e["tag"] for e in out["exits"]], ["direct", "de"])

        # An empty list probes direct only (every exit shares one network).
        out = self.probe("--exits", "", "sekai.test")
        self.assertEqual({e["tag"] for e in out["exits"]}, {"direct"})
        self.assertIsNone(out["exit"])

        # --via: can this exit carry what direct reaches?
        out = self.probe("--via", "de", "sekai.test")
        self.assertEqual(out["verdict"], "ok")
        self.assertEqual({e["tag"] for e in out["exits"]}, {"de", "direct"})
        self.assertEqual(self.probe("--via", "fi", "sekai.test")["verdict"], "blocked")
        self.assertNotEqual(run(ctl.cmd_proxy_probe, "--json", "--via", "nowhere", "sekai.test")[0], 0)

        # A given path is probed as is, for that probe only.
        out = self.probe("--via", "de", "sekai.test/robots.txt")
        self.assertEqual(out["url"], "https://sekai.test/robots.txt")
        self.assertEqual({e["path"] for e in out["exits"]}, {"/robots.txt"})
        out = self.probe("--via", "fi", "sekai.test")
        self.assertEqual({e["path"] for e in out["exits"]}, {"/", "/robots.txt"})

    def test_via_refused_front_page(self):
        # Refused a front page direct gets: not a stand-in (www.reddit.com).
        self.use_exits(lambda domain, path, flag, url: "0|0.10|403|190240|" if url.endswith(":18541") and path == "/" else "0|0.10|200|500|")
        self.assertEqual(self.probe("--via", "fi", "geo.test")["verdict"], "blocked")

    def test_via_robots_decides(self):
        # i.pximg.net: the front page is 400 everywhere, so robots.txt decides.
        self.use_exits(lambda domain, path, flag, url: "0|0.10|400|0|" if path == "/" else "0|0.10|200|43|")
        self.assertEqual(self.probe("--via", "fi", "cdn.test")["verdict"], "ok")

    def test_text_output(self):
        self.use_exits(lambda domain, path, flag, url: "0|0.10|200|500|" if url.endswith(":18542") else "0|0.10|403|919|")
        out = ok(ctl.cmd_proxy_probe, "sekai.test")
        self.assertRegex(out, r"(?m)^    de +/ +TLS 0\.10s, 200, 500 bytes +ok  <- chosen$")
        self.assertIn('pin: proxy.routing.rules = [ { outbound = "de"; domains = [ "sekai.test" ]; } ]', out)


class AutoProxyTest(EnvTest):
    def setUp(self):
        super().setUp()
        os.environ.update(AUTOPROXY_ENABLED="1", AUTOPROXY_STATE_DIR=self.dir)

    def state_on_start(self, state):
        def systemctl(*args, **kw):
            if args[:1] == ("start",):
                self.write("state.json", state)
            return 0, ""

        self.patch("systemctl", systemctl)

    def test_learn(self):
        self.state_on_start(
            {
                "domains": {"last.fm": {"verdict": "destination", "exit": "primary", "host": "www.last.fm"}},
                "hosts": {"www.last.fm": {"domain": "last.fm", "verdict": "destination", "exit": "primary"}},
            }
        )
        with mock.patch.dict(os.environ, AUTOPROXY_ENABLED="0"):
            self.assertNotEqual(run(ctl.cmd_proxy_learn, "www.last.fm")[0], 0)
        # It lands in a root-owned file and then in a URL: hostnames only.
        self.assertNotEqual(run(ctl.cmd_proxy_learn, "x;rm -rf /")[0], 0)
        self.assertNotEqual(run(ctl.cmd_proxy_learn, "-evil.test/path")[0], 0)
        out = ok(ctl.cmd_proxy_learn, "www.last.fm")
        self.assertEqual(ctl.read_text(self.path("requests")), "www.last.fm\n")
        self.assertIn("last.fm: destination - routed via primary", out)

    def test_learn_nothing_to_route(self):
        # A verdict that routes nothing is kept for its host and reported.
        self.state_on_start({"domains": {}, "hosts": {"api.example.test": {"domain": "example.test", "verdict": "ok", "exit": None}}})
        self.assertIn("api.example.test: ok - nothing to route", ok(ctl.cmd_proxy_learn, "api.example.test"))

    def test_learn_failed_run(self):
        # A failed run is reported in plain words, and the request is not lost.
        self.patch("systemctl", lambda *args, **kw: (1, ""))
        status, _, err = run(ctl.cmd_proxy_learn, "www.last.fm")
        self.assertNotEqual(status, 0)
        self.assertIn("still queued", err)
        self.assertIn("www.last.fm\n", ctl.read_text(self.path("requests")))

    def test_queue_and_learned(self):
        self.patch("systemctl", lambda *args, **kw: (0, ""))
        self.write("requests", "www.last.fm\n")
        self.write(
            "state.json",
            {
                "domains": {"spotify.com": {"verdict": "destination", "exit": "primary", "host": "www.spotify.com", "at": 0}},
                "hosts": {
                    "www.spotify.com": {"domain": "spotify.com", "verdict": "destination", "exit": "primary"},
                    "gew1-spclient.spotify.com": {"domain": "spotify.com", "verdict": "ok", "exit": None},
                },
                "backlog": {"a.example": {"domain": "example", "hits": 2}, "b.example": {"domain": "example", "hits": 9}},
            },
        )
        q = ok(ctl.cmd_proxy_queue)
        self.assertIn("\n  www.last.fm\n", q)
        # Most-dialled first.
        self.assertLess(q.index("b.example"), q.index("a.example"))
        learned = ok(ctl.cmd_proxy_learned)
        self.assertRegex(learned, r"spotify.com .*-> primary")
        self.assertIn("ok=1", learned)

    @unittest.skipIf(os.geteuid() == 0, "root reads anything")
    def test_unreadable_state_asks_for_sudo(self):
        os.chmod(self.dir, 0)
        try:
            status, _, err = run(ctl.cmd_proxy_queue)
        finally:
            os.chmod(self.dir, 0o755)
        self.assertNotEqual(status, 0)
        self.assertIn("enable userControl, or run with sudo", err)


class InboundsTest(EnvTest):
    def test_stats(self):
        self.patch("systemctl", lambda *args, **kw: (0, ""))
        self.patch("_today", lambda: datetime.date(2026, 9, 11))
        os.environ["INBOUNDS_STATS_FILE"] = self.write(
            "stats.json",
            {
                "days": {
                    "2026-09-11": {"fufsob": {"down": 6000000, "up": 4000}, "phone": {"up": 0}},
                    "2026-09-10": {"fufsob": {"down": 1073741824, "up": 1048576}},
                    "2026-09-01": {"fufsob": {"down": 1, "up": 1}},
                }
            },
        )
        out = ok(ctl._inbound_stats, "2")
        # Newest day first, sizes readable, then totals over the period.
        self.assertLess(out.index("  2026-09-11"), out.index("  2026-09-10"))
        self.assertNotIn("2026-09-01", out)
        self.assertRegex(out, r"(?m)^  2026-09-11 +fufsob +5\.7 MiB +4 KiB$")
        self.assertRegex(out, r"(?m)^  2026-09-11 +phone +0 B +0 B$")
        self.assertRegex(out, r"(?m)^  2026-09-10 +fufsob +1\.0 GiB +1\.0 MiB$")
        self.assertRegex(out, r"(?m)^  fufsob +1\.0 GiB +1\.0 MiB$")
        self.assertNotEqual(run(ctl._inbound_stats, "0")[0], 0)
        # Nothing collected yet says so, rather than printing an empty table.
        os.environ["INBOUNDS_STATS_FILE"] = self.path("none.json")
        status, _, err = run(ctl._inbound_stats, "7")
        self.assertNotEqual(status, 0)
        self.assertIn("No traffic recorded yet", err)

    def test_subscriptions(self):
        os.environ["INBOUNDS_SUBS_FILE"] = self.write("subs.json", [{"user": "fufsob", "token": "aaa"}, {"user": "teri", "token": "bbb"}])
        os.environ["INBOUNDS_SUB_BASE_URL"] = "https://vpn.example/sub/"
        self.assertEqual(ok(ctl._inbound_subscriptions, "teri"), "https://vpn.example/sub/bbb\n")
        # Without a user: names only, never a token.
        out = ok(ctl._inbound_subscriptions)
        self.assertEqual(out, "  fufsob\n  teri\n")
        self.assertNotEqual(run(ctl._inbound_subscriptions, "nobody")[0], 0)
        # Without a base URL: the file path, and no QR code.
        os.environ["INBOUNDS_SUB_BASE_URL"] = ""
        self.assertEqual(ok(ctl._inbound_subscriptions, "fufsob"), self.path("subs") + "/aaa\n")
        self.assertNotEqual(run(ctl._inbound_subscriptions, "fufsob", "--qr")[0], 0)


class AppsRunTest(EnvTest):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.active = set()
        self.execed = None
        os.environ.update(
            PER_APP_ROUTING_ENABLED="1",
            PER_APP_ROUTING_PROXYCHAINS_ENABLED="1",
            PER_APP_ROUTING_TUN_ENABLED="1",
            PER_APP_ROUTING_TPROXY_ENABLED="1",
            PER_APP_ROUTING_ZAPRET_ENABLED="1",
            PROXYCHAINS_QUIET_ARG="-q",
            PROXYCHAINS_CONFIG=self.write("proxychains.conf", ""),
            PER_APP_ROUTING_PROFILES_FILE=self.write(
                "profiles.json",
                [{"name": n, "route": n} for n in ("direct", "proxychains", "tun", "tproxy", "zapret")],
            ),
        )

        def systemctl(*args, **kw):
            self.calls.append(args)
            if args[:2] == ("is-active", "--quiet"):
                return (0 if args[2] in self.active else 3), ""
            return 0, ""

        def exec_(argv):
            self.execed = argv
            raise SystemExit(0)

        self.patch("systemctl", systemctl)
        self.patch("_exec", exec_)
        self.patch("_run_foreground", lambda argv: self.calls.append(tuple(argv)) or self.scope_status)
        self.scope_status = 0
        self.addCleanup(lambda: ctl.signal.signal(ctl.signal.SIGTERM, ctl.signal.SIG_DFL))

    def test_direct_and_proxychains_exec(self):
        run(ctl.cmd_apps, "run", "direct", "--", "firefox", "-P")
        self.assertEqual(self.execed, ["firefox", "-P"])
        run(ctl.cmd_apps, "run", "proxychains", "--", "curl", "x")
        self.assertEqual(self.execed, ["proxychains4", "-q", "-f", os.environ["PROXYCHAINS_CONFIG"], "curl", "x"])
        os.environ["PROXYCHAINS_CONFIG"] = self.path("missing.conf")
        self.assertIn("Proxychains config is not readable", run(ctl.cmd_apps, "run", "proxychains", "--", "curl")[2])

    def test_slice_routes(self):
        for route in ("tun", "tproxy", "zapret"):
            self.calls.clear()
            status, _, _ = run(ctl.cmd_apps, "run", route, "--", "curl", "x")
            self.assertEqual(status, 0)
            base = f"proxy-suite-per-app-{route}"
            scope = next(c for c in self.calls if c[0] == "systemd-run")
            self.assertIn(f"--unit={base}-{route}-{os.getpid()}", scope)
            self.assertIn(f"--slice={base}", scope)
            self.assertEqual(scope[-2:], ("curl", "x"))
            self.assertIn(("start", f"{base}-user@{os.getuid()}.service"), self.calls)
            # Nothing else runs in the slice, so it is torn down afterwards.
            self.assertIn(("stop", f"{base}.service"), self.calls)
            self.assertIn(("--user", "stop", f"{base}-anchor.service"), self.calls)

    def test_cleanup_when_scope_fails(self):
        self.scope_status = 3
        status, _, _ = run(ctl.cmd_apps, "run", "tun", "--", "false")
        self.assertEqual(status, 3)
        self.assertIn(("stop", "proxy-suite-per-app-tun.service"), self.calls)

    def test_global_proxy_refused(self):
        self.active = {"proxy-suite-tun.service"}
        status, _, err = run(ctl.cmd_apps, "run", "tproxy", "--", "curl")
        self.assertNotEqual(status, 0)
        self.assertIn("Global proxy-suite-tun.service is active", err)
        self.assertFalse(any(c[0] == "systemd-run" for c in self.calls))

    def test_disabled_route(self):
        os.environ["PER_APP_ROUTING_ZAPRET_ENABLED"] = "0"
        self.assertIn("perAppRouting.zapret.enable is false", run(ctl.cmd_apps, "run", "zapret", "--", "curl")[2])


class OutboundTestTest(EnvTest):
    def setUp(self):
        super().setUp()
        os.environ["OUTBOUND_INVENTORY_FILE"] = self.write("outbounds.json", {"tags": ["own-vps", "de", "wg"], "selection": "first"})
        self.write(
            "outbound-test.json",
            {
                "port": 18537,
                "selector": "proxy-suite-test",
                "url": "https://t.test/204",
                # selection = "first": the backend knows the pick as "proxy".
                "outbounds": {"own-vps": "proxy", "de": "de", "wg": "wg"},
            },
        )
        self.calls = []

        def clash(method, path, body=None, timeout=10):
            self.calls.append((method, path, body))
            if path.startswith("/proxies/de/delay"):
                return 503, {"message": "An error occurred in the delay test"}
            if method == "GET":
                return 200, {"delay": 88}
            return 204, None

        self.patch("_clash", clash)
        self.patch("_timed_download", lambda port: 12.34)

    def test_ping(self):
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            port = server.getsockname()[1]
            self.assertRegex(ctl._test_ping({"server": "127.0.0.1", "port": port, "network": "tcp"}), r"^\d+ ms$")
        self.assertEqual(ctl._test_ping({"server": "127.0.0.1", "port": port}), "refused")
        # No TCP handshake to time on a QUIC or WireGuard server.
        self.assertEqual(ctl._test_ping({"server": "127.0.0.1", "port": port, "network": "udp"}), "udp")
        self.assertEqual(ctl._test_ping(None), "-")

    def test_every_test(self):
        self.write("outbound-endpoints.json", {"own-vps": {"server": "127.0.0.1", "port": 9, "network": "udp"}})
        out = ok(ctl.cmd_outbounds, "test", "--ping", "--delay", "--download")
        self.assertRegex(out, r"(?m)^  TAG +PING +DELAY +DOWNLOAD$")
        self.assertRegex(out, r"(?m)^  own-vps +udp +88 ms +12\.3 Mbit/s$")
        self.assertRegex(out, r"(?m)^  de +- +failed +12\.3 Mbit/s$")
        self.assertTrue(any(c[1].startswith("/proxies/proxy/delay?") and "t.test" in c[1] for c in self.calls))
        # Downloads switch the test selector, one outbound at a time, in order.
        puts = [c for c in self.calls if c[0] == "PUT"]
        self.assertEqual([c[2]["name"] for c in puts], ["proxy", "de", "wg"])
        self.assertEqual({c[1] for c in puts}, {"/proxies/proxy-suite-test"})

    def test_default_and_arguments(self):
        out = ok(ctl.cmd_outbounds, "test", "de")
        self.assertEqual(ctl.lines(out)[0], "  TAG         PING        DELAY")
        self.assertEqual(len(ctl.lines(out)), 2)
        self.assertFalse(any(c[0] == "PUT" for c in self.calls))
        self.assertNotEqual(run(ctl.cmd_outbounds, "test", "nope")[0], 0)
        self.assertNotEqual(run(ctl.cmd_outbounds, "test", "--bogus")[0], 0)

    def test_without_sing_box(self):
        # Pure XRay: servers, but no test listener.
        os.remove(self.path("outbound-test.json"))
        status, out, err = run(ctl.cmd_outbounds, "test")
        self.assertEqual(status, 0)
        self.assertEqual(ctl.lines(out)[0], "  TAG         PING")
        self.assertIn("sing-box or hybrid", err)
        status, _, err = run(ctl.cmd_outbounds, "test", "--download")
        self.assertNotEqual(status, 0)
        self.assertIn("sing-box or hybrid", err)

    @unittest.skipIf(os.geteuid() == 0, "root reads anything")
    def test_unreadable_servers(self):
        os.chmod(self.write("outbound-endpoints.json", {}), 0)
        status, _, err = run(ctl.cmd_outbounds, "test", "--ping")
        self.assertEqual(status, 0)
        self.assertIn("enable userControl, or run with sudo", err)


if __name__ == "__main__":
    unittest.main()
