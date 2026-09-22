#!/usr/bin/env python3

import contextlib
import datetime
import io
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import unittest
from unittest import mock

import proxy_ctl as ctl


def setUpModule():
    """proxy_model, once imported into the same run, patches proxy_ctl for the front ends;
    these tests want it the way the CLI runs."""
    model = sys.modules.get("proxy_model")
    for name, fn in (model.CLI_FUNCTIONS if model else {}).items():
        patcher = mock.patch.object(ctl, name, fn)
        patcher.start()
        unittest.addModuleCleanup(patcher.stop)


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


class StubResolverTest(unittest.TestCase):
    def resolv(self, content):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False)
        tmp.write(content)
        tmp.close()
        self.addCleanup(os.unlink, tmp.name)
        return tmp.name

    def test_only_stub_nameservers_are_reported(self):
        path = self.resolv("nameserver 127.0.0.53\noptions edns0\n")
        assert ctl._stub_resolver_nameservers(path) == ["127.0.0.53"]

    def test_a_real_resolver_alongside_the_stub_is_not_a_leak(self):
        path = self.resolv("nameserver 127.0.0.53\nnameserver 192.168.1.1\n")
        assert ctl._stub_resolver_nameservers(path) == []

    def test_missing_resolv_conf_is_quiet(self):
        assert ctl._stub_resolver_nameservers("/nonexistent/resolv.conf") == []

    def test_wrap_warns_once_on_the_stub(self):
        with mock.patch.object(ctl, "_stub_resolver_nameservers", return_value=["127.0.0.53"]):
            status, out, err = run(ctl._warn_stub_resolver, "tun")
        assert status == 0, (status, out, err)
        assert "route=tun" in err
        assert "127.0.0.53" in err


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


class ClashApiTest(EnvTest):
    def test_unset_api_reads_as_unreachable(self):
        # The XRay backend leaves the API off; a bare
        # path is not a URL, and it used to escape as a traceback out of
        # `status`, `where` and `proxy outbounds`.
        for value in ("", "127.0.0.1:9090"):
            with self.subTest(api=value), mock.patch.dict(os.environ, {"CLASH_API": value}):
                self.assertEqual(ctl._clash("GET", "/proxies/proxy", timeout=1), (0, None))
                self.assertEqual(ctl._outbound_current(), "")


# The verdict table, fed tuples measured on a real censored network.
class ProbeVerdictTest(unittest.TestCase):
    def expect(self, want, direct, via):
        self.assertEqual(ctl._probe_verdict(direct, via), want, (direct, via))

    def test_table(self):
        # Origin refuses direct, accepts the proxy: chatgpt.com/robots.txt.
        self.expect("destination", "0|0.146175|403|6633||", "0|0.230116|200|4302||")
        # The same through a redirect: claude.ai/robots.txt.
        self.expect("destination", "0|0.141625|302|143||https://claude.com/app-unavailable-in-region", "0|0.181276|200|281||")
        # TLS never completed: censorship, zapret's job.
        self.expect("censor", "35|0.000000|000|0||", "0|0.119348|200|6258||")
        # Handshake, then silence: the post-handshake throttle.
        self.expect("censor", "0|0.125029|000|0||", "0|0.143772|200|32881||")
        # Direct works. Nothing to do, whoever else also works.
        self.expect("ok", "0|0.099546|200|2678||", "0|0.146822|200|2678||")
        # robots.txt legitimately absent is not a failure.
        self.expect("ok", "0|0.161330|404|559||", "0|0.214667|404|559||")
        # An ordinary redirect must not read as a block.
        self.expect("ok", "0|0.10|301|0||https://www.example.com/robots.txt", "0|0.20|301|0||https://www.example.com/robots.txt")
        # Refused everywhere: not an egress problem.
        self.expect("both-fail", "0|0.10|403|100||", "0|0.20|403|100||")
        # AWS WAF's page for direct, the origin's own 403 through the proxy: it got
        # past the wall (game-version.sekai.colorfulpalette.org, S3 behind CloudFront).
        self.expect("destination", "0|0.12|403|919|aws-waf|", "0|0.19|403|243||")
        # A wall everywhere is not an egress problem either (a bot challenge, say).
        self.expect("both-fail", "0|0.12|403|919|aws-waf|", "0|0.19|403|919|aws-waf|")
        # A country refused is an ordinary refusal: nothing to get past.
        self.expect("both-fail", "0|0.12|403|500|cloudfront-geo|", "0|0.19|403|243||")
        # Nothing reaches it at all - a dead name, not a blocked one.
        self.expect("unreachable", "6|0.000000|000|0||", "35|0.000000|000|0||")


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

    def test_block_pages(self):
        waf_head = "HTTP/2 403\r\nserver: CloudFront\r\nx-cache: Error from cloudfront\r\n\r\n"
        waf_body = "<H1>403 ERROR</H1>\n<H2>The request could not be satisfied.</H2>\n<HR noshade size=\"1px\">\nRequest blocked.\n"
        pages = {
            # Measured through two exits: AWS WAF's page, and past it S3 refusing "/".
            "waf.test": ("403", waf_head, waf_body),
            "s3.test": ("403", "HTTP/2 403\r\nserver: AmazonS3\r\n\r\n", "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>"),
            "cf.test": ("403", "HTTP/2 403\r\nserver: cloudflare\r\n\r\n", '<span class="cf-error-code">1020</span>'),
            "cfgeo.test": ("403", "HTTP/2 403\r\nserver: cloudflare\r\n\r\n", "error code: 1009"),
            # Content that merely quotes a block page is content.
            "article.test": ("200", waf_head, waf_body),
        }

        def curl(argv):
            code, head, body = pages[argv[-1].split("/")[2]]
            for flag, text in (("-D", head), ("-o", body)):
                with open(argv[argv.index(flag) + 1], "w") as f:
                    f.write(text)
            return 0, f"0|0.1|{code}|{len(body)}|"

        self.patch("run_curl", curl)
        got = {}
        for host in pages:
            result = ctl._probe_fetch(host, "/", "--noproxy", "*")
            got[host] = (ctl._probe_field(result, 5), ctl._probe_exit_verdict(result))
        self.assertEqual(
            got,
            {
                "waf.test": ("aws-waf", "wall"),
                "s3.test": ("", "blocked"),
                "cf.test": ("cloudflare", "wall"),
                "cfgeo.test": ("cloudflare-geo", "blocked"),
                "article.test": ("", "ok"),
            },
        )

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
        out = self.probe_with("0|0.11|403|424||", "0|0.17|200|59809||", "0|0.11|200|400||", "0|0.17|200|400||")
        self.assertEqual((out["verdict"], out["url"]), ("destination", "https://example.test/"))

    def test_robots_breaks_ties(self):
        # chatgpt.com: apex 403 everywhere, robots.txt separates.
        out = self.probe_with("0|0.14|403|6633||", "0|0.23|403|8442||", "0|0.14|403|6633||", "0|0.23|200|4302||")
        self.assertEqual((out["verdict"], out["url"]), ("destination", "https://example.test/robots.txt"))

    def test_working_apex_is_not_second_guessed(self):
        out = self.probe_with("0|0.10|200|500||", "0|0.20|200|500||", "0|0.10|403|10||", "0|0.20|200|10||")
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
        self.use_exits(lambda domain, path, flag, url: "0|0.10|200|500||" if url.endswith(":18542") else "0|0.10|403|919||")
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
        self.use_exits(lambda domain, path, flag, url: "0|0.10|403|190240||" if url.endswith(":18541") and path == "/" else "0|0.10|200|500||")
        self.assertEqual(self.probe("--via", "fi", "geo.test")["verdict"], "blocked")

    def test_via_robots_decides(self):
        # i.pximg.net: the front page is 400 everywhere, so robots.txt decides.
        self.use_exits(lambda domain, path, flag, url: "0|0.10|400|0||" if path == "/" else "0|0.10|200|43||")
        self.assertEqual(self.probe("--via", "fi", "cdn.test")["verdict"], "ok")

    def test_past_a_wall(self):
        # game-version.sekai.colorfulpalette.org: AWS WAF for direct and fi, S3's own 403 for de.
        self.use_exits(lambda domain, path, flag, url: "0|0.19|403|243||" if url.endswith(":18542") else "0|0.12|403|919|aws-waf|")
        out = self.probe("sekai.test")
        self.assertEqual((out["verdict"], out["exit"], out["path"]), ("destination", "de", "/"))
        self.assertEqual(
            [(e["tag"], e["judgement"], e["block"]) for e in out["exits"]],
            [("direct", "wall", "aws-waf"), ("fi", "wall", "aws-waf"), ("de", "blocked", "")],
        )
        # Walled everywhere: nobody got past.
        self.use_exits(lambda domain, path, flag, url: "0|0.12|403|919|aws-waf|")
        self.assertEqual(self.probe("sekai.test")["verdict"], "both-fail")

    def test_text_output(self):
        self.use_exits(lambda domain, path, flag, url: "0|0.10|200|500||" if url.endswith(":18542") else "0|0.10|403|919||")
        out = ok(ctl.cmd_proxy_probe, "sekai.test")
        self.assertRegex(out, r"(?m)^    de +/ +TLS 0\.10s, 200, 500 bytes +ok  <- chosen$")
        self.assertIn('pin: proxy.routing.rules = [ { outbound = "de"; domains = [ "sekai.test" ]; } ]', out)


