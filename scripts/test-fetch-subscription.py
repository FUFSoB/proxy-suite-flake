#!/usr/bin/env python3

import base64
import contextlib
import http.server
import importlib.util
import io
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from unittest import mock

import proxy_parsing
from proxy_parsing import (
    decode_subscription,
    fetch_raw,
    parse_hybrid_subscription,
    parse_subscription,
)

VLESS_URI = (
    "vless://uuid@example.com:443?security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"
    "&fp=chrome&sni=cdn.example.com&sid=abcd"
)
VLESS_XHTTP_URI = "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fx"
VLESS_ECH_URI = "vless://uuid@example.com:443?type=tcp&security=tls&sni=cdn.example.com&ech=udp%3A%2F%2F1.1.1.1"
SS_URI = "ss://{}@ss.example.com:8388".format(
    base64.urlsafe_b64encode(b"chacha20-ietf-poly1305:passw0rd").decode().rstrip("=")
)
HY2_URI = "hy2://secret@hy.example.com:443?sni=hy.example.com"
INVALID_URI = "wireguard://example.com:51820"


def _make_b64_payload(*uris: str) -> bytes:
    text = "\n".join(uris)
    return base64.b64encode(text.encode())


def _load_fetch_subscription():
    here = os.path.dirname(os.path.abspath(proxy_parsing.__file__))
    spec = importlib.util.spec_from_file_location("fetch_subscription", os.path.join(here, "fetch-subscription.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_fetcher(
    server_data: bytes,
    tag_prefix: str = "test",
    *,
    routing_mark: int | None = None,
    backend: str = "sing-box",
):
    lines = decode_subscription(server_data)
    if backend == "hybrid":
        return parse_hybrid_subscription(lines, tag_prefix, routing_mark)
    return parse_subscription(lines, tag_prefix, routing_mark, backend)


class FetchSubscriptionTests(unittest.TestCase):
    def test_fetch_rejects_non_http_schemes(self):
        for url in ("file:///etc/shadow", "ftp://example.com/sub", "data:text/plain,x"):
            with self.assertRaisesRegex(ValueError, "http"):
                fetch_raw(url)

    def test_fetch_refuses_redirects_off_http(self):
        # A subscription server may redirect; not to a local file or FTP, which root would fetch.
        class Redirect(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", "ftp://127.0.0.1/sub" if self.path == "/ftp" else "file:///etc/passwd")
                self.end_headers()

            def log_message(self, *_):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Redirect)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_port}"
        # urllib refuses file: itself, and follows ftp: unless told not to.
        with self.assertRaises(urllib.error.HTTPError):
            fetch_raw(f"{base}/file")
        with self.assertRaisesRegex(ValueError, "redirected off http"):
            fetch_raw(f"{base}/ftp")

    def test_fetch_refuses_https_to_http_redirect(self):
        handler = proxy_parsing._HttpOnlyRedirects()
        request = urllib.request.Request("https://sub.example.com/s")
        with self.assertRaisesRegex(ValueError, "from https:// to http://"):
            handler.redirect_request(request, None, 302, "Found", {}, "http://sub.example.com/s")
        # http to https, and https to https, still follow.
        self.assertIsNotNone(handler.redirect_request(request, None, 302, "Found", {}, "https://cdn.example.com/s"))
        plain = urllib.request.Request("http://sub.example.com/s")
        self.assertIsNotNone(handler.redirect_request(plain, None, 302, "Found", {}, "https://sub.example.com/s"))

    def test_fetch_refuses_redirects_nearer_to_this_host(self):
        handler = proxy_parsing._HttpOnlyRedirects()
        public = urllib.request.Request("http://203.0.113.5/s")
        for target in ("http://127.0.0.1:8080/", "http://169.254.169.254/latest/meta-data/",
                       "http://[::1]/", "http://localhost/", "http://192.168.1.1/", "http://2130706433/"):
            with self.subTest(target=target):
                with self.assertRaisesRegex(ValueError, "this host or a private network"):
                    handler.redirect_request(public, None, 302, "Found", {}, target)
        # Served from there already: a converter on loopback, a server on the LAN.
        local = urllib.request.Request("http://127.0.0.1:25500/sub")
        self.assertIsNotNone(handler.redirect_request(local, None, 302, "Found", {}, "http://127.0.0.1:25500/s2"))
        lan = urllib.request.Request("http://192.168.1.2/sub")
        self.assertIsNotNone(handler.redirect_request(lan, None, 302, "Found", {}, "http://192.168.1.3/s"))
        with self.assertRaisesRegex(ValueError, "private network"):
            handler.redirect_request(lan, None, 302, "Found", {}, "http://127.0.0.1/s")
        # A name other than localhost is not looked up.
        with mock.patch.object(proxy_parsing.socket, "getaddrinfo", side_effect=AssertionError("looked up")):
            self.assertIsNotNone(handler.redirect_request(public, None, 302, "Found", {}, "http://cdn.example.com/s"))

    def test_fetch_has_a_total_deadline(self):
        # Every byte inside the socket timeout, but the body never ends.
        class Trickle(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", "1000")
                self.end_headers()
                try:
                    for _ in range(1000):
                        self.wfile.write(b"x")
                        self.wfile.flush()
                        time.sleep(0.1)
                except OSError:
                    pass

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Trickle)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        fetch = _load_fetch_subscription()
        stderr = io.StringIO()
        started = time.monotonic()
        with mock.patch.object(fetch, "OVERALL_DEADLINE_SECONDS", 1), \
                mock.patch.object(fetch.sys, "argv", ["fetch-subscription.py", "--tag-prefix", "t"]), \
                mock.patch.object(fetch.sys, "stdin", io.StringIO(f"http://127.0.0.1:{server.server_port}/")), \
                contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            fetch.main()
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("longer than 1s", stderr.getvalue())

    def test_one_bad_entry_does_not_take_the_others(self):
        # sing-box refuses to start on any of these; each is skipped, the good one kept.
        bad = [
            VLESS_URI.replace("pbk=SbVK", "pbk=Sb+K"),
            VLESS_URI + "&flow=bogus",
            "ss://{}@ss.example.com:8388".format(base64.urlsafe_b64encode(b"rc4:pw").decode()),
            "tuic://00000000-0000-0000-0000-000000000000:pw@t.example.com:443?congestion_control=reno",
        ]
        obs = run_fetcher(_make_b64_payload(*bad, SS_URI))
        self.assertEqual([ob["type"] for ob in obs], ["shadowsocks"])
        self.assertEqual(obs[0]["method"], "chacha20-ietf-poly1305")

    def test_base64_payload_mixed_protocols(self):
        payload = _make_b64_payload(VLESS_URI, SS_URI, HY2_URI)
        obs = run_fetcher(payload)
        self.assertEqual(len(obs), 3)
        types = {ob["type"] for ob in obs}
        self.assertEqual(types, {"vless", "shadowsocks", "hysteria2"})

    def test_urlsafe_and_wrapped_base64_payloads(self):
        text = "\n".join([VLESS_URI, SS_URI, HY2_URI]).encode() + b"~?>"
        urlsafe = base64.urlsafe_b64encode(text).rstrip(b"=")
        self.assertTrue(b"-" in urlsafe or b"_" in urlsafe)
        std = base64.b64encode(text)
        wrapped = b"\r\n".join(std[i : i + 76] for i in range(0, len(std), 76))
        for payload in (urlsafe, wrapped):
            self.assertEqual(len(run_fetcher(payload)), 3)

    def test_plain_text_payload(self):
        payload = "\n".join([VLESS_URI, SS_URI]).encode()
        obs = run_fetcher(payload)
        self.assertEqual(len(obs), 2)

    def test_tag_prefix_applied(self):
        payload = _make_b64_payload(VLESS_URI)
        obs = run_fetcher(payload, tag_prefix="mysub")
        self.assertTrue(obs[0]["tag"].startswith("mysub-"))

    def test_links_map_tags_to_lines(self):
        lines = [VLESS_URI, INVALID_URI, VLESS_XHTTP_URI]
        links: dict[str, str] = {}
        obs = parse_subscription(lines, "sub", None, "sing-box", links)
        self.assertEqual(links, {obs[0]["tag"]: VLESS_URI})
        links = {}
        hybrid = parse_hybrid_subscription(lines, "sub", None, links)
        self.assertEqual(links, {hybrid["singBox"][0]["tag"]: VLESS_URI, hybrid["xray"][0]["tag"]: VLESS_XHTTP_URI})

    def test_remark_used_in_tag(self):
        uri_with_remark = VLESS_URI + "#My Server DE"
        payload = _make_b64_payload(uri_with_remark)
        obs = run_fetcher(payload, tag_prefix="sub")
        # Remark should be slugified and appear in tag
        self.assertIn("My-Server-DE", obs[0]["tag"])

    def test_remark_special_chars_slugified(self):
        uri_with_remark = VLESS_URI + "#Server @ 🇩🇪 #1"
        payload = _make_b64_payload(uri_with_remark)
        obs = run_fetcher(payload, tag_prefix="sub")
        tag = obs[0]["tag"]
        # Tag must contain only safe characters
        self.assertRegex(tag, r"^[a-zA-Z0-9_/\-]+$")

    def test_non_latin_remark_kept_in_tag(self):
        # Flag emoji + Cyrillic remarks must stay distinguishable, not all
        # collapse to the "proxy" fallback.
        payload = _make_b64_payload(
            VLESS_URI + "#\U0001F1E9\U0001F1EA \u0413\u0435\u0440\u043c\u0430\u043d\u0438\u044f",
            SS_URI + "#\U0001F1EF\U0001F1F5 \u042f\u043f\u043e\u043d\u0438\u044f",
        )
        obs = run_fetcher(payload, tag_prefix="sub")
        self.assertEqual(
            [ob["tag"] for ob in obs],
            ["sub-\u0413\u0435\u0440\u043c\u0430\u043d\u0438\u044f", "sub-\u042f\u043f\u043e\u043d\u0438\u044f"],
        )

    def test_tag_deduplication(self):
        # Two entries with the same remark → distinct tags
        uri1 = VLESS_URI + "#Server"
        uri2 = SS_URI + "#Server"
        payload = _make_b64_payload(uri1, uri2)
        obs = run_fetcher(payload, tag_prefix="sub")
        tags = [ob["tag"] for ob in obs]
        self.assertEqual(len(tags), len(set(tags)), "Tags must be unique")

    def test_invalid_lines_skipped(self):
        payload = _make_b64_payload(INVALID_URI, VLESS_URI)
        obs = run_fetcher(payload)
        self.assertEqual(len(obs), 1)
        self.assertEqual(obs[0]["type"], "vless")

    def test_invalid_lines_warn_on_stderr(self):
        # A syntactically invalid URI for a known scheme should warn, not crash.
        broken_vless = "vless://not-a-valid-vless-url"
        payload = _make_b64_payload(broken_vless, SS_URI)
        obs = run_fetcher(payload)
        self.assertEqual(len(obs), 1)

    def test_routing_mark_applied(self):
        payload = _make_b64_payload(VLESS_URI, SS_URI)
        obs = run_fetcher(payload, routing_mark=2)
        for ob in obs:
            self.assertEqual(ob["routing_mark"], 2)

    def test_all_invalid_fails(self):
        payload = _make_b64_payload(INVALID_URI, "not-a-uri-at-all")
        self.assertEqual(run_fetcher(payload), [])

    def test_index_tag_fallback_when_no_remark(self):
        # URIs without a remark should get index-based tags
        payload = _make_b64_payload(VLESS_URI, SS_URI)
        obs = run_fetcher(payload, tag_prefix="sub")
        for ob in obs:
            # Tags follow the pattern sub-<index>
            self.assertRegex(ob["tag"], r"^sub-\d+$")

    def test_empty_lines_ignored(self):
        text = f"\n\n{VLESS_URI}\n\n{SS_URI}\n\n"
        payload = base64.b64encode(text.encode())
        obs = run_fetcher(payload)
        self.assertEqual(len(obs), 2)

    def test_trailing_whitespace_in_uris(self):
        text = f"{VLESS_URI}   \r\n{SS_URI}  \r\n"
        payload = base64.b64encode(text.encode())
        obs = run_fetcher(payload)
        self.assertEqual(len(obs), 2)

    def test_hybrid_subscription_preserves_xray_only_entries(self):
        payload = _make_b64_payload(VLESS_URI, VLESS_XHTTP_URI, VLESS_ECH_URI)
        obs = run_fetcher(payload, backend="hybrid")
        self.assertEqual(len(obs["singBox"]), 1)
        self.assertEqual(len(obs["xray"]), 2)
        self.assertEqual(obs["singBox"][0]["type"], "vless")
        self.assertEqual(obs["xray"][0]["streamSettings"]["network"], "xhttp")
        self.assertEqual(
            obs["xray"][1]["streamSettings"]["tlsSettings"]["echConfigList"],
            "udp://1.1.1.1",
        )

    def test_hybrid_subscription_deduplicates_tags_across_backend_lists(self):
        payload = _make_b64_payload(
            VLESS_URI + "#Same",
            VLESS_XHTTP_URI + "#Same",
            VLESS_ECH_URI + "#Same",
        )
        obs = run_fetcher(payload, tag_prefix="sub", backend="hybrid")
        tags = [ob["tag"] for ob in obs["singBox"] + obs["xray"]]
        self.assertEqual(tags, ["sub-Same", "sub-Same-2", "sub-Same-3"])

    def test_hybrid_subscription_all_invalid_returns_empty_backend_lists(self):
        payload = _make_b64_payload(INVALID_URI, "not-a-uri-at-all")
        obs = run_fetcher(payload, backend="hybrid")
        self.assertEqual(obs, {"singBox": [], "xray": []})


