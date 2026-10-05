#!/usr/bin/env python3

import contextlib
import datetime
import fcntl
import io
import json
import os
import shutil
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
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


class TerminalSafeTest(unittest.TestCase):
    def test_control_characters_are_shown_not_obeyed(self):
        """A share link a subscription served may carry escapes: OSC 52 would set the clipboard."""
        out = io.StringIO()
        ctl._TerminalSafe(out).write("vless://u@h:1#\x1b]52;c;cm0gLXJmIH4=\x07name\r\tok\n\x9b2J")
        self.assertEqual(out.getvalue(), "vless://u@h:1#\\x1b]52;c;cm0gLXJmIH4=\\x07name\\x0d\tok\n\\x9b2J")


class NscdWarningTest(unittest.TestCase):
    def test_wrap_warns_on_nscd(self):
        # glibc goes through nscd, which looks names up from its own cgroup.
        with tempfile.NamedTemporaryFile() as sock, mock.patch.dict(os.environ, {"NSCD_SOCKET": sock.name}):
            status, out, err = run(ctl._warn_nscd, "tproxy")
        assert status == 0, (status, out, err)
        assert "nscd" in err and "route=tproxy" in err

    def test_no_nscd_is_quiet(self):
        # A stub resolver on loopback is no leak: the route's forwarder answers it.
        with mock.patch.dict(os.environ, {"NSCD_SOCKET": "/nonexistent/socket"}):
            assert run(ctl._warn_nscd, "tun")[2] == ""


class SharedFilesTest(unittest.TestCase):
    def test_completion_words_are_never_shell_code(self):
        words = {"ok-tag": "", "sub-Россия": "", "$(id>/tmp/p)": "", "`id`": "", "a b": "", "x": "d\tescr\x1b[31m"}
        with mock.patch.object(ctl, "_complete_tree", lambda *w: words):
            _, out, _ = run(ctl.cmd_complete, "proxy")
        self.assertEqual(out.splitlines(), ["ok-tag", "sub-Россия", "x\td escr[31m"])

    def test_a_list_swapped_for_a_link_is_not_copied(self):
        with tempfile.TemporaryDirectory() as d:
            secret = os.path.join(d, "secret")
            with open(secret, "w") as f:
                f.write("root:hash\n")
            os.chmod(secret, 0o600)
            listed = os.path.join(d, "zapret-hosts-auto.txt")
            os.symlink(secret, listed)
            status, _, _ = run(ctl._replace_lines, listed, lambda line: True)
            self.assertNotEqual(status, 0)
            self.assertTrue(os.path.islink(listed))
            os.unlink(listed)
            os.mkfifo(listed)
            with self.assertRaises(OSError):
                ctl.read_shared_text(listed)


class SliceCleanupTest(unittest.TestCase):
    def test_a_run_still_starting_keeps_the_marking(self):
        with tempfile.TemporaryDirectory() as runtime, mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                mock.patch.object(ctl, "_has_units", return_value=False), \
                mock.patch.object(ctl, "systemctl", return_value=(0, "")) as systemctl:
            ending = ctl._slice_lock("proxy-suite-app-tun")
            starting = ctl._slice_lock("proxy-suite-app-tun")
            self.assertIsNotNone(ending)
            # The other run has its units up but no scope yet: nothing is stopped under it.
            ctl._cleanup_slice_if_idle("proxy-suite-app-tun", "a.service", "u.service", ending)
            systemctl.assert_not_called()
            # The last one out stops them.
            ctl._cleanup_slice_if_idle("proxy-suite-app-tun", "a.service", "u.service", starting)
            self.assertEqual([c.args for c in systemctl.call_args_list], [("stop", "u.service"), ("--user", "stop", "a.service")])


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