class ServiceManagerTest(EnvTest):
    def calls(self):
        seen = []
        self.patch("_run", lambda argv, **kw: seen.append(argv) or (0, ""))
        return seen

    def test_system_units(self):
        seen = self.calls()
        ctl.systemctl("--user", "start", "anchor.service")
        ctl.systemctl("start", "proxy-suite-socks")
        self.assertEqual(seen, [["systemctl", "--user", "start", "anchor.service"], ["systemctl", "start", "proxy-suite-socks"]])
        self.assertEqual(ctl.journal_hint("proxy-suite-autoproxy-learn", 20), "journalctl -u proxy-suite-autoproxy-learn -n 20")

    def test_kill_switch_lifts_only_on_purpose(self):
        seen = self.calls()
        stops = lambda: [argv[2] for argv in seen if argv[1] == "stop"]
        ctl.cmd_proxy("tun", "on")
        self.assertEqual(stops(), [])
        ctl.cmd_proxy("tun", "off")
        self.assertEqual(stops(), ["proxy-suite-tun", ctl.KILL_SWITCH])
        seen.clear()
        ctl.cmd_proxy("off")
        self.assertEqual(stops(), ["proxy-suite-tproxy", "proxy-suite-tun", ctl.KILL_SWITCH, "proxy-suite-socks"])
        # A profile that already failed is not active, and its kill switch still lifts.
        seen.clear()
        self.patch("_active_awg_profiles", lambda: [])
        ctl.cmd_awg("off")
        self.assertEqual(stops(), [ctl.KILL_SWITCH])
        seen.clear()
        ctl.COMMANDS["killswitch"]("off")
        self.assertEqual(stops(), [ctl.KILL_SWITCH])

    def test_rulesets_list(self):
        self.calls()
        with tempfile.TemporaryDirectory() as tmp:
            fetched = os.path.join(tmp, "antifilter.srs")
            with open(fetched, "wb") as handle:
                handle.write(b"SRS" + b"\0" * 29)
            listing = os.path.join(tmp, "rulesets.json")
            with open(listing, "w", encoding="utf-8") as handle:
                json.dump([{"name": "antifilter", "path": fetched}, {"name": "gone", "path": os.path.join(tmp, "x.srs")}], handle)
            os.environ["RULE_SETS_FILE"] = listing
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                ctl.cmd_proxy("rulesets")
        rows = out.getvalue().splitlines()
        self.assertRegex(rows[1], r"^  antifilter +\d{4}-\d\d-\d\d \d\d:\d\d:\d\d +32$")
        self.assertRegex(rows[2], r"^  gone +\(missing\) +-$")

    def test_user_units(self):
        # home-manager: every unit is the user's, and a --user of the caller's is not doubled.
        os.environ["SERVICE_MANAGER"] = "systemd-user"
        seen = self.calls()
        ctl.systemctl("--user", "stop", "anchor.service")
        ctl._unit_states(["proxy-suite-socks"])
        self.assertEqual(seen[0], ["systemctl", "--user", "stop", "anchor.service"])
        self.assertEqual(seen[1][:3], ["systemctl", "--user", "show"])
        self.assertEqual(ctl.journal_hint("proxy-suite-socks"), "journalctl --user -u proxy-suite-socks")

    def test_supervisor_units(self):
        # nix-on-droid: proxy-suitectl stands in for systemctl and journalctl.
        os.environ.update(SERVICE_MANAGER="supervisor", SUPERVISOR_CTL="/bin/proxy-suitectl")
        seen = self.calls()
        ctl.systemctl("--user", "stop", "anchor.service")
        ctl._unit_states(["proxy-suite-socks"])
        self.assertEqual(seen[0], ["/bin/proxy-suitectl", "stop", "anchor.service"])
        self.assertEqual(seen[1][:2], ["/bin/proxy-suitectl", "show"])
        self.assertEqual(ctl.journal_hint("proxy-suite-socks", 5), "/bin/proxy-suitectl journal -u proxy-suite-socks -n 5")

    def test_paths_follow_host_dirs(self):
        for name in ("SUB_CACHE_DIR", "AUTOPROXY_STATE_DIR", "INBOUNDS_STATS_FILE", "OUTBOUND_INVENTORY_FILE"):
            os.environ.pop(name, None)
        os.environ.update(STATE_DIR="/home/u/.local/state/proxy-suite", RUNTIME_DIR="/tmp/ps")
        self.assertEqual(ctl._autoproxy_dir(), "/home/u/.local/state/proxy-suite/autoproxy")
        self.assertEqual(os.path.dirname(ctl._subscription_cache("x")), "/home/u/.local/state/proxy-suite/subscriptions")

    def test_rootless_hosts_never_ask_for_root(self):
        self.assertIn("sudo", ctl.ask_group())
        os.environ["PRIVILEGED"] = "0"
        self.assertNotIn("sudo", ctl.ask_group())


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

    def test_forget(self):
        state = {
            "domains": {"last.fm": {"verdict": "destination", "exit": "primary", "host": "www.last.fm"}},
            "hosts": {"www.last.fm": {"domain": "last.fm", "verdict": "destination", "exit": "primary"}},
        }
        self.write("state.json", state)
        started = []
        self.patch("systemctl", lambda *args, **kw: started.append(args) or (0, ""))
        # A host names its domain: the route is the domain's.
        out = ok(ctl.cmd_proxy_forget, "www.last.fm")
        self.assertEqual(ctl.read_text(self.path("edits")), "forget last.fm\n")
        self.assertEqual(started, [("start", "proxy-suite-autoproxy-learn.service")])
        self.assertIn("Forgot last.fm (was via primary)", out)
        self.assertNotEqual(run(ctl.cmd_proxy_forget, "x;rm -rf /")[0], 0)

    def test_relearn(self):
        before = {
            "domains": {"last.fm": {"verdict": "destination", "exit": "primary", "host": "www.last.fm"}},
            "hosts": {"www.last.fm": {"domain": "last.fm", "verdict": "destination", "exit": "primary"}},
        }
        self.write("state.json", before)
        self.state_on_start(before)  # the same exit wins again
        out = ok(ctl.cmd_proxy_relearn, "last.fm")
        # Forgotten first, then probed again from the host it was learned from.
        self.assertEqual(ctl.read_text(self.path("edits")), "forget last.fm\n")
        self.assertEqual(ctl.read_text(self.path("requests")), "www.last.fm\n")
        self.assertIn("probing www.last.fm", out)
        self.assertIn("proxy-ctl proxy outbounds disable primary", out)

    def test_clear(self):
        self.patch("systemctl", lambda *args, **kw: (1, ""))
        status, _, err = run(ctl.cmd_proxy_clear)
        self.assertNotEqual(status, 0)
        self.assertIn("still queued", err)
        self.assertEqual(ctl.read_text(self.path("edits")), "clear\n")

    @unittest.skipIf(os.geteuid() == 0, "root reads anything")
    def test_unreadable_state_asks_for_sudo(self):
        os.chmod(self.dir, 0)
        try:
            status, _, err = run(ctl.cmd_proxy_queue)
        finally:
            os.chmod(self.dir, 0o755)
        self.assertNotEqual(status, 0)
        self.assertIn("proxy-suite group, or re-run with sudo", err)