# Whoever serves a subscription picks its servers, and urltest prefers the fastest: an entry
# on this host would win, and make whatever listens there (Tor, the proxy itself) the exit.
LOCAL_SERVER_URIS = [
    "socks5://127.0.0.1:9050#fast",
    "socks5://127.8.9.10:1080",
    "socks5://localhost:1080",
    "socks5://Tor.LOCALHOST.:1080",
    "socks5://[::1]:1080",
    "socks5://[::ffff:127.0.0.1]:1080",
    "socks5://0.0.0.0:1080",
    "socks5://0.1.2.3:1080",
    "socks5://[::]:1080",
    # inet_aton's spellings of 127.0.0.1, which a resolver may hand back as an address.
    "socks5://2130706433:1080",
    "socks5://0x7f.1:1080",
    "socks5://127.1:1080",
    "http://169.254.169.254:80",
    "socks5://[fe80::1]:1080",
    "socks5://224.0.0.1:1080",
    "socks5://[ff02::1]:1080",
    VLESS_URI.replace("example.com", "127.0.0.1"),
    # VMess's "add" is no URL: backends dial a bracketed one all the same.
    "vmess://"
    + base64.b64encode(
        b'{"add":"[127.0.0.1]","port":"80","id":"11111111-1111-1111-1111-111111111111","net":"ws","path":"/x"}'
    ).decode(),
    "vmess://"
    + base64.b64encode(b'{"add":"[::1]","port":"80","id":"11111111-1111-1111-1111-111111111111"}').decode(),
]
PRIVATE_SERVER_URIS = [
    "http://192.168.1.1:80",
    "socks5://10.0.0.2:1080",
    "socks5://172.16.5.4:1080",
    "socks5://100.64.0.1:1080",
    "socks5://[fd00::1]:1080",
    "socks5://[::ffff:192.168.1.1]:1080",
]
PUBLIC_SERVER_URIS = [
    "socks5://1.1.1.1:1080",
    "socks5://[2606:4700::1111]:1080",
    "socks5://localhost.example.com:1080",
    "socks5://172.32.0.1:1080",
    "socks5://3735928559:1080",
]