class ClashBrokerTest(EnvTest):
    def test_what_each_scope_may_ask(self):
        os.environ["OUTBOUND_INVENTORY_FILE"] = self.write("outbounds.json", {"url": "https://t.test/204"})
        allows = lambda method, target, scopes: ctl._broker_allows(method, target.split("?")[0], scopes, target.partition("?")[2])  # noqa: E731
        member, routing, secrets = set(), {"routing"}, {"secrets"}
        for method, path, scopes, expected in (
            ("GET", "/proxies", member, True),
            ("GET", "/proxies/proxy", member, True),
            ("GET", "/proxies/DE%20one/delay?url=https%3A%2F%2Ft.test%2F204&timeout=8000", member, True),
            ("GET", "/group/g/delay?timeout=1&url=https://t.test/204", member, True),
            # Only the configured test URL: any other is the backend fetching what the caller names.
            ("GET", "/proxies/proxy/delay?url=http://192.168.1.1/admin", member, False),
            ("GET", "/group/g/delay?url=https://t.test/204&url=http://10.0.0.1/", member, False),
            ("GET", "/proxies/proxy/delay", member, False),
            ("PUT", "/proxies/proxy-suite-test", member, True),
            ("PUT", "/proxies/proxy", member, False),
            ("PUT", "/proxies/proxy", routing, True),
            ("GET", "/connections", member, False),
            ("GET", "/connections", secrets, True),
            ("DELETE", "/connections", secrets, False),
            ("PATCH", "/configs", routing, False),
            ("GET", "/logs", secrets, False),
            ("GET", "/proxies/a/b/c", member, False),
            ("GET", "/proxies/", member, False),
            # Decoded and cleaned by the API's router, these name another endpoint.
            ("GET", "/proxies/%2E%2E%2Fconnections", member, False),
            ("GET", "/proxies/..", member, False),
            ("PUT", "/proxies/%2E%2E", routing, False),
            ("GET", "/anything", {"*"}, True),
        ):
            with self.subTest(method=method, path=path, scopes=scopes):
                self.assertEqual(allows(method, path, scopes), expected)
        # outbound-test.json's URL, which `proxy outbounds test` asks with, as much as the inventory's.
        self.write("outbound-test.json", {"url": "https://other.test/"})
        self.assertTrue(allows("GET", "/proxies/p/delay?url=https://other.test/", member))
        self.assertTrue(allows("GET", "/proxies/p/delay?url=https://t.test/204", member))

    def test_root_reads_the_secret_everyone_else_asks_the_broker(self):
        os.environ["CLASH_BROKER"] = self.write("api.sock", "")
        self.patch("_clash_via_broker", lambda *a: (200, {"via": "broker"}))
        self.patch("_clash_direct", lambda *a: (200, {"via": "direct"}))
        self.patch("_clash_secret", lambda: None)
        self.assertEqual(ctl._clash("GET", "/proxies"), (200, {"via": "broker"}))
        self.patch("_clash_secret", lambda: "s")
        self.assertEqual(ctl._clash("GET", "/proxies"), (200, {"via": "direct"}))

    @unittest.skipIf(os.geteuid() == 0, "root holds every scope")
    def test_end_to_end(self):
        import grp
        import http.server

        try:
            group = grp.getgrgid(os.getgid()).gr_name
        except KeyError:
            self.skipTest("no name for this group")
        seen = []

        class Api(http.server.BaseHTTPRequestHandler):
            def _answer(self):
                seen.append((self.command, self.path, self.headers.get("Authorization")))
                raw = json.dumps({"path": self.path}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            do_GET = do_PUT = _answer

            def log_message(self, *_):
                pass

        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
        self.addCleanup(api.server_close)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        self.addCleanup(api.shutdown)
        self.write("clash-secret", "s3cret\n")
        sock = self.path("api.sock")
        os.environ.update(
            CLASH_API=f"http://127.0.0.1:{api.server_address[1]}",
            OUTBOUND_INVENTORY_FILE=self.write("outbounds.json", {"url": "x"}),
            USER_CONTROL_GROUPS=json.dumps({group: ["routing"]}),
        )
        self.patch("CLASH_BROKER_TIMEOUT", 1)
        broker = ctl._clash_broker_server(sock)
        self.addCleanup(broker.server_close)
        threading.Thread(target=broker.serve_forever, daemon=True).start()
        self.addCleanup(broker.shutdown)
        self.assertEqual(stat.S_IMODE(os.stat(sock).st_mode), 0o666)

        ask = lambda method, path, body=None: ctl._clash_via_broker(sock, method, path, body, 5)  # noqa: E731
        self.assertEqual(ask("GET", "/proxies/proxy/delay?url=x&timeout=1"), (200, {"path": "/proxies/proxy/delay?url=x&timeout=1"}))
        self.assertEqual(ask("PUT", "/proxies/proxy", {"name": "de"})[0], 200)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ask("GET", "/connections")[0], 403)
            self.assertEqual(ask("GET", "/proxies/proxy/delay?url=http://127.0.0.1:22/")[0], 403)
        # The secret reaches the API, never the caller; the refused request never left.
        self.assertEqual([s[2] for s in seen], ["Bearer s3cret", "Bearer s3cret"])
        self.assertNotIn("/connections", [s[1] for s in seen])
        # One that connects and says nothing holds up no one else, and not for long.
        stalled = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(stalled.close)
        stalled.connect(sock)
        self.assertEqual(ask("GET", "/proxies")[0], 200)
        stalled.settimeout(5)
        self.assertEqual(stalled.recv(1), b"")
        # In no group at all: closed on unheard, which reads as no API.
        os.environ["USER_CONTROL_GROUPS"] = json.dumps({"someone-else": []})
        self.assertEqual(ask("GET", "/proxies"), (0, None))
        self.assertEqual(len(seen), 3)

    def test_a_full_listen_queue_is_waited_out(self):
        # Nothing accepts at first, and the queue holds one: a Unix socket refuses the next
        # connect at once (EAGAIN), which the client must retry rather than read as no API.
        path = self.path("busy.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(server.close)
        server.bind(path)
        server.listen(0)
        queued = [socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) for _ in range(4)]
        for s in queued:
            self.addCleanup(s.close)
            s.setblocking(False)
            try:
                s.connect(path)
            except BlockingIOError:
                pass

        def drain():
            time.sleep(0.3)
            server.settimeout(5)
            for _ in range(len(queued) + 1):
                try:
                    server.accept()[0].close()
                except OSError:
                    return

        threading.Thread(target=drain, daemon=True).start()
        conn = ctl._UnixHTTPConnection(path, 5)
        self.addCleanup(conn.close)
        conn.connect()
        self.assertIsNotNone(conn.sock)
        # With no one ever accepting, it still gives up once its timeout has passed.
        stuck = self.path("stuck.sock")
        never = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(never.close)
        never.bind(stuck)
        never.listen(0)
        fillers = [socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) for _ in range(4)]
        for s in fillers:
            self.addCleanup(s.close)
            s.setblocking(False)
            try:
                s.connect(stuck)
            except BlockingIOError:
                pass
        start = time.monotonic()
        with self.assertRaises(BlockingIOError):
            ctl._UnixHTTPConnection(stuck, 0.3).connect()
        self.assertLess(time.monotonic() - start, 3)

    @unittest.skipIf(os.geteuid() == 0, "root holds every scope")
    def test_a_burst_of_delay_tests_all_get_answers(self):
        import grp
        import http.server
        from concurrent.futures import ThreadPoolExecutor

        try:
            group = grp.getgrgid(os.getgid()).gr_name
        except KeyError:
            self.skipTest("no name for this group")

        class Api(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                time.sleep(0.2)  # a delay test takes a while
                raw = json.dumps({"delay": 1}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def log_message(self, *_):
                pass

        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
        self.addCleanup(api.server_close)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        self.addCleanup(api.shutdown)
        self.write("clash-secret", "s3cret\n")
        os.environ.update(
            CLASH_API=f"http://127.0.0.1:{api.server_address[1]}",
            OUTBOUND_INVENTORY_FILE=self.write("outbounds.json", {"url": "x"}),
            USER_CONTROL_GROUPS=json.dumps({group: ["outbounds"]}),
        )
        sock = self.path("api.sock")
        broker = ctl._clash_broker_server(sock)
        self.addCleanup(broker.server_close)
        threading.Thread(target=broker.serve_forever, daemon=True).start()
        self.addCleanup(broker.shutdown)
        # As `proxy outbounds test` asks: every outbound's delay at once.
        with ThreadPoolExecutor(max_workers=32) as pool:
            statuses = list(pool.map(lambda i: ctl._clash_via_broker(sock, "GET", f"/proxies/o{i}/delay?url=x", None, 5)[0], range(32)))
        self.assertEqual(statuses, [200] * 32)


class WarpDevicesTest(EnvTest):
    def test_every_device_or_the_one_named(self):
        os.environ["WARP_DEVICES"] = json.dumps([{"tag": "warp-1", "unit": "proxy-suite-awg-warp-1"}, {"tag": "warp-2", "unit": "proxy-suite-awg-warp-2"}])
        calls = []
        self.patch("svc_exists", lambda unit: True)
        self.patch("systemctl", lambda *a, **kw: calls.append(a) or (0, "active\n"))
        status, out, _ = run(ctl.cmd_warp)
        self.assertEqual(status, 0)
        self.assertEqual(out.split(), ["warp-1", "active", "warp-2", "active"])
        # Status exits as `systemctl is-active` would: 3 once none is active.
        self.patch("systemctl", lambda *a, **kw: (3, "inactive\n"))
        self.assertEqual(run(ctl.cmd_warp)[0], 3)
        self.assertEqual(run(ctl.cmd_warp, "status", "warp-1")[0], 3)
        self.patch("systemctl", lambda *a, **kw: calls.append(a) or (0, "active\n"))
        calls.clear()
        run(ctl.cmd_warp, "restart", "warp-2")
        self.assertEqual(calls, [("restart", "proxy-suite-awg-warp-2")])
        calls.clear()
        run(ctl.cmd_warp, "off")
        self.assertEqual(calls, [("stop", "proxy-suite-awg-warp-1"), ("stop", "proxy-suite-awg-warp-2")])
        # Both are WARP's: `awg add` leaves their names alone.
        self.patch("_awg_profiles", lambda: [])
        os.environ["AWG_RUNTIME_GLOBAL"] = "1"
        self.assertIn("reserved for WARP", run(ctl.cmd_awg, "add", "warp-2", "vpn://x")[2])


class GroupWatchTest(EnvTest):
    """Failover groups, through a Clash API that answers from a table."""

    def setUp(self):
        super().setUp()
        os.environ["RUNTIME_DIR"] = self.dir
        self.working = {"warp-1": True, "warp-2": True, "de": True}
        self.nows = {"warp": "warp-1", "proxy": "warp"}
        self.calls = []
        self.clock = [0.0]
        self.patch("_group_nows", lambda: dict(self.nows))
        self.watch = ctl.GroupWatch(clash=self.clash, clock=lambda: self.clock[0], wall=lambda: 1000.0)
        self.inventory = {
            "url": "https://t",
            "selection": "first",
            "disabled": [],
            "groups": {"warp": {"strategy": "failover", "failback": True, "interval": "30s", "members": ["warp-1", "warp-2"], "pinned": ""}},
        }

    def clash(self, method, path, body=None, timeout=10):
        self.calls.append((method, path))
        if method == "GET" and path.startswith("/proxies/") and "/delay" in path:
            tag = urllib.parse.unquote(path.split("/")[2])
            return (200, {"delay": 50}) if self.working.get(tag, True) else (504, None)
        if method == "PUT":
            self.nows[urllib.parse.unquote(path.split("/")[2])] = body["name"]
            return 204, None
        return 200, {}

    def step(self, seconds=30, hinted=()):
        self.clock[0] += seconds
        return self.watch.step(self.inventory, hinted)

    def test_moves_after_two_misses_and_comes_back_after_three_passes(self):
        self.assertEqual(self.step(0), [])
        self.working["warp-1"] = False
        self.assertEqual(self.step(), [])  # one miss is not an outage
        self.assertEqual(self.step(), [("warp", "warp-2")])
        self.working["warp-1"] = True
        self.assertEqual(self.step(), [])
        self.assertEqual(self.step(), [])
        self.assertEqual(self.step(), [("warp", "warp-1")])

    def test_a_hint_moves_at_once(self):
        self.step(0)
        self.working["warp-1"] = False
        # Not due yet, but a watchdog saw it fail.
        self.assertEqual(self.step(1, hinted=["warp-1"]), [("warp", "warp-2")])
        # A hint about a member that still works changes nothing.
        self.assertEqual(self.step(1, hinted=["warp-2"]), [])

    def test_hints_outside_the_groups_are_ignored(self):
        # A name no watched group holds is neither tested nor kept.
        self.step(0)
        self.calls.clear()
        self.step(1, hinted=["../etc", "nobody"])
        self.assertEqual(self.calls, [])
        self.assertEqual(set(self.watch.health), {"warp-1", "warp-2"})
        # A member's is tested each time it comes.
        self.step(1, hinted=["warp-1"])
        self.step(1, hinted=["warp-1"])
        self.assertEqual(sum(p.startswith("/proxies/warp-1/delay") for _, p in self.calls), 2)

    def test_without_failback_it_stays(self):
        self.inventory["groups"]["warp"]["failback"] = False
        self.step(0)
        self.working["warp-1"] = False
        self.step(1, hinted=["warp-1"])
        self.working["warp-1"] = True
        for _ in range(4):
            self.assertEqual(self.step(), [])
        self.assertEqual(self.nows["warp"], "warp-2")

    def test_pins_and_dead_ends_stay_put(self):
        self.inventory["groups"]["warp"]["pinned"] = "warp-1"
        self.working["warp-1"] = False
        self.step(0, hinted=["warp-1"])
        self.assertEqual(self.nows["warp"], "warp-1")
        self.inventory["groups"]["warp"]["pinned"] = ""
        self.working["warp-2"] = False
        self.step(1, hinted=["warp-2"])
        self.assertEqual(self.nows["warp"], "warp-1")  # nothing works: no flapping

    def test_failover_selection_and_nested_groups(self):
        self.inventory.update(selection="failover", top=["warp", "de", "tor"], excluded=["tor"])
        self.assertEqual(list(ctl.GroupWatch.watched(self.inventory)), ["warp", "proxy"])
        self.assertEqual(ctl.GroupWatch.inner_first({"proxy": {"members": ["warp", "de"]}, "warp": {"members": ["warp-1"]}}), ["warp", "proxy"])
        self.working["warp"] = False
        self.step(0, hinted=["warp"])
        self.assertEqual(self.nows["proxy"], "de")

    def test_urltest_groups_are_only_asked_to_test_again(self):
        self.inventory["groups"]["warp"]["strategy"] = "urltest"
        self.step(0)
        self.assertEqual(self.calls, [])
        self.step(1, hinted=["warp-1"])
        self.assertTrue(any(p.startswith("/group/warp/delay") for _, p in self.calls))
        self.assertFalse(any(m == "PUT" for m, _ in self.calls))

    def test_hint_files(self):
        health = self.path("proxy-suite-outbound-groups/health")
        os.makedirs(health)
        self.assertEqual(self.watch.hints(), [])
        open(os.path.join(health, "warp-1"), "w").close()
        self.assertEqual(self.watch.hints(), [])  # first sight: there already
        os.utime(os.path.join(health, "warp-1"), (5, 5))
        self.assertEqual(self.watch.hints(), ["warp-1"])
        self.assertEqual(self.watch.hints(), [])

    def test_group_files_and_priority(self):
        os.environ["RUNTIME_OUTBOUNDS_DIR"] = self.path("obd")
        os.makedirs(self.path("obd"))
        inventory = {"tags": ["a", "b", "c"], "top": ["g", "c"], "groups": {"g": {"members": ["a", "b"], "runtime": True}}}
        self.patch("_outbound_inventory", lambda: inventory)
        self.patch("_runtime_reload", lambda: None)

        def saved(name):
            with open(self.path(f"obd/{name}")) as f:
                return json.load(f)

        run(ctl.cmd_groups, "add", "h", "c", "--strategy", "urltest", "--no-failback")
        self.assertEqual(saved("h.group"), {"outbounds": ["c"], "subscriptions": [], "match": [], "strategy": "urltest", "failback": False})
        self.assertIn("cannot hold itself", run(ctl.cmd_groups, "add", "x", "x")[2])
        # h holds g (as the start script would list it): g cannot take h in.
        inventory["groups"]["h"] = {"members": ["g"]}
        self.write("obd/g.group", {"outbounds": ["a", "b"]})
        self.assertIn("contains 'g'", run(ctl.cmd_groups, "members", "g", "add", "h")[2])
        # A group's name is taken for outbounds too.
        self.assertIn("A group named 'g' already exists", run(ctl._check_runtime_tag, "outbound", "g")[2])
        run(ctl.cmd_priority, "c", "up")
        self.assertEqual(saved("priority.json"), {"c": 10, "g": 20})
        run(ctl.cmd_priority, "c", "--clear")
        self.assertEqual(saved("priority.json"), {"g": 20})


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
    def test_listener_login_goes_through_a_file(self):
        """The probe listeners take the login drawn per start, the local proxy its own
        (listener.auth); never on curl's argv."""
        os.environ["PROXYCHAINS_CONFIG"] = self.write(
            "proxychains.conf", 'strict_chain\n\n[ProxyList]\nsocks5 127.0.0.1 1080 user pa"ss\\w\n'
        )
        os.environ["OUTBOUND_INVENTORY_FILE"] = self.write("outbounds.json", "{}")
        self.write("probe-login", "probe:0123abcd\n")
        os.environ["LOCAL_PROXY_URL"] = "http://127.0.0.1:1080"
        seen = []

        def curl(argv):
            with open(argv[argv.index("-K") + 1]) as f:
                seen.append((argv, f.read()))
            return 0, "0|0.1|200|10|"

        self.patch("run_curl", curl)
        ctl._probe_fetch("site.test", "/", "--proxy", "http://127.0.0.1:18600")
        argv, curlrc = seen[0]
        self.assertEqual(curlrc, 'proxy-user = "probe:0123abcd"\n')
        self.assertFalse(any("0123abcd" in a for a in argv))
        ctl._probe_fetch("site.test", "/", "--proxy", "http://127.0.0.1:1080")
        argv, curlrc = seen[-1]
        self.assertEqual(curlrc, 'proxy-user = "user:pa\\"ss\\\\w"\n')
        self.assertFalse(any("pa" in a and "ss" in a for a in argv))
        # Direct fetches, and a config without a login, carry none.
        self.write("proxychains.conf", "strict_chain\n\n[ProxyList]\nsocks5 127.0.0.1 1080\n")
        self.assertIsNone(ctl._local_proxy_login())

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
        # A Location at this host or the LAN, by literal, is never fetched.
        for target in ("http://127.1/", "http://localhost/", "http://[::ffff:10.0.0.1]/", "http://u@192.168.1.1:80/", "http://0.0.0.0/"):
            with self.subTest(target=target):
                self.assertTrue(ctl._probe_local_target(target))
        self.assertFalse(ctl._probe_local_target("https://www.spotify.test/"))
        self.assertFalse(ctl._probe_local_target("https://203.0.113.0.example/"))

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

    def test_unit_escape(self):
        # As systemd-escape prints them.
        self.assertEqual(ctl.unit_escape("ssh-proxy"), "ssh\\x2dproxy")
        self.assertEqual(ctl.unit_escape("de_1:x.y"), "de_1:x.y")
        self.assertEqual(ctl.unit_escape(".a/b c\\"), "\\x2ea-b\\x20c\\x5c")
        self.assertEqual(ctl.unit_escape("é"), "\\xc3\\xa9")
        seen = self.calls()
        ctl._start_pin_unit("my-vps")
        self.assertEqual(seen, [["systemctl", "start", "proxy-suite-outbound-pin@my\\x2dvps.service"]])

    def test_logs(self):
        ran = []

        def exec_(argv):
            ran.append(("exec", argv))
            raise SystemExit(0)

        self.patch("_exec", exec_)
        self.patch("_follow_in_pager", lambda argv, viewer: ran.append((viewer, argv)) or 0)
        found = {"lnav", "less"}
        self.patch("shutil", mock.Mock(which=lambda name: f"/bin/{name}" if name in found else None))
        # Piped (run() captures stdout): journalctl itself, with a backlog.
        run(ctl.cmd_logs)
        self.assertEqual(ran[-1], ("exec", ["journalctl", "-f", "-n", "1000", "--unit=proxy-suite-*"]))
        # In a terminal: through lnav, one --unit per named unit.
        terminal = mock.Mock(isatty=lambda: True)
        with mock.patch.object(ctl.sys, "stdin", terminal), mock.patch.object(ctl.sys, "stdout", terminal):
            with self.assertRaises(SystemExit) as done:
                ctl.cmd_logs("a", "b")
            self.assertEqual(done.exception.code, 0)
            self.assertEqual(ran[-1], (["/bin/lnav", "-q"], ["journalctl", "-f", "-n", "1000", "--unit=a", "--unit=b"]))
            # Without lnav: less, already following.
            found.discard("lnav")
            with self.assertRaises(SystemExit):
                ctl.cmd_logs()
            self.assertEqual(ran[-1][0], ["/bin/less", "-R", "-M", "+F"])
            # Without either: journalctl itself.
            found.clear()
            with self.assertRaises(SystemExit):
                ctl.cmd_logs()
            self.assertEqual(ran[-1][0], "exec")

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
        # Another global tunnel still up keeps it: turning off one that is not running lifts nothing.
        self.patch("_awg_profiles", lambda: ["home"])
        running = {ctl._awg_service("home"): "active"}
        self.patch("_unit_states", lambda units: {u: running.get(u, "inactive") for u in units})
        for off in (lambda: ctl.cmd_proxy("tun", "off"), lambda: ctl.cmd_proxy("tproxy", "off"), lambda: ctl.cmd_proxy("off")):
            seen.clear()
            with contextlib.redirect_stderr(io.StringIO()) as err:
                off()
            self.assertNotIn(ctl.KILL_SWITCH, stops())
            self.assertIn("stays up for proxy-suite-awg-home", err.getvalue())
        running = {"proxy-suite-tproxy": "activating"}
        seen.clear()
        with contextlib.redirect_stderr(io.StringIO()):
            ctl.cmd_awg("off", "home")
        self.assertEqual(stops(), [ctl._awg_service("home")])
        # Still, killswitch off always lifts it.
        seen.clear()
        ctl.COMMANDS["killswitch"]("off")
        self.assertEqual(stops(), [ctl.KILL_SWITCH])

    def test_toggle_and_restart(self):
        seen = self.calls()
        active = set()
        self.patch("svc_active", lambda unit: unit in active)
        verbs = lambda: [argv[1:3] for argv in seen if argv[1] in ("start", "stop", "restart")]
        ctl.COMMANDS["ssh"]("toggle")
        active.add("proxy-suite-ssh-proxy")
        ctl.COMMANDS["ssh"]("toggle")
        ctl.COMMANDS["ssh"]("restart")
        self.assertEqual(verbs(), [["start", "proxy-suite-ssh-proxy"], ["stop", "proxy-suite-ssh-proxy"], ["restart", "proxy-suite-ssh-proxy"]])
        # Toggled off, a mode lifts the kill switch as off does; proxy toggled off takes the modes down.
        seen.clear()
        active.update(["proxy-suite-tun", "proxy-suite-socks"])
        ctl.cmd_proxy("tun", "toggle")
        ctl.cmd_proxy("toggle")
        self.assertEqual(
            verbs(),
            [["stop", "proxy-suite-tun"], ["stop", ctl.KILL_SWITCH], ["stop", "proxy-suite-tproxy"], ["stop", "proxy-suite-tun"], ["stop", ctl.KILL_SWITCH], ["stop", "proxy-suite-socks"]],
        )
        seen.clear()
        ctl.cmd_proxy("restart")
        ctl.cmd_proxy("tproxy", "restart")
        ctl.cmd_zapret("restart")
        ctl.cmd_tor("restart")
        self.assertEqual(verbs(), [["restart", u] for u in ("proxy-suite-socks", "proxy-suite-tproxy", "proxy-suite-zapret", "proxy-suite-tor")])
        # Per-app zapret only: no system-wide unit to toggle, so point at the profile instead.
        os.environ["PER_APP_ROUTING_ZAPRET_ENABLED"] = "1"
        with mock.patch.object(ctl, "svc_exists", lambda unit: unit != "proxy-suite-zapret"):
            self.assertIn("zapret.global.enable = false", run(ctl.cmd_zapret, "on")[2])
        # awg toggle: a named profile flips; without one, only stopping is possible.
        seen.clear()
        self.patch("_awg_profiles", lambda: ["p", "q"])
        ctl.cmd_awg("toggle", "p")
        active.add(ctl._awg_service("q"))
        ctl.cmd_awg("toggle")
        self.assertEqual(verbs(), [["start", ctl._awg_service("p")], ["stop", ctl._awg_service("q")], ["stop", ctl.KILL_SWITCH]])
        active.clear()
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            ctl.cmd_awg("toggle")

    def test_wl(self):
        seen = self.calls()
        active = {"proxy-suite-wb-joiner-wl"}
        self.patch("svc_active", lambda unit: unit in active)
        os.environ["WL_FILE"] = self.write("wl.json", [{"name": "phone", "role": "creator", "platform": "dion"}, {"name": "wl", "role": "joiner", "platform": "dion"}])
        os.environ["STATE_DIR"] = self.dir
        ctl.cmd_wl("toggle")
        ctl.cmd_wl("restart", "wl")
        # Toggle flips each one on its own.
        self.assertEqual(
            [argv[1:3] for argv in seen],
            [["start", "proxy-suite-wb-creator-phone"], ["stop", "proxy-suite-wb-joiner-wl"], ["restart", "proxy-suite-wb-joiner-wl"]],
        )
        self.assertNotEqual(run(ctl.cmd_wl, "link", "phone")[0], 0)  # no call yet
        self.write("whitelist-bypass/phone.link", "dion://old\ndion://new\n")
        self.assertEqual(ok(ctl.cmd_wl, "link", "phone"), "dion://new\n")
        self.assertNotEqual(run(ctl.cmd_wl, "link", "wl")[0], 0)  # a joiner has no link to give
        self.assertEqual(set(ctl._complete_tree("wl", "link")), {"phone", "--qr"})
        # auth: a cookies export, or DION's email and password; either restarts the creator.
        # The directory's group bits carry over: the whitelistBypass scope's group shares it.
        seen.clear()
        os.chmod(os.path.join(self.dir, "whitelist-bypass"), 0o770)
        cookies = os.path.join(self.dir, "whitelist-bypass", "phone.cookies.json")
        ok(ctl.cmd_wl, "auth", "phone", self.write("export.json", [{"name": "a", "value": "b"}]))
        self.assertEqual(json.loads(ctl.read_text(cookies)), [{"name": "a", "value": "b"}])
        self.assertEqual(os.stat(cookies).st_mode & 0o777, 0o660)
        self.enterContext(mock.patch("builtins.input", lambda prompt: " me@x "))
        self.enterContext(mock.patch("getpass.getpass", lambda prompt: "pw"))
        ok(ctl.cmd_wl, "auth", "phone")
        self.assertEqual(json.loads(ctl.read_text(cookies)), {"email": "me@x", "password": "pw"})
        self.assertEqual([argv[1:3] for argv in seen], [["restart", "proxy-suite-wb-creator-phone"]] * 2)
        self.assertNotEqual(run(ctl.cmd_wl, "auth", "phone", self.write("bad.json", "{"))[0], 0)
        self.assertNotEqual(run(ctl.cmd_wl, "auth", "wl")[0], 0)  # a joiner has no login
        # join: the call a joiner takes; new: a creator drops its call, unless configured.
        seen.clear()
        ok(ctl.cmd_wl, "join", "wl", " dion://new ")
        self.assertEqual(ctl.read_text(os.path.join(self.dir, "whitelist-bypass", "wl.join")), "dion://new\n")
        self.assertNotEqual(run(ctl.cmd_wl, "join", "wl", "a b")[0], 0)
        self.assertNotEqual(run(ctl.cmd_wl, "join", "phone", "x")[0], 0)  # a creator makes its call
        ok(ctl.cmd_wl, "new", "phone")
        self.assertFalse(os.path.exists(os.path.join(self.dir, "whitelist-bypass", "phone.link")))
        self.assertEqual([argv[1:3] for argv in seen], [["restart", "proxy-suite-wb-joiner-wl"], ["restart", "proxy-suite-wb-creator-phone"]])
        os.environ["WL_FILE"] = self.write("wl.json", [{"name": "phone", "role": "creator", "platform": "dion", "fixedLink": True}])
        self.assertNotEqual(run(ctl.cmd_wl, "new", "phone")[0], 0)

    def test_toggle_completes(self):
        for path in ("ssh", "zapret", "proxy", "proxy tun", "tor"):
            self.assertLessEqual({"toggle", "restart"}, set(ctl._complete_tree(*path.split())))
        self.assertIn("toggle", ctl._complete_tree("awg"))

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
        for name in ("SUB_CACHE_DIR", "AUTOPROXY_STATE_DIR", "AUTOPROXY_SPOOL_DIR", "INBOUNDS_STATS_FILE", "OUTBOUND_INVENTORY_FILE"):
            os.environ.pop(name, None)
        os.environ.update(STATE_DIR="/home/u/.local/state/proxy-suite", RUNTIME_DIR="/tmp/ps")
        self.assertEqual(ctl._autoproxy_dir(), "/home/u/.local/state/proxy-suite/autoproxy")
        self.assertEqual(ctl._autoproxy_spool(), "/home/u/.local/state/proxy-suite/autoproxy-requests")
        self.assertEqual(os.path.dirname(ctl._subscription_cache("x")), "/home/u/.local/state/proxy-suite/subscriptions")

    def test_rootless_hosts_never_ask_for_root(self):
        self.assertIn("sudo", ctl.ask_group())
        os.environ["PRIVILEGED"] = "0"
        self.assertNotIn("sudo", ctl.ask_group())

    def test_names_every_user_control_group(self):
        os.environ.update(USER_CONTROL_GROUP="proxy-suite", USER_CONTROL_GROUPS=json.dumps({"proxy-suite": [], "users": ["perApp"]}))
        self.assertIn("(proxy-suite, users)", ctl.ask_group())
        os.environ["USER_CONTROL_GROUPS"] = json.dumps({"proxy-suite": []})
        self.assertIn("join the proxy-suite group", ctl.ask_group())


class AutoProxyTest(EnvTest):
    def setUp(self):
        super().setUp()
        os.environ.update(AUTOPROXY_ENABLED="1", AUTOPROXY_STATE_DIR=self.dir, AUTOPROXY_SPOOL_DIR=self.path("spool"))
        os.makedirs(self.path("spool"))

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
        self.assertEqual(ctl._autoproxy_queued("requests"), "www.last.fm\n")
        self.assertIn("last.fm: destination - routed via primary", out)
        # A file of its own in the spool, never in root's state dir.
        (queued,) = os.listdir(self.path("spool"))
        self.assertRegex(queued, r"^requests\.[0-9]+\.[0-9]+$")
        self.assertFalse(os.path.exists(self.path("requests")))

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
        self.assertIn("www.last.fm\n", ctl._autoproxy_queued("requests"))

    def test_queue_and_learned(self):
        self.patch("systemctl", lambda *args, **kw: (0, ""))
        self.write("spool/requests.2.1", "www.last.fm\n")
        # What a member left besides: not followed, not waited on, not shown.
        self.write("secret", "root.only\n")
        os.symlink(self.path("secret"), self.path("spool/requests.3.1"))
        os.mkfifo(self.path("spool/requests.4.1"))
        self.write("spool/.requests.5.1.tmp", "half.written\n")
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
        self.assertNotIn("root.only", q)
        self.assertNotIn("half.written", q)
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
        self.assertEqual(ctl._autoproxy_queued("edits"), "forget last.fm\n")
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
        self.assertEqual(ctl._autoproxy_queued("edits"), "forget last.fm\n")
        self.assertEqual(ctl._autoproxy_queued("requests"), "www.last.fm\n")
        self.assertIn("probing www.last.fm", out)
        self.assertIn("proxy-ctl proxy outbounds disable primary", out)

    def test_clear(self):
        self.patch("systemctl", lambda *args, **kw: (1, ""))
        status, _, err = run(ctl.cmd_proxy_clear)
        self.assertNotEqual(status, 0)
        self.assertIn("still queued", err)
        self.assertEqual(ctl._autoproxy_queued("edits"), "clear\n")
        # Again: queued after the first, not in its place.
        run(ctl.cmd_proxy_clear)
        self.assertEqual(ctl._autoproxy_queued("edits"), "clear\nclear\n")

    @unittest.skipIf(os.geteuid() == 0, "root writes anything")
    def test_unwritable_spool_asks_for_sudo(self):
        os.chmod(self.path("spool"), 0o500)
        try:
            status, _, err = run(ctl.cmd_proxy_learn, "www.last.fm")
        finally:
            os.chmod(self.path("spool"), 0o755)
        self.assertNotEqual(status, 0)
        self.assertIn(f"Cannot write to {self.path('spool')}", err)

    @unittest.skipIf(os.geteuid() == 0, "root reads anything")
    def test_unreadable_state_asks_for_sudo(self):
        os.chmod(self.dir, 0)
        try:
            status, _, err = run(ctl.cmd_proxy_queue)
        finally:
            os.chmod(self.dir, 0o755)
        self.assertNotEqual(status, 0)
        self.assertIn("proxy-suite group, or re-run with sudo", err)


class RuntimeSpoolTest(EnvTest):
    """The runtime spools, and a backend that reads them back on every reload."""

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


class RuntimeEntryTest(RuntimeSpoolTest):
    def test_tag_for(self):
        tag = ctl._runtime_tag_for
        self.assertEqual(tag("outbound", "vless://u@de1.example.net:443?security=reality#%F0%9F%87%A9%F0%9F%87%AA%20DE-1"), "DE-1")
        self.assertEqual(tag("outbound", "trojan://p@1.2.3.4:443"), "trojan-1.2.3.4")
        # Declared tags are taken as much as runtime ones.
        self.assertEqual(tag("outbound", "vless://u@www.example.org:443"), "vless-example-2")
        self.assertEqual(tag("outbound", '{"type": "socks", "server": "127.0.0.1"}'), "socks")
        self.assertEqual(tag("outbound", '{"tag": "proxy", "type": "socks"}'), "proxy-2")  # reserved
        self.assertEqual(tag("outbound", "vless://u@t.test:443#tor"), "tor-2")
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
        # Plain http: anyone on the path could rewrite what root fetches. Refused, piped or not.
        for args, stdin in ((("plain", "http://sub.plain.test/s"), ""), (("plain", "-"), " HTTP://sub.plain.test/s\n"), (("ftp://sub.plain.test/s",), "")):
            with self.subTest(args=args), mock.patch.object(sys, "stdin", io.StringIO(stdin)):
                status, _, err = run(ctl.cmd_subscription, "add", *args)
                self.assertNotEqual(status, 0)
                self.assertIn("must be an https:// URL", err)
        self.assertIn("runtimeSubscriptions.allowHttp", run(ctl.cmd_subscription, "add", "plain", "http://sub.plain.test/s")[2])
        self.assertFalse([n for n in os.listdir(self.path("subscriptions.d")) if not n.startswith(("work", "home", "."))])
        # Unless the admin allows it; other schemes stay refused.
        with mock.patch.dict(os.environ, {"RUNTIME_SUBS_ALLOW_HTTP": "1"}):
            ok(ctl.cmd_subscription, "add", "plain", "http://sub.plain.test/s")
            self.assertNotEqual(run(ctl.cmd_subscription, "add", "ftp", "ftp://sub.plain.test/s")[0], 0)
        os.unlink(self.path("subscriptions.d/plain.url"))
        # An HTTP proxy is still an outbound.
        ok(ctl.cmd_outbounds, "add", "httpproxy", "http://proxy.test:3128")
        # Names the start script skips: priority.json's, the Tor outbound's and its own selectors'.
        for reserved in ("priority", "tor", "proxy-suite-test"):
            with self.subTest(tag=reserved):
                status, _, err = run(ctl.cmd_outbounds, "add", reserved, "vless://u@r.test:443")
                self.assertNotEqual(status, 0)
                self.assertIn("is reserved", err)
                self.assertFalse(os.path.exists(self.path(f"outbounds.d/{reserved}.url")))
        # Outbound JSON alone, and a JSON-looking word for a subscription is not a source.
        self.assertIn("Tag: socks", ok(ctl.cmd_outbounds, "add", '{"type": "socks", "server": "127.0.0.1", "server_port": 1080}'))
        self.assertTrue(os.path.exists(self.path("outbounds.d/socks.json")))

    @unittest.skipIf(os.geteuid() == 0, "root reads any cache")
    def test_a_root_only_cache_is_counted_from_the_inventory(self):
        """Without "secrets" the cache is out of reach: add and list go by the outbounds the proxy took from it."""
        os.makedirs(self.path("subscriptions"))
        os.chmod(self.path("subscriptions"), 0)
        self.addCleanup(os.chmod, self.path("subscriptions"), 0o755)

        def started():
            tags = self.declared + ctl._runtime_tags("outbound")
            sources = {f"{t}-{n}": f"sub:{t}" for t in ctl._runtime_tags("subscription") for n in (1, 2)}
            self.write("outbounds.json", {"tags": tags + list(sources), "sources": sources})

        self.backend_start = started
        self.assertIn("Added subscription: work (2 proxies)", ok(ctl.cmd_subscription, "add", "work", "https://sub.work.test/s"))
        self.assertRegex(ok(ctl.cmd_subscription, "list"), r"(?m)^  work +unknown +2 +runtime$")
        self.assertRegex(ok(ctl.cmd_subscription, "list"), r"(?m)^  provider +\(no cache\) +- +static$")

    def test_add_from_stdin(self):
        # "-": the link on stdin, so its credentials stay out of argv (ps, pkexec's log).
        with mock.patch.object(sys, "stdin", io.StringIO("https://sub.piped.test/s?token=t\n")):
            self.assertIn("Tag: piped", ok(ctl.cmd_subscription, "add", "-"))
        self.assertEqual(ctl.read_text(self.path("subscriptions.d/piped.url")), "https://sub.piped.test/s?token=t\n")
        with mock.patch.object(sys, "stdin", io.StringIO("https://sub.x.test/s")):
            ok(ctl.cmd_subscription, "add", "mine", "-")
        self.assertTrue(os.path.exists(self.path("subscriptions.d/mine.url")))
        with mock.patch.object(sys, "stdin", io.StringIO("vless://u@de.test:443#DE")):
            ok(ctl.cmd_outbounds, "add", "-", "--detour", "primary")
        self.assertEqual(ctl.read_text(self.path("outbounds.d/DE.url")), "vless://u@de.test:443#DE\n")
        # Nothing piped in: nothing written.
        for fn in (ctl.cmd_subscription, ctl.cmd_outbounds):
            with self.subTest(fn=fn.__name__), mock.patch.object(sys, "stdin", io.StringIO("")):
                status, _, err = run(fn, "add", "empty", "-")
                self.assertNotEqual(status, 0)
                self.assertIn("Nothing on stdin", err)
        self.assertFalse([n for n in os.listdir(self.path("subscriptions.d")) + os.listdir(self.path("outbounds.d")) if n.startswith("empty")])

    def test_json_naming_local_files_is_refused(self):
        """The backend holds CAP_NET_ADMIN: a tor outbound runs a program, *_path and *File are read."""
        for tag, ob in (
            ("t", {"type": "tor", "executable_path": "/tmp/x"}),
            ("s", {"type": "ssh", "server": "h", "private_key_path": "/root/.ssh/id_ed25519"}),
            ("x", {"protocol": "vless", "streamSettings": {"tlsSettings": {"masterKeyLog": "/etc/x"}}}),
            # XRay's JSON decoding folds U+017F to s: this is masterKeyLog to it.
            ("u", {"protocol": "vless", "streamSettings": {"tlsSettings": {"ma\u017fterKeyLog": "/etc/x"}}}),
        ):
            status, _, err = run(ctl.cmd_outbounds, "add", tag, json.dumps(ob))
            self.assertNotEqual(status, 0)
            self.assertIn("cannot name local files or programs", err)
            self.assertFalse(os.path.exists(self.path(f"outbounds.d/{tag}.json")))
        # A transport's path is a URL path, not a file.
        ok(ctl.cmd_outbounds, "add", "ws", '{"type": "vless", "transport": {"type": "ws", "path": "/x"}}')

    def test_symlinks_in_the_spool_are_replaced_not_followed(self):
        """proxy-ctl may run as root in a dir the group writes to: a planted link leads nowhere."""
        victim = self.write("victim", "untouched\n")
        os.symlink(victim, self.path("outbounds.d/priority.json"))
        # Dangling: followed, the write would create a file wherever they point.
        for name in ("new.detour", "primary.disabled"):
            os.symlink(self.path(f"created-{name}"), self.path(f"outbounds.d/{name}"))
        ok(ctl.cmd_outbounds, "add", "new", "vless://u@new.test:443", "--detour", "primary")
        ok(ctl.cmd_outbounds, "disable", "primary")
        ok(ctl.cmd_priority, "primary", "5")
        self.assertEqual(ctl.read_text(victim), "untouched\n")
        for name in ("new.detour", "primary.disabled", "priority.json"):
            self.assertFalse(os.path.islink(self.path(f"outbounds.d/{name}")), name)
            self.assertFalse(os.path.exists(self.path(f"created-{name}")), name)
        self.assertEqual(ctl.read_text(self.path("outbounds.d/new.detour")), "primary\n")
        # The link holds credentials: no other member reads it without the "secrets" scope.
        self.assertEqual(stat.S_IMODE(os.stat(self.path("outbounds.d/new.url")).st_mode), 0o600)

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
        self.assertEqual(os.listdir(self.path("outbounds.d")), [".entries.lock"])

    def test_priority_and_group_edits_are_locked(self):
        """Read to write under .<name>.lock: the GUI and a terminal at once would drop one's change."""
        ok(ctl.cmd_groups, "add", "pool", "primary")
        for name, fn, args in [
            ("priority.json", ctl.cmd_priority, ("primary", "5")),
            ("pool.group", ctl.cmd_groups, ("strategy", "pool", "urltest")),
            ("pool.group", ctl.cmd_groups, ("members", "pool", "add", "vless-example")),
        ]:
            with self.subTest(args=args), open(self.path(f"outbounds.d/.{name}.lock"), "a") as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                with mock.patch.object(ctl, "LOCK_WAIT", 0.2):
                    status, _, err = run(fn, *args)
                self.assertNotEqual(status, 0)
                self.assertIn("Something else is still changing", err)
        self.assertFalse(os.path.exists(self.path("outbounds.d/priority.json")))
        self.assertEqual(json.loads(ctl.read_text(self.path("outbounds.d/pool.group")))["outbounds"], ["primary"])
        # Released, they go through.
        ok(ctl.cmd_groups, "members", "pool", "add", "vless-example")
        self.assertEqual(json.loads(ctl.read_text(self.path("outbounds.d/pool.group")))["outbounds"], ["primary", "vless-example"])
        # rm takes its lock file along; one waiting on the old one locks the new one instead.
        lock = self.path("outbounds.d/.pool.group.lock")
        ok(ctl.cmd_groups, "rm", "pool")
        self.assertFalse(os.path.exists(lock))
        opened = []
        real_open = os.open

        def open_once(path, *a, **kw):
            # The first open finds the old, removed lock (as one already waiting holds it).
            if path == lock and not opened:
                opened.append(path)
                stale = real_open(lock, os.O_RDONLY | os.O_CREAT, 0o600)
                os.unlink(lock)
                return stale
            return real_open(path, *a, **kw)

        with mock.patch.object(ctl.os, "open", open_once), ctl._file_lock(self.path("outbounds.d/pool.group")) as held:
            self.assertTrue(held)
            self.assertTrue(os.path.exists(lock))

    def test_rm_and_group_edits_stay_in_the_spool(self):
        # Root runs these: a tag with ../ in it must not reach files outside the spool.
        for name in ("victim.url", "victim.group"):
            self.write(name, "{}")
        for fn, args in [
            (ctl.cmd_outbounds, ("rm", "../victim")),
            (ctl.cmd_groups, ("rm", "../victim")),
            (ctl.cmd_groups, ("strategy", "../victim", "failover")),
            (ctl.cmd_groups, ("members", "../victim", "rm", "a")),
        ]:
            with self.subTest(args=args):
                status, _, err = run(fn, *args)
                self.assertNotEqual(status, 0)
                self.assertIn("Invalid", err)
        self.assertTrue(os.path.exists(self.path("victim.url")) and os.path.exists(self.path("victim.group")))


AWG_CONF = """[Interface]
PrivateKey = private
Address = 10.8.0.2/32

[Peer]
PublicKey = public
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example.com:51820
"""


def awg_vpn_link(description):
    """A vpn:// export carrying AWG_CONF, as the Amnezia app writes one."""
    import base64
    import zlib

    data = json.dumps({"description": description, "containers": [{"container": "amnezia-awg", "awg": {"last_config": json.dumps({"config": AWG_CONF})}}]}).encode()
    return "vpn://" + base64.urlsafe_b64encode(len(data).to_bytes(4, "big") + zlib.compress(data)).decode().rstrip("=")


class AmneziaWgRuntimeTest(RuntimeSpoolTest):
    """`awg add`/`rm` and AmneziaWG outbounds: amneziawg_config.py itself checks and writes them."""

    def setUp(self):
        super().setUp()
        tool = os.environ.get("AWG_CONFIG_TOOL") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../scripts/amneziawg_config.py")
        os.makedirs(self.path("amneziawg.d"))
        os.environ.update(
            AWG_CONFIG_TOOL=tool,
            AWG_RUNTIME_GLOBAL="1",
            AWG_RUNTIME_OUTBOUNDS="1",
            AWG_RUNTIME_DIR=self.path("amneziawg.d"),
            AWG_PROFILES_FILE=self.write("awg-profiles.json", ["home"]),
            AWG_TUNNEL_BASE_PORT="18800",
            AWG_TUNNEL_SLOTS="2",
        )
        self.active = set()
        self.patch("svc_active", lambda unit: unit in self.active)
        self.patch("svc_state", lambda unit: "active" if unit in self.active else "inactive")
        self.patch("svc_exists", lambda unit: True)

    def test_add_and_rm_global_profiles(self):
        # Named after the server's host, then after the export's description; the config on stdin.
        self.assertIn("Name: awg-example (none given", ok(ctl.cmd_awg, "add", AWG_CONF))
        self.assertIn("Name: awg-example-2", ok(ctl.cmd_awg, "add", AWG_CONF))
        with mock.patch.object(sys, "stdin", io.StringIO(awg_vpn_link("Work VPN"))):
            self.assertIn("Name: Work-VPN", ok(ctl.cmd_awg, "add", "-"))
        conf = self.write("office.conf", AWG_CONF)
        ok(ctl.cmd_awg, "add", "office", conf)
        path = self.path("amneziawg.d/office.conf")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertIn("Endpoint = vpn.example.com:51820", ctl.read_text(path))
        self.assertEqual(ctl._awg_profiles(), ["home", "Work-VPN", "awg-example", "awg-example-2", "office"])
        self.assertEqual(ctl._awg_service("office"), "proxy-suite-awg@office")
        self.assertEqual(ctl._awg_service("home"), "proxy-suite-awg-home")
        listing = ok(ctl.cmd_awg, "list")
        self.assertRegex(listing, r"home\s+inactive\s+declared")
        self.assertRegex(listing, r"office\s+inactive\s+runtime")
        self.assertIn("office", ctl._complete_tree("awg", "rm"))
        # Refused: a taken or reserved name, the wrong order, hooks, and anything but a config.
        for args, why in [
            (("home", AWG_CONF), "declared in the NixOS configuration"),
            (("office", AWG_CONF), "already exists"),
            (("warp", AWG_CONF), "reserved"),
            (("bad name", AWG_CONF), "Invalid profile name"),
            ((AWG_CONF, "later"), "The name goes first"),
            (("hooked", AWG_CONF.replace("Address", "PostUp = id\nAddress")), "privileged"),
            (("nothing", "vless://u@x.test:443"), "Cannot read"),
        ]:
            with self.subTest(args=args[0][:10]):
                status, _, err = run(ctl.cmd_awg, "add", *args)
                self.assertNotEqual(status, 0)
                self.assertIn(why, err)
        self.assertFalse(os.path.exists(self.path("amneziawg.d/hooked.conf")))
        # rm: only what awg add added; a running one stops first, and its kill switch with it.
        self.assertIn("remove it there", run(ctl.cmd_awg, "rm", "home")[2])
        self.active.add("proxy-suite-awg@office")
        self.assertIn("Removed AmneziaWG profile: office", ok(ctl.cmd_awg, "rm", "office"))
        self.assertIn(("stop", "proxy-suite-awg@office"), self.started)
        self.assertIn(("stop", ctl.KILL_SWITCH), self.started)
        self.assertFalse(os.path.exists(path))
        self.assertNotIn("office", ctl._awg_profiles())
        # Off in the configuration: nothing to add to, and nothing listed.
        os.environ["AWG_RUNTIME_GLOBAL"] = "0"
        self.assertIn("not enabled", run(ctl.cmd_awg, "add", AWG_CONF)[2])
        self.assertEqual(ctl._awg_profiles(), ["home"])

    def test_outbounds(self):
        self.assertIn("Tag: awg-example", ok(ctl.cmd_outbounds, "add", AWG_CONF))
        self.assertEqual(ctl.read_text(self.path("outbounds.d/awg-example.port")), "18800\n")
        self.assertEqual(os.stat(self.path("outbounds.d/awg-example.awg")).st_mode & 0o777, 0o600)
        self.assertIn("proxy-suite-outbound-reload.service", self.started)
        # A file, with a tag: the next port.
        self.assertIn("Added outbound: de", ok(ctl.cmd_outbounds, "add", "de", self.write("de.conf", AWG_CONF)))
        self.assertEqual(ctl.read_text(self.path("outbounds.d/de.port")), "18801\n")
        self.assertIn("No free port", run(ctl.cmd_outbounds, "add", "fr", AWG_CONF)[2])
        self.assertIn("cannot chain", run(ctl.cmd_outbounds, "add", "fr", AWG_CONF, "--detour", "primary")[2])
        self.assertIn("--container only applies", run(ctl.cmd_outbounds, "add", "x", "vless://u@x.test:443", "--container", "c")[2])
        # A copy through a hop makes no sense for a tunnel that dials its peer itself.
        self.write("outbound-share.json", {"outbounds": {"de": {"outbound": {"type": "socks", "server": "127.0.0.1", "server_port": 18801}}}})
        self.assertIn("AmneziaWG outbound", run(ctl.cmd_outbound_chain, "de", "primary")[2])
        # rm takes the port along, which frees it.
        ok(ctl.cmd_outbounds, "rm", "de")
        self.assertFalse(os.path.exists(self.path("outbounds.d/de.port")))
        self.assertEqual(ctl._awg_free_port(), 18801)
        os.environ["AWG_RUNTIME_OUTBOUNDS"] = "0"
        self.assertIn("not enabled", run(ctl.cmd_outbounds, "add", "fr", AWG_CONF)[2])

    def test_interface_outbounds(self):
        os.environ.update(AWG_RUNTIME_IFACE_OUTBOUNDS="1", AWG_IFACE_SLOTS="2", PER_APP_VIA_RUNTIME="1")
        # --interface: a slot in <tag>.iface instead of a port, which frees nothing of the tunnels'.
        self.assertIn("Added outbound: de", ok(ctl.cmd_outbounds, "add", "de", AWG_CONF, "--interface"))
        self.assertEqual(ctl.read_text(self.path("outbounds.d/de.iface")), "0\n")
        self.assertFalse(os.path.exists(self.path("outbounds.d/de.port")))
        self.assertEqual(ctl._awg_free_port(), 18800)
        # The configuration's default kind, unless the command says.
        os.environ["AWG_RUNTIME_OUTBOUND_KIND"] = "interface"
        ok(ctl.cmd_outbounds, "add", "nl", AWG_CONF)
        self.assertEqual(ctl.read_text(self.path("outbounds.d/nl.iface")), "1\n")
        self.assertIn("No free slot", run(ctl.cmd_outbounds, "add", "fr", AWG_CONF)[2])
        ok(ctl.cmd_outbounds, "add", "fr", AWG_CONF, "--userspace")
        self.assertEqual(ctl.read_text(self.path("outbounds.d/fr.port")), "18800\n")
        # Apps can run through the interface ones.
        self.assertEqual(sorted(ctl._via_outbounds()), ["de", "nl"])
        # rm takes the slot along.
        ok(ctl.cmd_outbounds, "rm", "de")
        self.assertFalse(os.path.exists(self.path("outbounds.d/de.iface")))
        self.assertEqual(ctl._awg_free_iface_slot(), 0)
        for args, why in [
            (("x", AWG_CONF, "--interface", "--userspace"), "Pick one"),
            (("x", "vless://u@x.test:443", "--interface"), "--interface only applies"),
        ]:
            with self.subTest(args=args[-1]):
                self.assertIn(why, run(ctl.cmd_outbounds, "add", *args)[2])
        os.environ["AWG_RUNTIME_IFACE_OUTBOUNDS"] = "0"
        self.assertIn("root hosts only", run(ctl.cmd_outbounds, "add", "x", AWG_CONF, "--interface")[2])


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

    def test_exclude_takes_learned_ip_literals(self):
        os.environ.update(ZAPRET_AUTO_ENABLED="1", ZAPRET_STATE_DIR=self.dir)
        auto = self.write("zapret-hosts-auto.txt", "82.146.44.102\na.example\n")
        ok(ctl.cmd_zapret_auto, "exclude", "82.146.44.102")
        self.assertEqual(ctl.read_text(auto), "a.example\n")
        self.assertEqual(ctl.read_text(self.path("zapret-hosts-user-exclude.txt")), "82.146.44.102\n")
        ok(ctl.cmd_zapret_auto, "forget", "2001:db8::1")
        self.assertIn("zapret auto add <domain>", run(ctl.cmd_zapret_auto, "add", "1.2.3")[2])

    def test_list_names_the_strategy_remembered_for_the_apex(self):
        os.environ.update(ZAPRET_AUTO_ENABLED="1", ZAPRET_STATE_DIR=self.dir)
        self.write("zapret-hosts-auto.txt", "www.blocked.example\nnew.example\n")
        self.write(
            "circular/state.tsv",
            "# key\thost\tstrategy\tts\tmode\tsni\n"
            "rkn_tcp\tblocked.example\t3\t1\tfrozen\t\n"
            "http_rkn\tblocked.example|4\t2\t1\tauto\thcaptcha.com\n",
        )
        os.environ["ZAPRET_STRATEGIES_FILE"] = self.write(
            "strategies.json",
            {"rkn_tcp": {"3": ["fake:blob=x:repeats=6", "multisplit:pos=1", "fake:blob=y"]}},
        )
        out = run(ctl.cmd_zapret_auto, "list")[1].splitlines()
        self.assertEqual(
            out,
            [
                "www.blocked.example  rkn_tcp #3 (fake + multisplit), frozen; http_rkn #2, fake SNI hcaptcha.com",
                "new.example",
            ],
        )
        # A missing or unreadable map still names the profile and the number.
        os.environ["ZAPRET_STRATEGIES_FILE"] = self.path("gone.json")
        self.assertIn("rkn_tcp #3, frozen", run(ctl.cmd_zapret_auto, "list")[1])
        self.assertEqual(ctl._zapret_strategy_summary("notblocked.example"), "")

    def test_verdicts(self):
        """What detect.lua decided: the last verdict per name and protocol stands."""
        os.environ.update(ZAPRET_AUTO_ENABLED="1", ZAPRET_STATE_DIR=self.dir)
        self.write("zapret-hosts-auto.txt", "www.notion.so\nchat.example\nsignal.org\n")
        verdicts = self.write(
            "verdicts.tsv",
            "works\tnotion.so\ttcp\trkn_tcp\t1\n"
            "stalls\tsignal.org\tcutoff\t\t1\n"
            "works\tsignal.org\ttcp\trkn_tcp\t2\n"
            "unfixable\tdiscord.com\tudp\trkn_quic\t2\n"
            "unfixable\tchat.example\ttcp\trkn_tcp\t3\n"
            "blocked\t149.154.167.99\tip\tno answer\t4\n"
            "blocked\t203.0.113.9\tip\tno answer\t5\n"
            "reachable\t203.0.113.9\tip\t\t6\n",
        )
        status, out, err = run(ctl.cmd_zapret_auto, "list")
        self.assertEqual(status, 0)
        self.assertIn("www.notion.so  works", out)
        self.assertIn("chat.example   via the proxy: no strategy gets through", out)
        self.assertIn("signal.org     cut off after 16 KB: keeps the proxy's route", out)
        self.assertRegex(out, r"(?m)^  discord\.com +its QUIC: no strategy gets through$")
        self.assertRegex(out, r"(?m)^  149\.154\.167\.99 +blocked by address$")
        self.assertNotIn("203.0.113.9", out)
        self.assertIn("zapret auto retry", err)
        # retry clears it, and restarts zapret2 to unfreeze the rotation, when it runs.
        self.patch("svc_active", lambda unit: False)
        ok(ctl.cmd_zapret_auto, "retry", "149.154.167.99")
        self.assertNotIn("149.154.167.99", [name for name, _ in ctl._zapret_proxied()])
        self.assertTrue(ctl.read_text(verdicts).endswith("\n"))
        self.assertIn("sends nothing", run(ctl.cmd_zapret_auto, "retry", "nothing.example")[2])
        # forget drops its verdicts with it: zapret2 judges it afresh.
        ok(ctl.cmd_zapret_auto, "forget", "chat.example")
        self.assertNotIn("chat.example", ctl.read_text(verdicts))
        self.assertIn("discord.com", ctl.read_text(verdicts))

    def test_rewrite_keeps_what_nfqws2_appended_meanwhile(self):
        """nfqws2 appends verdicts without our lock: a line it added after the read survives the rename."""
        path = self.write("verdicts.tsv", "works\ta.example\ttcp\nunfixable\tb.example\ttcp\n")
        mkstemp = tempfile.mkstemp

        def appended_meanwhile(*args, **kwargs):
            with open(path, "a") as f:
                f.write("works\tc.example\ttcp\n")
            return mkstemp(*args, **kwargs)

        with mock.patch.object(ctl.tempfile, "mkstemp", appended_meanwhile):
            ctl._replace_lines(path, lambda line: "b.example" not in line)
        self.assertEqual(ctl.read_text(path), "works\ta.example\ttcp\nworks\tc.example\ttcp\n")

    def test_rewrites_take_the_lock(self):
        """Another proxy-ctl mid-edit holds .<name>.lock: this one waits for it, then gives up."""
        path = self.write("zapret-hosts-auto.txt", "a.example\n")
        with open(self.path(".zapret-hosts-auto.txt.lock"), "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            with mock.patch.object(ctl, "LOCK_WAIT", 0.2):
                status, _, err = run(ctl._replace_lines, path, lambda _: False)
        self.assertNotEqual(status, 0)
        self.assertIn("Something else is still changing", err)
        self.assertEqual(ctl.read_text(path), "a.example\n")
        # A lock planted as a symlink is not followed: the edit goes ahead without it.
        os.unlink(self.path(".zapret-hosts-auto.txt.lock"))
        victim = self.write("victim", "")
        os.symlink(victim, self.path(".zapret-hosts-auto.txt.lock"))
        ctl._replace_lines(path, lambda _: False)
        self.assertEqual(ctl.read_text(path), "")
        self.assertTrue(os.path.islink(self.path(".zapret-hosts-auto.txt.lock")))

    def test_strategy_drop_takes_z2ks_lock(self):
        """z2k writes state.tsv whole under state.tsv.lock: a fresh one is waited for, a stale one taken."""
        os.environ.update(ZAPRET_AUTO_ENABLED="1", ZAPRET_STATE_DIR=self.dir)
        state = self.write("circular/state.tsv", "rkn_tcp\ta.example\t3\t1\tauto\t\nrkn_tcp\tb.example\t2\t1\tauto\t\n")
        lock = self.write("circular/state.tsv.lock", str(int(time.time())))
        with mock.patch.object(ctl, "LOCK_WAIT", 0.2):
            status, _, err = run(ctl._zapret_strategy_drop, "a.example")
        self.assertNotEqual(status, 0)
        self.assertIn("zapret2 is still writing", err)
        self.assertIn("a.example", ctl.read_text(state))
        self.assertTrue(os.path.exists(lock))  # z2k's, not ours to remove
        self.write("circular/state.tsv.lock", str(int(time.time()) - 60))
        ctl._zapret_strategy_drop("a.example")
        self.assertEqual(ctl.read_text(state), "rkn_tcp\tb.example\t2\t1\tauto\t\n")
        self.assertFalse(os.path.exists(lock))


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

    def api(self):
        """The stats API's socket, as root (or the daemon's own user) reaches it."""
        os.environ["INBOUNDS_API"] = "unix://" + self.write("stats.sock", "")

    def test_online(self):
        answer = {"users": [{"email": "fufsob", "ips": [{"ip": "203.0.113.7", "lastSeen": 1789471207}]}]}
        self.patch("_run", lambda *a, **kw: (0, json.dumps(answer)))
        self.api()
        os.environ["INBOUNDS_STATS_FILE"] = self.write("stats.json", {"seen": {"phone": 1789135690}})
        os.environ["INBOUNDS_LINKS_FILE"] = self.write("links.json", [{"tag": "a", "user": "fufsob"}, {"tag": "a", "user": "teri"}])
        out = ok(ctl._inbound_online)
        self.assertRegex(out, r"(?m)^  fufsob +online +203\.0\.113\.7$")
        self.assertRegex(out, r"(?m)^  phone +seen 2026-09-1\d \d\d:\d\d")
        self.assertRegex(out, r"(?m)^  teri +never seen")
        # XRay not running is an error, not an empty table.
        self.patch("_run", lambda *a, **kw: (1, ""))
        self.assertNotEqual(run(ctl._inbound_online)[0], 0)

    @unittest.skipIf(os.geteuid() == 0, "root reaches any socket")
    def test_online_without_the_api(self):
        """A stats member cannot reach the API (it may reset the counters): who was online
        comes from the collector's file, read again first."""
        self.patch("_run", lambda *a, **kw: self.fail("asked the API"))
        started = []
        self.patch("systemctl", lambda *a, **kw: started.append(a))
        now = 1789471300
        self.patch("time", mock.Mock(time=lambda: now))
        os.environ["INBOUNDS_API"] = "unix://" + self.write("stats.sock", "")
        os.chmod(self.path("stats.sock"), 0o400)
        online = [{"email": "fufsob", "ips": [{"ip": "203.0.113.7", "lastSeen": now - 5}]}]
        os.environ["INBOUNDS_STATS_FILE"] = self.write("stats.json", {"at": now - 10, "online": online, "seen": {"phone": now - 9000}})
        os.environ["INBOUNDS_LINKS_FILE"] = self.write("links.json", [{"tag": "a", "user": "fufsob"}, {"tag": "a", "user": "teri"}])
        status, out, err = run(ctl._inbound_online)
        self.assertEqual(status, 0)
        self.assertEqual(started, [("--no-ask-password", "start", "proxy-suite-inbound-stats.service")])
        self.assertRegex(out, r"(?m)^  fufsob +online +203\.0\.113\.7$")
        self.assertRegex(out, r"(?m)^  phone +seen ")
        self.assertRegex(out, r"(?m)^  teri +never seen")
        self.assertNotIn("as of", err)
        # A reading a few minutes old says so; one the collector could not refresh is no answer.
        self.write("stats.json", {"at": now - 300, "online": online})
        status, out, err = run(ctl._inbound_online)
        self.assertEqual(status, 0)
        self.assertIn("collector's last reading", err)
        for stats in ({"at": now - 3600, "online": online}, {"at": now, "seen": {}}):
            with self.subTest(stats=stats):
                self.write("stats.json", stats)
                status, _, err = run(ctl._inbound_online)
                self.assertNotEqual(status, 0)
                self.assertIn("not answering", err)
        # No socket at all: the inbounds are down, whatever the collector last read.
        self.write("stats.json", {"at": now - 10, "online": online})
        os.unlink(self.path("stats.sock"))
        status, _, err = run(ctl._inbound_online)
        self.assertNotEqual(status, 0)
        self.assertIn("is proxy-suite-inbounds running", err)

    def test_online_amneziawg(self):
        answer = {"users": [{"email": "fufsob", "ips": [{"ip": "203.0.113.7", "lastSeen": 1789471207}]}]}
        self.patch("_run", lambda *a, **kw: (0, json.dumps(answer)))
        self.api()
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
                [{"name": n, "route": n} for n in ("direct", "proxychains", "tun", "tproxy", "zapret")]
                + [{"name": "game", "route": "tun", "outbound": "de-2"}],
            ),
            PER_APP_VIA_FILE=self.write("via.json", {"de-2": {"interface": "awg-de", "mark": 23040}}),
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
            # Nothing else runs in the slice, so this user's marking goes afterwards.
            self.assertIn(("stop", f"{base}-user@{os.getuid()}.service"), self.calls)
            self.assertIn(("--user", "stop", f"{base}-anchor.service"), self.calls)
            # The backend every user shares: brought up by the marking unit (Requires=), and
            # gone after the last one by itself (StopWhenUnneeded=), never stopped here.
            self.assertFalse([c for c in self.calls if c[0] in ("start", "stop") and c[-1] == f"{base}.service"])

    def test_cleanup_when_scope_fails(self):
        self.scope_status = 3
        status, _, _ = run(ctl.cmd_apps, "run", "tun", "--", "false")
        self.assertEqual(status, 3)
        self.assertIn(("stop", f"proxy-suite-per-app-tun-user@{os.getuid()}.service"), self.calls)

    def test_global_proxy_runs_plain(self):
        # A wrapPerApp launcher must still start the app; the global mode carries it.
        self.active = {"proxy-suite-tun.service"}
        status, _, err = run(ctl.cmd_apps, "run", "tproxy", "--", "curl", "x")
        self.assertEqual(status, 0)
        self.assertEqual(self.execed, ["curl", "x"])
        self.assertIn("proxy-suite-tun.service is active", err)
        self.assertFalse(any(c[0] == "systemd-run" for c in self.calls))

    def test_via_interface_outbound(self):
        # Its own slice and units, keyed by the tag in hex: "de-2" must not nest under "de".
        key = "awg-" + "de-2".encode().hex()
        uid = os.getuid()
        for args, label in ((("--via", "de-2", "--", "curl", "x"), "de-2"), (("game", "--", "curl", "x"), "game")):
            self.calls.clear()
            status, _, _ = run(ctl.cmd_apps, "run", *args)
            self.assertEqual(status, 0)
            base = f"proxy-suite-per-app-via-{key}"
            scope = next(c for c in self.calls if c[0] == "systemd-run")
            self.assertIn(f"--unit={base}-{label}-{os.getpid()}", scope)
            self.assertIn(f"--slice={base}", scope)
            self.assertEqual(scope[-2:], ("curl", "x"))
            self.assertIn(("--user", "start", f"proxy-suite-per-app-via-anchor@{key}.service"), self.calls)
            # The via unit first: the marking goes in its table.
            starts = [c[1] for c in self.calls if c[0] == "start"]
            self.assertEqual(starts, [f"proxy-suite-per-app-via@{key}.service", f"proxy-suite-per-app-via-user@{uid}-{key}.service"])
            # Only this user's marking stops; the last one's takes the via unit down itself.
            stops = [c[1] for c in self.calls if c[0] == "stop"]
            self.assertEqual(stops, [f"proxy-suite-per-app-via-user@{uid}-{key}.service"])

    def test_via_without_pin_slots(self):
        status, _, err = run(ctl.cmd_apps, "run", "--via", "nl", "--", "curl")
        self.assertNotEqual(status, 0)
        self.assertIn("this configuration has no pin slots", err)
        self.assertIn('"interface" AmneziaWG outbounds: de-2.', err)
        self.assertFalse(any(c[0] == "systemd-run" for c in self.calls))

    def test_via_pin_slots(self):
        os.environ.update(PER_APP_PIN_TUN="1", PER_APP_PIN_TPROXY="1")
        self.patch("_outbound_tags", lambda: ["nl", "de-2"])
        self.patch("_outbound_groups", lambda: {})
        hexed = "nl".encode().hex()
        uid = os.getuid()
        # TUN when both are there; a profile's route, or --route, picks.
        for args, route, label in (
            (("--via", "nl", "--", "curl"), "tun", "nl"),
            (("--via", "nl", "--route", "tproxy", "--", "curl"), "tproxy", "nl"),
            (("--route", "tproxy", "--via", "nl", "curl"), "tproxy", "nl"),
        ):
            with self.subTest(args=args):
                self.calls.clear()
                status, _, _ = run(ctl.cmd_apps, "run", *args)
                self.assertEqual(status, 0)
                key = f"{route}-{hexed}"
                scope = next(c for c in self.calls if c[0] == "systemd-run")
                self.assertIn(f"--slice=proxy-suite-per-app-via-{key}", scope)
                self.assertIn(f"--unit=proxy-suite-per-app-via-{key}-{label}-{os.getpid()}", scope)
                self.assertIn(("start", f"proxy-suite-per-app-via-{route}@{hexed}.service"), self.calls)
                self.assertIn(("start", f"proxy-suite-per-app-via-user@{uid}-{key}.service"), self.calls)
                # The pin, and the per-app TUN backend it holds, go by themselves.
                self.assertEqual([c[1] for c in self.calls if c[0] == "stop"], [f"proxy-suite-per-app-via-user@{uid}-{key}.service"])
        self.assertIn("Unknown outbound: fr", run(ctl.cmd_apps, "run", "--via", "fr", "--", "curl")[2])
        self.assertIn("--route is tun or tproxy", run(ctl.cmd_apps, "run", "--via", "nl", "--route", "zapret", "--", "curl")[2])
        os.environ["PER_APP_PIN_TUN"] = "0"
        self.assertIn("no pin slots of per-app tun here", run(ctl.cmd_apps, "run", "--via", "nl", "--route", "tun", "--", "curl")[2])
        # A global TProxy takes pinned apps past their route, as it does the other routes.
        self.active = {"proxy-suite-tproxy.service"}
        run(ctl.cmd_apps, "run", "--via", "nl", "--", "curl", "x")
        self.assertEqual(self.execed, ["curl", "x"])

    def test_runtime_profiles(self):
        os.environ.update(PER_APP_PIN_TPROXY="1", RUNTIME_APPS_DIR=self.path("apps.d"))
        os.makedirs(self.path("apps.d"))
        self.patch("_outbound_tags", lambda: ["nl"])
        self.patch("_outbound_groups", lambda: {})
        self.assertIn("Added app profile: play", ok(ctl.cmd_apps, "add", "play", "--via", "nl"))
        ok(ctl.cmd_apps, "add", "chat", "--route", "proxychains")
        ok(ctl.cmd_apps, "add", "vpn", "--via", "de-2")
        # Readable by whoever runs apps; the pin route chosen now, an interface outbound needs none.
        self.assertEqual(os.stat(self.path("apps.d/play.json")).st_mode & 0o777, 0o644)
        added = {p["name"]: p for p in ctl._per_app_profiles() if p.get("runtime")}
        self.assertEqual((added["play"]["route"], added["play"]["outbound"]), ("tproxy", "nl"))
        self.assertEqual((added["chat"]["route"], added["chat"]["outbound"]), ("proxychains", None))
        self.assertEqual(added["vpn"]["outbound"], "de-2")
        listing = ok(ctl.cmd_apps, "list")
        self.assertRegex(listing, r"play\s+tproxy\s+nl\s+runtime")
        self.assertRegex(listing, r"tun\s+tun\s+-\s+declared")
        self.assertIn("play", ctl._complete_tree("apps", "rm"))
        # Run like a declared one.
        self.calls.clear()
        self.assertEqual(run(ctl.cmd_apps, "run", "play", "--", "curl")[0], 0)
        self.assertIn(("start", f"proxy-suite-per-app-via-tproxy@{'nl'.encode().hex()}.service"), self.calls)
        for args, why in [
            (("tun", "--route", "tun"), "declared in the NixOS configuration"),
            (("Bad", "--route", "tun"), "Invalid profile name"),
            (("x", "--route", "warp"), "--route is one of"),
            (("x", "--via", "nl", "--route", "proxychains"), "needs --route tun or tproxy"),
            (("x",), "usage"),
        ]:
            with self.subTest(args=args):
                status, out, err = run(ctl.cmd_apps, "add", *args)
                self.assertNotEqual(status, 0)
                self.assertIn(why, (out + err).lower() if why == "usage" else err)
        self.assertIn("remove it there", run(ctl.cmd_apps, "rm", "tun")[2])
        self.assertIn("Removed app profile: play", ok(ctl.cmd_apps, "rm", "play"))
        self.assertFalse(os.path.exists(self.path("apps.d/play.json")))
        self.assertIn("No app profile", run(ctl.cmd_apps, "rm", "play")[2])

    def test_runtime_profiles_read_only_regular_files(self):
        # apps.d is the group's: a FIFO or a symlink to /dev/zero would hang or fill root's proxy-ctl.
        os.environ["RUNTIME_APPS_DIR"] = self.path("apps.d")
        self.write("apps.d/play.json", {"route": "direct"})
        self.write("apps.d/big.json", json.dumps({"route": "direct", "pad": "x" * ctl.RUNTIME_APP_MAX_BYTES}))
        os.mkfifo(self.path("apps.d/fifo.json"))
        os.symlink("/dev/zero", self.path("apps.d/zero.json"))
        os.symlink(self.path("apps.d/play.json"), self.path("apps.d/link.json"))
        self.assertEqual([p["name"] for p in ctl._runtime_apps()], ["play"])

    def test_via_global_awg_profile(self):
        # Brought up apart for the app, first; the last user's marking takes it down.
        os.environ.update(PER_APP_VIA_PROFILES="1", AWG_PROFILES_FILE=self.write("awg.json", ["netcup"]))
        key = "app-" + "netcup".encode().hex()
        status, _, _ = run(ctl.cmd_apps, "run", "--via", "netcup", "--", "curl", "x")
        self.assertEqual(status, 0)
        starts = [c[1] for c in self.calls if c[0] == "start"]
        self.assertEqual(starts[:2], ["proxy-suite-awg-app@netcup.service", f"proxy-suite-per-app-via@{key}.service"])
        scope = next(c for c in self.calls if c[0] == "systemd-run")
        self.assertIn(f"--slice=proxy-suite-per-app-via-{key}", scope)
        self.assertNotIn(("stop", "proxy-suite-awg-app@netcup.service"), self.calls)
        self.assertIn("netcup", ctl._complete_tree("apps", "run", "--via"))
        # Up globally, it carries the app as it is.
        self.calls.clear()
        self.active = {"proxy-suite-awg-netcup.service"}
        status, _, err = run(ctl.cmd_apps, "run", "--via", "netcup", "--", "curl", "x")
        self.assertEqual(self.execed, ["curl", "x"])
        self.assertIn("proxy-suite-awg-netcup.service is active", err)
        self.assertNotIn(("start", "proxy-suite-awg-app@netcup.service"), self.calls)

    def test_via_names_both_a_profile_and_an_outbound(self):
        # "nl" is an outbound and a global profile: a bare name is refused, a prefix picks.
        os.environ.update(PER_APP_VIA_PROFILES="1", PER_APP_PIN_TPROXY="1", AWG_PROFILES_FILE=self.write("awg.json", ["nl"]))
        self.patch("_outbound_tags", lambda: ["nl"])
        self.patch("_outbound_groups", lambda: {})
        status, _, err = run(ctl.cmd_apps, "run", "--via", "nl", "--", "curl")
        self.assertNotEqual(status, 0)
        self.assertIn("say --via awg:nl or --via outbound:nl", err)
        hexed = "nl".encode().hex()
        for via, unit in (("awg:nl", f"proxy-suite-per-app-via@app-{hexed}.service"), ("outbound:nl", f"proxy-suite-per-app-via-tproxy@{hexed}.service")):
            with self.subTest(via=via):
                self.calls.clear()
                self.assertEqual(run(ctl.cmd_apps, "run", "--via", via, "--", "curl")[0], 0)
                self.assertIn(("start", unit), self.calls)
                scope = next(c for c in self.calls if c[0] == "systemd-run")
                self.assertTrue(any(a.startswith("--unit=") and ":" not in a for a in scope))
        self.assertIn("No global AmneziaWG profile 'fr'", run(ctl.cmd_apps, "run", "--via", "awg:fr", "--", "curl")[2])
        self.assertIn("--via takes an outbound", run(ctl.cmd_apps, "run", "--via", "wg:nl", "--", "curl")[2])

    def test_cleanup_reads_only_own_scopes(self):
        # Other users' marking and the pins of per-app TUN are systemd's to weigh
        # (StopWhenUnneeded=): cleanup asks only after this user's own apps.
        self.calls.clear()
        run(ctl.cmd_apps, "run", "tun", "--", "curl")
        self.assertFalse([c for c in self.calls if c[0] == "list-units"])
        self.assertIn(("--user", "list-units", "--type=scope", "--state=running", "--plain", "--no-legend", "proxy-suite-per-app-tun-*"), self.calls)

    def test_via_under_global_tun_runs_plain(self):
        self.active = {"proxy-suite-tun.service"}
        run(ctl.cmd_apps, "run", "--via", "de-2", "--", "curl", "x")
        self.assertEqual(self.execed, ["curl", "x"])

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


class InboundRuntimeTest(EnvTest):
    """inbounds.runtime through proxy-ctl: the tool does the work, proxy-ctl reloads after."""

    def setUp(self):
        super().setUp()
        tool = os.environ.get("INBOUNDS_RUNTIME_TOOL")
        if not tool:
            self.skipTest("INBOUNDS_RUNTIME_TOOL is not set")
        spool = self.path("inbounds.d")
        os.makedirs(spool)
        spec = {
            "serverAddress": "vpn.example.com",
            "shareLinks": True,
            "users": {"bob": {"order": 1, "uuid": "11111111-1111-4111-8111-111111111111"}, "idle": {"order": None}},
            "serverSource": {"ipv4": None, "ipv6": None, "declared": []},
            "listeners": [
                {"tag": "vless-in", "type": "vless", "port": 443, "order": 1000, "via": "proxy", "listen": "::",
                 "users": [{"name": "bob", "uuid": "11111111-1111-4111-8111-111111111111"}]},
            ],
            "runtime": {
                "spool": spool,
                "ports": ["20000-20010"],
                "vias": ["proxy", "block"],
                "defaultVia": "proxy",
                "fallbackDests": [],
                "tlsCertificates": {},
                "listenerDefaults": {
                    "address": "::", "acceptProxyProtocol": False, "fallbacks": [], "flow": None, "order": 1000, "port": 443,
                    "method": "2022-blake3-aes-128-gcm", "serverPassword": None, "sharePort": None, "shareAddress": None,
                    "hysteria": {"masquerade": None, "salamander": {"enable": False, "password": None}},
                    "reality": {"enable": False, "dest": "www.microsoft.com:443", "serverNames": [], "privateKey": None,
                                "publicKey": None, "shortIds": [""], "xver": 0},
                    "tls": {"enable": False, "alpn": None, "serverName": None},
                    "transport": {"type": "raw", "path": "/", "host": None, "mode": None, "serviceName": "", "trustedXForwardedFor": []},
                },
            },
        }
        os.environ.update(
            INBOUNDS_ENABLED="1",
            INBOUNDS_RUNTIME_ENABLED="1",
            INBOUNDS_SPEC_FILE=self.write("spec.json", spec),
        )
        self.started = []

        def systemctl(*args, **kw):
            self.started.append(args)
            return 0, ""

        self.patch("systemctl", systemctl)

    def test_users_and_listeners(self):
        out = ok(ctl.cmd_inbounds, "users", "add", "alice", "--listener", "vless-in")
        self.assertEqual(out, "Added user alice (order 2) on vless-in\n")
        self.assertEqual(self.started, [("start", "proxy-suite-inbounds-reload.service")])
        out = ok(ctl.cmd_inbounds, "add", "friends", "vless", "--port", "20001", "--user", "alice")
        self.assertIn("Added listener friends", out)
        rows = {r["name"]: r for r in json.loads(ok(ctl.cmd_inbounds, "users", "--json"))}
        self.assertEqual(rows["alice"]["listeners"], ["friends", "vless-in"])
        self.assertEqual(rows["bob"]["source"], "nix")
        self.assertEqual(ctl._inbound_runtime_names("listeners", "runtime"), {"friends": "runtime"})
        status, _, err = run(ctl.cmd_inbounds, "bind", "bob", "vless-in")
        self.assertEqual(status, 1)
        self.assertIn("declared in the configuration", err)
        # A refusal changes nothing, so nothing is reloaded.
        self.assertEqual(len(self.started), 2)
        ok(ctl.cmd_inbounds, "rm", "friends")
        self.assertIn("vless-in", ok(ctl.cmd_inbounds, "users"))

    def test_bad_listener_is_refused(self):
        status, _, err = run(ctl.cmd_inbounds, "add", "far", "vless", "--port", "30000")
        self.assertEqual(status, 1)
        self.assertIn("not in inbounds.runtime.ports", err)
        self.assertEqual(self.started, [])

    def test_off(self):
        os.environ["INBOUNDS_RUNTIME_ENABLED"] = "0"
        spec = ctl.read_json(os.environ["INBOUNDS_SPEC_FILE"])
        spec["runtime"] = None
        os.environ["INBOUNDS_SPEC_FILE"] = self.write("spec-off.json", spec)
        status, _, err = run(ctl.cmd_inbounds, "users", "add", "alice")
        self.assertEqual(status, 1)
        self.assertIn("inbounds.runtime.enable", err)
        # The declared users are still listed, on a listener or not.
        rows = {r["name"]: r for r in ctl._inbound_runtime_rows("users")}
        self.assertEqual(rows["bob"]["listeners"], ["vless-in"])
        self.assertEqual(rows["idle"]["listeners"], [])
        self.assertIn("idle", ok(ctl.cmd_inbounds, "users"))
        os.environ["INBOUNDS_ENABLED"] = "0"
        self.assertEqual(ctl._inbound_runtime_rows("users"), [])

    def test_completion(self):
        ok(ctl.cmd_inbounds, "users", "add", "alice")
        self.assertIn("alice", ctl._complete_tree("inbounds", "users", "rm", ""))
        self.assertNotIn("bob", ctl._complete_tree("inbounds", "users", "rm", ""))
        self.assertIn("--reality", ctl._complete_tree("inbounds", "add", "x", "vless", ""))


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

    def test_inbound_share_variant_link(self):
        self.write(
            "inbounds/links.json",
            [
                {"tag": "in", "user": "u", "type": "vless", "port": 443, "link": "vless://x@h:443?fp=chrome", "outbound": {"server": "h"}},
                {"tag": "in", "user": "u", "type": "vless", "port": 443, "link": "vless://x@h:443?fp=firefox",
                 "outbound": {"server": "h", "fp": "firefox"}, "variant": "firefox"},
            ],
        )
        # The listener's own link unless --variant names one of its variants.
        self.assertEqual(ok(ctl.cmd_inbounds, "link", "in", "u"), "vless://x@h:443?fp=chrome\n")
        self.assertEqual(ok(ctl.cmd_inbounds, "link", "in", "--variant=firefox"), "vless://x@h:443?fp=firefox\n")
        self.assertEqual(json.loads(ok(ctl.cmd_inbounds, "link", "in", "u", "--variant=firefox", "--json"))["fp"], "firefox")
        status, _, err = run(ctl.cmd_inbounds, "link", "in", "--variant=safari")
        self.assertNotEqual(status, 0)
        self.assertIn("No share variant 'safari'", err)
        self.patch("svc_state", lambda unit: "active")
        self.assertRegex(ok(ctl.cmd_inbounds, "list"), r"(?m)^  in +u +vless \(firefox\) +443 +active$")

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

    def test_newnym_as_the_group_goes_through_the_unit(self):
        """On a system install only root opens the socket: the group starts a root unit."""
        os.environ["PRIVILEGED"] = "1"
        started = []
        self.patch("systemctl", lambda *a, **kw: started.append(a) or (0, None))
        with mock.patch.object(ctl.os, "geteuid", return_value=1000):
            ok(ctl.cmd_tor, "newnym")
        self.assertIn(("start", "proxy-suite-tor-newnym.service"), started)
        self.assertEqual(self.received, [])

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

    def test_status_exit_code_is_is_actives(self):
        """`if proxy-ctl tor status` means running: 3 when not, as systemctl says it, and no bootstrap line."""
        self.patch("systemctl", lambda *a, **kw: (0, None) if a[0] == "cat" else (3, "inactive\n"))
        status, out, _ = run(ctl.cmd_tor)
        self.assertEqual(status, 3)
        self.assertNotIn("bootstrap", out)
        for fn in (ctl.cmd_proxy, ctl.cmd_zapret, ctl.COMMANDS["ssh"]):
            with self.subTest(fn=fn):
                self.assertEqual(run(fn, "status")[0], 3)


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

    def test_unit_states_by_id(self):
        blocks = "Id=proxy-suite-tun.service\nLoadState=loaded\nActiveState=failed\n\nId=proxy-suite-socks.service\nLoadState=loaded\nActiveState=active\n"
        self.patch("systemctl", lambda *a, **kw: (0, blocks))
        # Out of order, one missing: each state still lands on its own unit.
        self.assertEqual(ctl._unit_states(["proxy-suite-socks", "proxy-suite-zapret", "proxy-suite-tun"]), {"proxy-suite-socks": "active", "proxy-suite-tun": "failed"})
        self.patch("systemctl", lambda *a, **kw: (1, blocks))
        self.assertEqual(ctl._unit_states(["proxy-suite-socks"]), {})

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