class RuntimeEntryTest(EnvTest):
    def setUp(self):
        super().setUp()
        os.environ.update(
            RUNTIME_OUTBOUNDS_DIR=self.path("outbounds.d"),
            RUNTIME_SUBS_DIR=self.path("subscriptions.d"),
            SUB_CACHE_DIR=self.path("subscriptions"),
            OUTBOUND_INVENTORY_FILE=self.path("outbounds.json"),
            SUB_TAGS_FILE=self.write("sub-tags.json", ["provider"]),
        )
        os.makedirs(self.path("outbounds.d"))
        os.makedirs(self.path("subscriptions.d"))
        self.declared, self.pinned, self.started = ["primary", "vless-example"], "", []
        self.backend_start()
        self.patch("systemctl", self.systemctl)

    def backend_start(self):
        """What the start script leaves: runtime entries and disable markers read into the inventory."""
        names = os.listdir(self.path("outbounds.d"))
        tags = self.declared + ctl._runtime_tags("outbound")
        disabled = [t for t in tags if f"{t}.disabled" in names]
        if self.pinned in disabled:
            self.pinned = ""
        self.write("outbounds.json", {"tags": tags, "pinned": self.pinned, "excluded": disabled, "disabled": disabled})
        for tag in ctl._runtime_tags("subscription"):
            self.write(f"subscriptions/{tag}.json", {"outbounds": []})

    def systemctl(self, *args, **kw):
        self.started.append(args[1] if args[:1] == ("start",) else args)
        if args[1:] == ("proxy-suite-outbound-reload.service",) and os.path.exists(self.path(f"outbounds.d/{self.pinned}.disabled")):
            self.pinned = ""
        self.backend_start()
        return 0, ""

    def test_tag_for(self):
        tag = ctl._runtime_tag_for
        self.assertEqual(tag("outbound", "vless://u@de1.example.net:443?security=reality#%F0%9F%87%A9%F0%9F%87%AA%20DE-1"), "DE-1")
        self.assertEqual(tag("outbound", "trojan://p@1.2.3.4:443"), "trojan-1.2.3.4")
        # Declared tags are taken as much as runtime ones.
        self.assertEqual(tag("outbound", "vless://u@www.example.org:443"), "vless-example-2")
        self.assertEqual(tag("outbound", '{"type": "socks", "server": "127.0.0.1"}'), "socks")
        self.assertEqual(tag("outbound", '{"tag": "proxy", "type": "socks"}'), "proxy-2")  # reserved
        self.assertEqual(tag("outbound", "vmess://" + __import__("base64").b64encode(b'{"ps": "JP 2", "add": "jp.test"}').decode()), "JP-2")
        self.assertEqual(tag("outbound", "{not json"), "outbound")
        self.assertEqual(tag("subscription", "https://sub.provider.com/api/v1/client?token=x"), "provider-2")
        self.assertEqual(tag("subscription", "https://panel.work.test/s#" + "x" * 40), "x" * 32)
        self.write("outbounds.d/DE-1.url", "vless://u@de1.example.net:443\n")
        self.assertEqual(tag("outbound", "vless://u@x:1#DE-1"), "DE-1-2")

    def test_add_forms(self):
        # A URL alone: the tag comes from it.
        out = ok(ctl.cmd_subscription, "add", "https://sub.work.test/s")
        self.assertIn("Tag: work (none given", out)
        self.assertEqual(ctl.read_text(self.path("subscriptions.d/work.url")), "https://sub.work.test/s\n")
        # Tag, then URL.
        ok(ctl.cmd_subscription, "add", "home", "https://sub.home.test/s")
        self.assertTrue(os.path.exists(self.path("subscriptions.d/home.url")))
        # The other way round is a mistake worth naming.
        status, _, err = run(ctl.cmd_subscription, "add", "https://sub.x.test/s", "x")
        self.assertNotEqual(status, 0)
        self.assertIn("The tag goes first", err)
        self.assertNotEqual(run(ctl.cmd_subscription, "add", "lonely")[0], 0)
        # Outbound JSON alone, and a JSON-looking word for a subscription is not a source.
        self.assertIn("Tag: socks", ok(ctl.cmd_outbounds, "add", '{"type": "socks", "server": "127.0.0.1", "server_port": 1080}'))
        self.assertTrue(os.path.exists(self.path("outbounds.d/socks.json")))
        self.assertNotEqual(run(ctl.cmd_subscription, "add", "-")[0], 0)

    def test_disable_enable(self):
        self.pinned = "primary"
        self.backend_start()
        out = ok(ctl.cmd_outbounds, "disable", "primary")
        self.assertTrue(os.path.exists(self.path("outbounds.d/primary.disabled")))
        # The reload drops the pin with it.
        self.assertEqual(self.started, ["proxy-suite-outbound-reload.service"])
        self.assertEqual(ctl._outbound_inventory()["pinned"], "")
        self.assertIn("Disabled: primary", out)
        self.assertIn("Already disabled", ok(ctl.cmd_outbounds, "disable", "primary"))
        # The last one selection could pick stays.
        status, _, err = run(ctl.cmd_outbounds, "disable", "vless-example")
        self.assertNotEqual(status, 0)
        self.assertIn("only outbound", err)
        self.assertNotEqual(run(ctl.cmd_outbounds, "disable", "nope")[0], 0)
        self.assertNotEqual(run(ctl.cmd_pin, "primary")[0], 0)

        self.started.clear()
        self.assertIn("Enabled: primary", ok(ctl.cmd_outbounds, "enable", "primary"))
        self.assertFalse(os.path.exists(self.path("outbounds.d/primary.disabled")))
        self.assertEqual(self.started, ["proxy-suite-outbound-reload.service"])
        self.assertNotEqual(run(ctl.cmd_outbounds, "enable", "primary")[0], 0)
        self.assertNotEqual(run(ctl.cmd_outbounds, "enable", "../primary")[0], 0)

    @unittest.skipIf(os.geteuid() == 0, "root reads anything")
    def test_rm_says_so_when_the_dir_is_out_of_reach(self):
        """outbounds.d is root-only without the group: the entry is there, it just cannot be seen."""
        ok(ctl.cmd_outbounds, "add", "de", "vless://u@de.test:443")
        os.chmod(self.path("outbounds.d"), 0o000)
        try:
            status, _, err = run(ctl.cmd_outbounds, "rm", "de")
        finally:
            os.chmod(self.path("outbounds.d"), 0o700)
        self.assertNotEqual(status, 0)
        self.assertIn("Cannot see the entry for 'de'", err)
        self.assertNotIn("No runtime outbound", err)

    def share(self, outbounds):
        """outbound-share.json as the socks start script writes it, beside the inventory."""
        self.write("outbound-share.json", {"outbounds": outbounds})

    def test_chain_copies_an_existing_outbound_through_a_hop(self):
        self.share({"primary": {"url": "vless://u@de.test:443"}, "vless-example": {"url": "vless://u@nl.test:443"}})
        out = ok(ctl.cmd_outbounds, "chain", "primary", "vless-example")
        self.assertIn("Tag: primary-via-vless-example", out)
        self.assertEqual(ctl.read_text(self.path("outbounds.d/primary-via-vless-example.url")), "vless://u@de.test:443\n")
        self.assertEqual(ctl.read_text(self.path("outbounds.d/primary-via-vless-example.detour")), "vless-example\n")
        # The original is untouched: a detour belongs to the outbound carrying it.
        self.assertFalse(os.path.exists(self.path("outbounds.d/primary.detour")))
        self.assertEqual(self.started, ["proxy-suite-outbound-reload.service"])
        # A name of one's own, and a second copy of the same pair gets its own tag.
        ok(ctl.cmd_outbounds, "chain", "primary", "vless-example", "de-via-nl")
        self.assertTrue(os.path.exists(self.path("outbounds.d/de-via-nl.url")))
        self.assertIn("Tag: primary-via-vless-example-2", ok(ctl.cmd_outbounds, "chain", "primary", "vless-example"))

    def test_chain_without_a_url_copies_the_backend_json(self):
        self.share({"primary": {"outbound": {"tag": "primary", "type": "socks", "server": "1.2.3.4", "routing_mark": 99}}})
        ok(ctl.cmd_outbounds, "chain", "primary", "vless-example", "hop")
        written = json.loads(ctl.read_text(self.path("outbounds.d/hop.json")))
        # Portable and untagged: the entry's name is the tag, and the host's mark is not shared.
        self.assertEqual(written, {"type": "socks", "server": "1.2.3.4"})

    def test_chain_refuses_what_it_cannot_chain(self):
        self.share({"primary": {"url": "vless://u@de.test:443"}, "vless-example": {}})
        for args, message in (
            (("chain",), "proxy outbounds chain"),
            (("chain", "primary"), "proxy outbounds chain"),
            (("chain", "primary", "primary"), "cannot chain through itself"),
            (("chain", "nope", "primary"), "Unknown outbound: nope"),
            (("chain", "primary", "nope"), "Cannot chain through 'nope'"),
            (("chain", "vless-example", "primary"), "Nothing to copy from 'vless-example'"),
        ):
            with self.subTest(args=args):
                status, _, err = run(ctl.cmd_outbounds, *args)
                self.assertNotEqual(status, 0)
                self.assertIn(message, err)
        self.assertEqual(os.listdir(self.path("outbounds.d")), [])

    def test_rm_takes_the_marker_along(self):
        ok(ctl.cmd_outbounds, "add", "de", "vless://u@de.test:443")
        ok(ctl.cmd_outbounds, "disable", "de")
        ok(ctl.cmd_outbounds, "rm", "de")
        self.assertEqual(os.listdir(self.path("outbounds.d")), [])