class SubscriptionServerTests(unittest.TestCase):
    def parse(self, uris, *, backend="sing-box", allow_private=False):
        lines = decode_subscription(_make_b64_payload(*uris))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            if backend == "hybrid":
                obs = parse_hybrid_subscription(lines, "sub", None, allow_private=allow_private)
            else:
                obs = parse_subscription(lines, "sub", None, backend, allow_private=allow_private)
        return obs, stderr.getvalue()

    def test_local_servers_are_dropped(self):
        for uri in LOCAL_SERVER_URIS:
            for allow_private in (False, True):
                with self.subTest(uri=uri, allow_private=allow_private):
                    obs, err = self.parse([uri, SS_URI], allow_private=allow_private)
                    self.assertEqual([ob["server"] for ob in obs], ["ss.example.com"])
                    self.assertIn("skipping entry 0", err)

    def test_private_servers_need_the_opt_in(self):
        for uri in PRIVATE_SERVER_URIS:
            with self.subTest(uri=uri):
                obs, err = self.parse([uri, SS_URI])
                self.assertEqual(len(obs), 1)
                self.assertIn("private address", err)
                obs, _ = self.parse([uri, SS_URI], allow_private=True)
                self.assertEqual(len(obs), 2)

    def test_public_servers_are_kept(self):
        obs, err = self.parse(PUBLIC_SERVER_URIS)
        self.assertEqual(len(obs), len(PUBLIC_SERVER_URIS), err)

    def test_xray_and_hybrid_drop_local_servers_too(self):
        local = VLESS_XHTTP_URI.replace("example.com", "127.0.0.1")
        obs, _ = self.parse([local, VLESS_URI], backend="xray")
        self.assertEqual([ob["settings"]["address"] for ob in obs], ["example.com"])
        obs, err = self.parse([local, VLESS_XHTTP_URI], backend="hybrid")
        self.assertEqual(obs["singBox"], [])
        self.assertEqual([ob["settings"]["address"] for ob in obs["xray"]], ["example.com"])
        # Refused once, not once per backend.
        self.assertEqual(err.count("skipping entry 0"), 1)

    def test_xhttp_download_settings_address_is_checked(self):
        extra = urllib.parse.quote(
            '{"downloadSettings":{"Address":"127.0.0.1","port":80,"network":"xhttp","security":"none"}}'
        )
        local = f"{VLESS_XHTTP_URI}&extra={extra}"
        obs, err = self.parse([local, VLESS_URI], backend="xray")
        self.assertEqual(len(obs), 1)
        self.assertIn("is this host", err)

    def test_ech_resolver_is_checked(self):
        # XRay fetches an ECH config from the resolver echConfigList names, by its own dialer.
        for ech in ("udp://127.0.0.1", "cdn.example.com+https://127.0.0.1:9/dns-query", "h2c://[::1]/q"):
            with self.subTest(ech=ech):
                uri = VLESS_ECH_URI.replace("udp%3A%2F%2F1.1.1.1", urllib.parse.quote(ech, safe=""))
                obs, err = self.parse([uri, VLESS_URI], backend="xray")
                self.assertEqual(len(obs), 1)
                self.assertIn("is this host", err)
        obs, err = self.parse([VLESS_ECH_URI], backend="xray")
        self.assertEqual(len(obs), 1, err)

    def test_entries_the_backend_would_refuse_are_skipped(self):
        bad = [
            # Without TLS XRay refuses VLESS to a public server.
            "vless://11111111-1111-1111-1111-111111111111@1.1.1.1:443",
            "ss://{}@ss.example.com:8388".format(base64.urlsafe_b64encode(b"aes-128-gcm:").decode()),
            "trojan://@trojan.example.com:443",
            VLESS_XHTTP_URI + "&extra=" + urllib.parse.quote('{"xPaddingBytes":NaN}'),
        ]
        for uri in bad:
            with self.subTest(uri=uri):
                obs, err = self.parse([uri, VLESS_URI], backend="xray")
                self.assertEqual(len(obs), 1, err)
                self.assertIn("skipping entry 0", err)

    def test_insecure_entries_need_the_opt_in(self):
        insecure = "hy2://secret@hy.example.com:443?sni=hy.example.com&insecure=1"
        obs, err = self.parse([insecure, HY2_URI])
        self.assertEqual(len(obs), 1)
        self.assertIn("certificate checks off", err)
        lines = decode_subscription(_make_b64_payload(insecure, HY2_URI))
        with contextlib.redirect_stderr(io.StringIO()):
            kept = parse_subscription(lines, "sub", None, "sing-box", allow_insecure=True)
        self.assertEqual(len(kept), 2)

    def test_pinned_insecure_entries_go_to_xray(self):
        pinned = f"hy2://secret@hy.example.com:443?sni=hy.example.com&insecure=1&pinSHA256={'ab' * 32}"
        obs, err = self.parse([pinned], backend="hybrid")
        self.assertEqual(obs["singBox"], [], err)
        self.assertEqual(obs["xray"][0]["streamSettings"]["tlsSettings"]["pinnedPeerCertSha256"], "ab" * 32)

    def test_dropped_entry_leaves_no_link(self):
        links: dict[str, str] = {}
        lines = decode_subscription(_make_b64_payload("socks5://127.0.0.1:9050#fast", SS_URI))
        with contextlib.redirect_stderr(io.StringIO()):
            parse_subscription(lines, "sub", None, "sing-box", links)
        self.assertEqual(list(links.values()), [SS_URI])

    def test_check_server_does_not_look_names_up(self):
        with mock.patch.object(proxy_parsing.socket, "getaddrinfo", side_effect=AssertionError("looked up")):
            for host in (None, "", "example.com", "127.0.0.1.nip.io", "not an address", "12ab.example"):
                with self.subTest(host=host):
                    proxy_parsing.check_server(host)