class ZapretAutoTest(EnvTest):
    @unittest.skipIf(os.geteuid() == 0, "root writes anything")
    def test_clear_replaces_what_it_cannot_write(self):
        """The group writes the state directory, not root's list files in it."""
        os.environ.update(ZAPRET_AUTO_ENABLED="1", ZAPRET_STATE_DIR=self.dir)
        auto = self.write("zapret-hosts-auto.txt", "a.example\n")
        state = self.write("circular/state.tsv", "1\ta.example\n")
        os.chmod(auto, 0o444)
        os.chmod(state, 0o444)
        ok(ctl.cmd_zapret_auto, "clear")
        self.assertEqual(ctl.read_text(auto), "")
        self.assertEqual(ctl.read_text(state), "")


class InboundsTest(EnvTest):
    def test_stats(self):
        self.patch("systemctl", lambda *args, **kw: (0, ""))
        self.patch("_today", lambda: datetime.date(2026, 9, 11))
        os.environ["INBOUNDS_STATS_FILE"] = self.write(
            "stats.json",
            {
                "days": {
                    "2026-09-11": {
                        "user": {"fufsob": {"down": 6000000, "up": 4000}, "phone": {"up": 0}},
                        "outbound": {"direct": {"down": 7, "up": 8}},
                    },
                    "2026-09-10": {"user": {"fufsob": {"down": 1073741824, "up": 1048576}}},
                    "2026-09-01": {"user": {"fufsob": {"down": 1, "up": 1}}},
                }
            },
        )
        out = ok(ctl._inbound_stats, "2")
        self.assertNotIn("direct", out)
        self.assertRegex(ok(ctl._inbound_stats, "--by", "outbound"), r"(?m)^  2026-09-11 +direct +7 B +8 B$")
        self.assertNotEqual(run(ctl._inbound_stats, "--by", "listener")[0], 0)
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

    def test_online(self):
        answer = {"users": [{"email": "fufsob", "ips": [{"ip": "203.0.113.7", "lastSeen": 1789471207}]}]}
        self.patch("_run", lambda *a, **kw: (0, json.dumps(answer)))
        os.environ["INBOUNDS_STATS_FILE"] = self.write("stats.json", {"seen": {"phone": 1789135690}})
        os.environ["INBOUNDS_LINKS_FILE"] = self.write("links.json", [{"tag": "a", "user": "fufsob"}, {"tag": "a", "user": "teri"}])
        out = ok(ctl._inbound_online)
        self.assertRegex(out, r"(?m)^  fufsob +online +203\.0\.113\.7$")
        self.assertRegex(out, r"(?m)^  phone +seen 2026-09-1\d \d\d:\d\d")
        self.assertRegex(out, r"(?m)^  teri +never seen")
        # XRay not running is an error, not an empty table.
        self.patch("_run", lambda *a, **kw: (1, ""))
        self.assertNotEqual(run(ctl._inbound_online)[0], 0)

    def test_online_amneziawg(self):
        answer = {"users": [{"email": "fufsob", "ips": [{"ip": "203.0.113.7", "lastSeen": 1789471207}]}]}
        self.patch("_run", lambda *a, **kw: (0, json.dumps(answer)))
        started = []
        self.patch("systemctl", lambda *a, **kw: started.append(a))
        now = 1789471300
        self.patch("time", mock.Mock(time=lambda: now))
        os.environ["INBOUNDS_STATS_FILE"] = self.write(
            "stats.json",
            {
                "seen": {"phone": now - 600, "laptop": now - 30},
                "awgPeers": {
                    "phone": {"tag": "awg", "handshake": now - 600, "endpoint": "198.51.100.2:5000"},
                    "laptop": {"tag": "awg", "handshake": now - 30, "endpoint": "[2001:db8::5]:51820"},
                    "tablet": {"tag": "awg", "handshake": 0, "endpoint": None},
                },
            },
        )
        os.environ["INBOUNDS_LINKS_FILE"] = self.write(
            "links.json", [{"tag": "a", "user": "fufsob", "type": "vless"}, {"tag": "awg", "user": "tablet", "type": "amneziawg"}]
        )
        out = ok(ctl._inbound_online)
        # The collector reads the handshakes first.
        self.assertEqual(started, [("--no-ask-password", "start", "proxy-suite-inbound-stats.service")])
        self.assertRegex(out, r"(?m)^  fufsob +online +203\.0\.113\.7$")
        self.assertRegex(out, r"(?m)^  laptop +online +2001:db8::5$")
        self.assertRegex(out, r"(?m)^  phone +seen ")
        self.assertRegex(out, r"(?m)^  tablet +never seen")

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
                "outbounds": {"own-vps": "own-vps", "de": "de", "wg": "wg"},
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
        self.assertTrue(any(c[1].startswith("/proxies/own-vps/delay?") and "t.test" in c[1] for c in self.calls))
        # Downloads switch the test selector, one outbound at a time, in order.
        puts = [c for c in self.calls if c[0] == "PUT"]
        self.assertEqual([c[2]["name"] for c in puts], ["own-vps", "de", "wg"])
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
        self.assertIn("proxy-suite group, or re-run with sudo", err)


class ShareTest(EnvTest):
    def setUp(self):
        super().setUp()
        os.environ["OUTBOUND_INVENTORY_FILE"] = self.write("outbounds.json", {"tags": ["vps", "warp"], "sources": {}})
        os.environ["INBOUNDS_ENABLED"] = "1"
        os.environ["INBOUNDS_LINKS_FILE"] = self.write(
            "inbounds/links.json", [{"tag": "in", "user": "u", "link": "vless://x@h:443", "outbound": {"type": "vless"}}]
        )
        self.write("inbounds/config.json", {"inbounds": [{"tag": "in", "protocol": "vless"}]})
        self.share = self.write(
            "outbound-share.json",
            {
                "outbounds": {
                    "vps": {"url": "vless://x@vps.test:443", "outbound": {"type": "vless", "tag": "vps", "server": "vps.test"}},
                    "warp": {"url": None, "outbound": {"type": "socks", "tag": "warp", "server": "127.0.0.1"}},
                },
                "subscriptions": {"community": "https://sub.test/t"},
            },
        )
        self.write(
            "config.json",
            {"outbounds": [{"type": "vless", "tag": "vps", "server": "vps.test"}, {"type": "socks", "tag": "warp", "server": "127.0.0.1"},
                           {"type": "direct", "tag": "direct"}], "route": {"final": "vps"}},
        )

    def test_outbound_link(self):
        self.assertEqual(ok(ctl.cmd_outbounds, "link", "vps"), "vless://x@vps.test:443\n")
        self.assertEqual(json.loads(ok(ctl.cmd_outbounds, "link", "warp", "--json"))["server"], "127.0.0.1")
        status, _, err = run(ctl.cmd_outbounds, "link", "warp")
        self.assertNotEqual(status, 0)
        self.assertIn("use --json", err)
        self.assertNotEqual(run(ctl.cmd_outbounds, "link", "nope")[0], 0)
        self.assertNotEqual(run(ctl.cmd_outbounds, "link", "vps", "--bogus")[0], 0)
        self.assertEqual(ok(ctl.cmd_subscription, "link", "community"), "https://sub.test/t\n")

    def test_config(self):
        status, out, err = run(ctl.cmd_proxy, "config")
        self.assertEqual(status, 0, err)
        self.assertEqual([o["tag"] for o in json.loads(out)["outbounds"]], ["vps", "direct"])
        self.assertIn("left out warp", err)
        self.assertIn('"tag": "warp"', ok(ctl.cmd_proxy, "config", "--raw"))
        self.assertNotEqual(run(ctl.cmd_outbounds, "link", "nope", "--config")[0], 0)

    def test_inbound_json(self):
        self.assertEqual(json.loads(ok(ctl.cmd_inbounds, "link", "in", "--json")), {"type": "vless"})
        self.assertEqual(json.loads(ok(ctl.cmd_inbounds, "link", "in", "--server-json"))["protocol"], "vless")

    def test_inbound_amneziawg_config(self):
        config = "[Interface]\nPrivateKey = k\n\n[Peer]\nEndpoint = h:51820\n"
        self.write(
            "inbounds/links.json",
            [
                {"tag": "in", "user": "u", "type": "vless", "link": "vless://x@h:443", "outbound": {"type": "vless"}},
                {"tag": "awg", "user": "u", "type": "amneziawg", "link": "vpn://abc", "config": config, "outbound": None},
            ],
        )
        emitted = []
        self.patch("_run", lambda cmd, **kw: (emitted.append((cmd, kw.get("stdin"))), (0, ""))[1])
        self.assertEqual(ok(ctl.cmd_inbounds, "link", "awg", "u"), "vpn://abc\n")
        self.assertEqual(ok(ctl.cmd_inbounds, "link", "awg", "--config"), config)
        ok(ctl.cmd_inbounds, "link", "awg", "u", "--config", "--qr")
        self.assertEqual(emitted[-1], (["qrencode", "-t", "ANSIUTF8"], config.rstrip("\n")))
        status, _, err = run(ctl.cmd_inbounds, "link", "awg", "--json")
        self.assertNotEqual(status, 0)
        self.assertIn("use --config", err)
        status, _, err = run(ctl.cmd_inbounds, "link", "in", "--config")
        self.assertNotEqual(status, 0)
        self.assertIn("only AmneziaWG", err)

    def test_inbound_onion_link(self):
        self.write(
            "inbounds/links.json",
            [
                {"tag": "in", "user": "u", "type": "vless", "link": "vless://x@h:443", "outbound": {"server": "h"}},
                {"tag": "in", "user": "u", "type": "vless", "port": 443, "link": "vless://x@o.onion:443", "outbound": {"server": "o.onion"},
                 "variant": "onion"},
                {"tag": "plain", "user": "u", "type": "vless", "link": "vless://x@h:80", "outbound": None},
            ],
        )
        # Same tag and user: the plain link unless --onion asks for the other.
        self.assertEqual(ok(ctl.cmd_inbounds, "link", "in", "u"), "vless://x@h:443\n")
        self.assertEqual(ok(ctl.cmd_inbounds, "link", "in", "--onion"), "vless://x@o.onion:443\n")
        self.assertEqual(json.loads(ok(ctl.cmd_inbounds, "link", "in", "u", "--onion", "--json"))["server"], "o.onion")
        status, _, err = run(ctl.cmd_inbounds, "link", "plain", "--onion")
        self.assertNotEqual(status, 0)
        self.assertIn("onionService.listeners", err)
        self.patch("svc_state", lambda unit: "active")
        self.assertRegex(ok(ctl.cmd_inbounds, "list"), r"(?m)^  in +u +vless \(onion\) +443 +active$")

    @unittest.skipIf(os.geteuid() == 0, "root reads anything")
    def test_unreadable(self):
        os.chmod(self.share, 0)
        status, _, err = run(ctl.cmd_outbounds, "link", "vps")
        self.assertNotEqual(status, 0)
        self.assertIn("re-run with sudo", err)