# Stands in for the backend: refuses a config holding a "bad" tag, naming the first one
# the way FAKE_STYLE says, and counts its runs.
FAKE_BACKEND = """
import json, os, sys
with open(os.environ["FAKE_RUNS"], "a") as handle:
    handle.write("run\\n")
obs = json.load(sys.stdin)["outbounds"]
bad = [i for i, ob in enumerate(obs) if ob["tag"].startswith("bad")]
if not bad:
    sys.exit(0)
style = os.environ["FAKE_STYLE"]
if style == "xray":
    tag = obs[bad[0]]["tag"]
    sys.exit(f"Failed to start: main: failed to load config files: [stdin:] > infra/conf: "
             f"failed to build outbound config with tag {tag} > infra/conf: no")
if style == "sing-box":
    sys.exit(f"\\x1b[31mFATAL\\x1b[0m[0000] initialize outbound[{bad[0]}]: no")
sys.exit("panic: runtime error: invalid memory address or nil pointer dereference")
"""


class BackendCheckTests(unittest.TestCase):
    """fetch-subscription.py's check of each batch by the backend's own binary."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.binary = os.path.join(self.tmp.name, "backend")
        self.runs = os.path.join(self.tmp.name, "runs")
        with open(self.binary, "w") as handle:
            handle.write(f"#!{sys.executable}\n{FAKE_BACKEND}")
        os.chmod(self.binary, 0o755)
        self.fetch = _load_fetch_subscription()

    def keep(self, tags, style="xray", kind="xray"):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), \
                mock.patch.dict(os.environ, {"FAKE_RUNS": self.runs, "FAKE_STYLE": style}):
            kept = self.fetch._Checker(kind, self.binary).keep([{"tag": t} for t in tags])
        return [ob["tag"] for ob in kept], stderr.getvalue()

    def run_count(self):
        with open(self.runs) as handle:
            return len(handle.readlines())

    def test_refused_entries_go_and_the_rest_stay(self):
        for style, kind in (("xray", "xray"), ("sing-box", "sing-box"), ("none", "xray"), ("none", "sing-box")):
            with self.subTest(style=style, kind=kind):
                kept, err = self.keep(["a", "bad1", "b", "c", "bad2", "d"], style, kind)
                self.assertEqual(kept, ["a", "b", "c", "d"])
                self.assertIn("'bad1'", err)
                self.assertIn("'bad2'", err)

    def test_a_named_refusal_costs_one_run(self):
        tags = [f"bad{i}" if i % 50 == 7 else str(i) for i in range(500)]
        for style in ("xray", "sing-box"):
            with self.subTest(style=style):
                if os.path.exists(self.runs):
                    os.unlink(self.runs)
                kept, _ = self.keep(tags, style, style)
                self.assertEqual(kept, [t for t in tags if not t.startswith("bad")])
                # The empty config, one run per bad entry, and the one that passes.
                self.assertEqual(self.run_count(), 1 + 10 + 1)

    def test_a_clean_batch_takes_one_run(self):
        kept, _ = self.keep([str(i) for i in range(100)])
        self.assertEqual(len(kept), 100)
        # The empty config first, then the batch.
        self.assertEqual(self.run_count(), 2)

    def test_a_check_that_does_not_run_checks_nothing(self):
        self.binary = "/nonexistent/backend"
        kept, err = self.keep(["a", "bad"])
        self.assertEqual(kept, ["a", "bad"])
        self.assertIn("does not run", err)

    def test_out_of_runs_keeps_the_rest_unchecked(self):
        tags = [f"bad{i}" for i in range(10)] + [str(i) for i in range(20)]
        for style in ("xray", "none"):
            with self.subTest(style=style), mock.patch.object(self.fetch, "MAX_CHECK_RUNS", 5):
                kept, err = self.keep(tags, style)
                self.assertTrue(set(map(str, range(20))) <= set(kept), kept)
                self.assertIn("left unchecked", err)


if __name__ == "__main__":
    unittest.main()