class TorTest(EnvTest):
    """proxy-ctl tor against a fake control socket that answers like Tor 0.4.9."""

    def setUp(self):
        super().setUp()
        # A relative path: an absolute one under TMPDIR can outgrow sun_path.
        cwd = os.getcwd()
        os.chdir(self.dir)
        self.addCleanup(os.chdir, cwd)
        os.environ["TOR_CONTROL_SOCKET"] = "control"
        self.received = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind("control")
        self.server.listen(1)
        self.addCleanup(self.server.close)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.patch("systemctl", lambda *a, **kw: (0, "active\n") if kw.get("capture") else (0, None))

    def serve(self):
        replies = {
            "AUTHENTICATE": "250 OK",
            "GETINFO status/bootstrap-phase": '250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=75 TAG=enough_dirinfo '
            'SUMMARY="Loaded enough directory info to build circuits"\r\n250 OK',
            "SIGNAL NEWNYM": "250 OK",
        }
        try:
            conn, _ = self.server.accept()
        except OSError:
            return
        with conn, conn.makefile("rwb") as stream:
            for line in stream:
                command = line.decode().rstrip("\r\n")
                self.received.append(command)
                stream.write((replies.get(command, '510 Unrecognized command "x"') + "\r\n").encode())
                stream.flush()

    def test_status_shows_bootstrap(self):
        out = ok(ctl.cmd_tor)
        self.assertIn("bootstrap 75% (Loaded enough directory info to build circuits)", out)
        self.assertEqual(self.received, ["AUTHENTICATE", "GETINFO status/bootstrap-phase"])

    def test_newnym(self):
        ok(ctl.cmd_tor, "newnym")
        self.thread.join(5)
        self.assertEqual(self.received, ["AUTHENTICATE", "SIGNAL NEWNYM"])

    def test_not_running(self):
        os.environ["TOR_CONTROL_SOCKET"] = "missing"
        status, _, err = run(ctl.cmd_tor, "newnym")
        self.assertNotEqual(status, 0)
        self.assertIn("not running", err)
        self.assertNotEqual(run(ctl.cmd_tor, "bogus")[0], 0)
        # Status still reports the unit.
        status, out, err = run(ctl.cmd_tor)
        self.assertEqual(status, 0)
        self.assertIn("bootstrap unknown", out)
        self.assertIn("not running", err)


class BadExitTest(EnvTest):
    def test_shown_from_state(self):
        os.environ.update(
            AUTOPROXY_ENABLED="1",
            AUTOPROXY_STATE_DIR=self.dir,
            OUTBOUND_INVENTORY_FILE=self.write("outbounds.json", {"tags": ["mine", "fresh", "new"], "sources": {}}),
        )
        # The user's "mine" is the backend's "proxy".
        self.write("outbound-test.json", {"outbounds": {"mine": "proxy", "fresh": "fresh", "new": "new"}})
        exits = {
            "proxy": {"strikes": {"sekai.test": {}, "pximg.net": {}}, "bad": True, "badBy": ["sekai.test refused", "pximg.net slow"]},
            "fresh": {"strikes": {"sekai.test": {}}, "bad": False, "badBy": ["sekai.test refused"]},
            "new": {"ip": "192.0.2.1"},
        }
        self.write("state.json", {"domains": {}, "exits": exits})
        self.patch("_outbound_current", lambda: "")
        self.patch("_autoproxy_next_run", lambda: None)
        rows = {line.split()[0]: line.split() for line in ctl.lines(ok(ctl.cmd_outbounds, "list")) if line.startswith("  ")}
        self.assertEqual(rows["mine"][1], "bad")
        self.assertEqual(rows["fresh"][1], "ok")
        # Not judged yet.
        self.assertEqual(rows["new"][1], "-")
        self.assertIn("1 bad exit", ctl._status_autoproxy())
        self.assertRegex(ok(ctl.cmd_proxy_learned), r"(?m)^  proxy +sekai\.test refused, pximg\.net slow$")

class WhereTest(EnvTest):
    """The route walk has to agree with sing-box and XRay, rule-sets included."""

    @unittest.skipUnless(shutil.which(os.environ.get("SING_BOX", "sing-box")), "sing-box not found; set SING_BOX")
    def test_sing_box_walk(self):
        rs = self.write("rs.json", {"version": 1, "rules": [{"domain_suffix": ["youtube.com"]}]})
        config = {
            "route": {
                "final": "direct",
                "rule_set": [{"tag": "yt", "type": "local", "format": "source", "path": rs}],
                "rules": [
                    # Probe listeners and actions are not what a connection by name meets.
                    {"inbound": ["probe-in-0"], "outbound": "primary"},
                    {"action": "sniff"},
                    {"ip_cidr": ["0.0.0.0/0"], "outbound": "block"},
                    {"domain_suffix": [".example.org"], "outbound": "proxy"},
                    {"rule_set": ["yt"], "outbound": "warp"},
                ],
            }
        }
        self.assertEqual(ctl._where_sing_box(config, "rr1.youtube.com"), ("warp", "rule-set yt"))
        self.assertEqual(ctl._where_sing_box(config, "a.example.org")[0], "proxy")
        # A leading dot is subdomains only; nothing else matches, so the final outbound.
        self.assertEqual(ctl._where_sing_box(config, "example.org")[0], "direct")

    def test_inbounds_walk(self):
        config = {
            "routing": {
                "rules": [
                    {"ruleTag": "inbound-block-ru-ip", "ip": ["geoip:ru"], "outboundTag": "block"},
                    {"ruleTag": "inbound-proxy-domain", "domain": ["domain:googlevideo.com"], "outboundTag": "proxy"},
                    {"ruleTag": "inbound-zapret-direct-domain", "domain": ["full:youtube.com"], "outboundTag": "direct"},
                    {"ruleTag": "inbound-final", "network": "tcp,udp", "outboundTag": "proxy"},
                ]
            }
        }
        self.assertEqual(ctl._where_inbounds(config, "rr1.googlevideo.com", "")[0], "proxy")
        self.assertEqual(ctl._where_inbounds(config, "youtube.com", ""), ("direct", "inbound-zapret-direct-domain (full:youtube.com)"))
        self.assertEqual(ctl._where_inbounds(config, "example.org", "")[0], "proxy")
        config["routing"]["rules"][2] |= {"inboundTag": ["relay"], "port": "443"}
        self.assertEqual(
            ctl._where_inbounds(config, "youtube.com", "")[1],
            "inbound-zapret-direct-domain (full:youtube.com, listeners relay, ports 443)",
        )


class StatusSnapshotTest(EnvTest):
    def setUp(self):
        super().setUp()
        self.patch("_awg_profiles", lambda: ["home", "work"])
        self.patch("_route_mode_current", lambda: "default")
        self.patch("_route_mode_default", lambda: "blacklist")

    def overall(self, **states):
        units = {f"proxy-suite-{k.replace('_', '-')}": v for k, v in states.items()}
        return ctl._status_snapshot(units)["overall"]

    def test_base_priority(self):
        self.assertEqual(self.overall(), {"base": "disabled", "badge": "", "label": "Inactive"})
        self.assertEqual(self.overall(zapret="active")["base"], "zapret")
        self.assertEqual(self.overall(socks="active")["label"], "Proxy only")
        self.assertEqual(self.overall(socks="active", zapret="active")["base"], "active")
        both = self.overall(socks="active", zapret="active", tun="active")
        self.assertEqual((both["base"], both["label"]), ("tunnel", "Proxy + traffic + zapret"))
        self.assertEqual(self.overall(awg_work="active"), {"base": "tunnel", "badge": "", "label": "AmneziaWG"})
        self.assertEqual(self.overall(tun="active")["label"], "TUN")

    def test_badges(self):
        self.assertEqual(self.overall(socks="active", tun="failed")["badge"], "failed")
        self.assertEqual(self.overall(socks="activating", tun="failed")["badge"], "failed")
        self.assertEqual(self.overall(socks="active", subscription_update="activating")["badge"], "busy")
        self.assertEqual(ctl._overall_state(None)["badge"], "unknown")

    def test_outputs(self):
        units = {"proxy-suite-socks": "active", "proxy-suite-awg-work": "active", "proxy-suite-tun": "inactive"}
        self.patch("_unit_states", lambda names: {u: s for u, s in units.items() if u in names})
        self.patch("_status_outbound", lambda: "b (pinned)")
        self.patch("_status_autoproxy", lambda: "")
        self.patch("_status_zapret", lambda: "")
        tray = dict(line.split("=", 1) for line in ok(ctl.cmd_status, "--tray").splitlines())
        self.assertEqual(
            (tray["socks_active"], tray["tun_available"], tray["tproxy_available"], tray["awg_active"], tray["awg_profiles"]),
            ("true", "true", "false", "work", "home,work"),
        )
        data = json.loads(ok(ctl.cmd_status, "--json"))
        self.assertEqual(data["overall"]["base"], "tunnel")
        self.assertEqual(data["outbound"], "b (pinned)")
        self.assertEqual(data["route_mode"], {"available": True, "current": "default", "default": "blacklist"})

    def test_warp_over_amneziawg_is_watched(self):
        # An outbound WARP profile is no `awg` profile, but its unit can still fail.
        self.assertIn("proxy-suite-awg-warp", ctl._snapshot_units())
        self.patch("_awg_profiles", lambda: ["warp"])
        self.assertEqual(ctl._snapshot_units().count("proxy-suite-awg-warp"), 1)

    def test_outbound_with_its_hop(self):
        inventory = {"pinned": "", "detours": {"a": "b"}}
        self.patch("_outbound_inventory", lambda: inventory)
        self.patch("_outbound_current", lambda: "a")
        self.assertEqual(ctl._status_outbound(), "a via b")
        inventory["pinned"] = "c"
        self.assertEqual(ctl._status_outbound(), "c (pinned)")
        inventory["detours"]["c"] = "b"
        self.assertEqual(ctl._status_outbound(), "c via b (pinned)")


if __name__ == "__main__":
    unittest.main()
