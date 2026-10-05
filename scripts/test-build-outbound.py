#!/usr/bin/env python3

import base64
import json
import unittest
import urllib.parse

import proxy_parsing
from proxy_parsing import build_outbound


def run_parser(url: str):
    return build_outbound(url, "test-outbound")


def run_xray_parser(url: str):
    return build_outbound(url, "test-outbound", backend="xray")


def vmess_url(extra: dict) -> str:
    body = {"add": "example.com", "port": 443, "id": "uuid", "net": "tcp", **extra}
    return "vmess://" + base64.b64encode(json.dumps(body).encode()).decode()


class BuildOutboundTests(unittest.TestCase):
    def test_vless_reality(self):
        ob = run_parser(
            "vless://uuid@example.com:443?security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&fp=chrome&sni=cdn.example.com&sid=abcd"
        )
        self.assertEqual(ob["type"], "vless")
        self.assertEqual(ob["server"], "example.com")
        self.assertEqual(ob["tls"]["reality"]["public_key"], "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc")

    def test_vless_reality_germany_main_shape(self):
        ob = run_parser(
            "vless://uuid@example.com:443?type=tcp&security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&fp=qq&sni=last.fm&sid=8a54&spx=%2F-%2Fen%2Fgp%2Fbestsellers&flow=xtls-rprx-vision&encryption=none"
        )
        self.assertEqual(ob["type"], "vless")
        self.assertEqual(ob["server_port"], 443)
        self.assertEqual(ob["flow"], "xtls-rprx-vision")
        self.assertEqual(ob["tls"]["server_name"], "last.fm")
        self.assertEqual(ob["tls"]["utls"]["fingerprint"], "qq")
        self.assertEqual(ob["tls"]["reality"]["short_id"], "8a54")
        self.assertNotIn("spider_x", ob["tls"]["reality"])
        self.assertNotIn("transport", ob)

    def test_xray_vless_reality_germany_main_shape(self):
        ob = run_xray_parser(
            "vless://uuid@example.com:443?type=tcp&security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&fp=qq&sni=last.fm&sid=8a54&spx=%2F-%2Fen%2Fgp%2Fbestsellers&flow=xtls-rprx-vision&encryption=none"
        )
        self.assertEqual(ob["protocol"], "vless")
        self.assertEqual(ob["settings"]["address"], "example.com")
        self.assertEqual(ob["settings"]["flow"], "xtls-rprx-vision")
        self.assertEqual(ob["streamSettings"]["network"], "raw")
        self.assertEqual(ob["streamSettings"]["sockopt"]["domainStrategy"], "UseIP")
        self.assertEqual(ob["streamSettings"]["realitySettings"]["serverName"], "last.fm")
        self.assertEqual(ob["streamSettings"]["realitySettings"]["fingerprint"], "qq")
        self.assertEqual(
            ob["streamSettings"]["realitySettings"]["spiderX"], "/-/en/gp/bestsellers"
        )

    def test_vless_raw_transport_is_tcp(self):
        # XRay renamed the tcp network to "raw"; it is still plain TCP.
        ob = run_parser(
            "vless://uuid@example.com:443?type=raw&security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&fp=chrome&sni=cdn.example.com"
        )
        self.assertNotIn("transport", ob)

    def test_at_sign_in_query_does_not_eat_the_host(self):
        ob = run_parser(
            "vless://uuid@example.com:443?type=tcp&security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"
            "&fp=chrome&sni=cdn.example.com&Telegram=@somechannel,@somechannel"
        )
        self.assertEqual(ob["server"], "example.com")
        self.assertEqual(ob["server_port"], 443)

    def test_trailing_path_is_not_part_of_the_port(self):
        ob = run_parser(
            "vless://uuid@example.com:23576/?type=tcp&security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&fp=chrome&sni=cdn.example.com"
        )
        self.assertEqual(ob["server_port"], 23576)

    def test_port_out_of_range_is_rejected(self):
        """sing-box stores it as uint16 and refuses to start, so one bad entry in a
        subscription would take every other outbound down with it."""
        for url in (
            "vless://uuid@example.com:70000?type=tcp",
            "trojan://pw@example.com:0",
            "ss://YWVzLTI1Ni1nY206cHc@example.com:99999",
        ):
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "out of range"):
                build_outbound(url, "test-outbound")

    def test_reality_empty_fingerprint_falls_back_to_chrome(self):
        # sing-box's REALITY client refuses to start without a uTLS block.
        ob = run_parser(
            "vless://uuid@example.com:443?type=tcp&security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&fp=&sni=cdn.example.com"
        )
        self.assertEqual(ob["tls"]["utls"]["fingerprint"], "chrome")

    def test_xray_only_fingerprint_rejected_for_sing_box(self):
        url = (
            "vless://uuid@example.com:443?type=tcp&security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"
            "&fp=hellochrome_120&sni=cdn.example.com"
        )
        with self.assertRaises(ValueError):
            run_parser(url)
        self.assertEqual(
            run_xray_parser(url)["streamSettings"]["realitySettings"]["fingerprint"],
            "hellochrome_120",
        )
        # XRay's REALITY refuses the two it takes for plain TLS only.
        for fp in ("unsafe", "hellogolang", "bogus"):
            with self.subTest(fp=fp), self.assertRaisesRegex(ValueError, "XRay would refuse"):
                run_xray_parser(url.replace("hellochrome_120", fp))

    def test_values_a_backend_refuses_to_start_on_are_rejected(self):
        """Each of these took sing-box check or xray -test down with the whole config;
        rejected here, a subscription skips just that entry."""
        reality = (
            "vless://uuid@example.com:443?security=reality&sni=a.example.com"
            "&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=ab"
        )
        tuic = "tuic://00000000-0000-0000-0000-000000000000:pw@example.com:443"
        k16 = base64.b64encode(b"k" * 16).decode()
        cases = [
            (reality + "&flow=xtls-rprx-direct", "both", "flow"),
            (reality + "&flow=xtls-rprx-vision-udp443", "sing-box", "flow"),
            (reality.replace("pbk=SbVK", "pbk=SbV+"), "both", "pbk"),
            (reality.replace("pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc", "pbk=pubkey"), "both", "pbk"),
            (reality.replace("sid=ab", "sid=abc"), "both", "sid"),
            (reality.replace("sid=ab", "sid=0123456789abcdef00"), "both", "sid"),
            (reality.replace("sid=ab", "sid=zz"), "both", "sid"),
            (reality + "&spx=nopath", "xray", "spx"),
            (reality + "&spx=%2F%25zz", "xray", "spx"),
            (reality + "&spx=%2Fa%01b", "xray", "spx"),
            (reality.replace("uuid@", "x" * 31 + "@"), "xray", "VLESS id"),
            ("vless://uuid@example.com:443?type=xhttp&security=tls&mode=bogus", "xray", "xhttp mode"),
            ("vless://uuid@example.com:443?type=h2&security=tls", "xray", "transport"),
            ("vless://uuid@example.com:443?type=quic&security=tls", "xray", "transport"),
            ("trojan://pw@example.com:443?security=tls&fp=bogus", "both", "fingerprint"),
            (vmess_url({"scy": "aes-128-ctr"}), "sing-box", "VMess security"),
            (vmess_url({"scy": "bogus"}), "sing-box", "VMess security"),
            (vmess_url({"id": 123}), "both", "VMess id"),
            (vmess_url({"id": None}), "xray", "VMess id"),
            (tuic + "?congestion_control=reno", "sing-box", "congestion_control"),
            ("tuic://not-a-uuid:pw@example.com:443", "sing-box", "TUIC uuid"),
            ("hy2://pw@example.com:443?mport=a-b", "both", "mport"),
            ("hy2://pw@example.com:443?mport=1-70000", "both", "mport"),
            ("hy2://pw@example.com:443?mport=0-5", "both", "mport"),
            ("hy2://pw@example.com:443?mport=30000-20000", "both", "mport"),
            ("hy2://pw@example.com:443?insecure=1&pinSHA256=abcd", "xray", "pinSHA256"),
            ("trojan://@example.com:443?security=tls", "both", "password is empty"),
            ("hy2://pw@example.com:443?obfs=salamander", "both", "obfs-password"),
            ("ss://plain:pw@example.com:8388", "both", "method"),
            ("ss://aes-128-ctr:pw@example.com:8388", "xray", "method"),
            ("ss://chacha20-poly1305:pw@example.com:8388", "sing-box", "method"),
            ("ss://2022-blake3-aes-128-gcm:pw@example.com:8388", "both", "base64 key"),
            ("ss://2022-blake3-aes-128-gcm:" + base64.b64encode(b"k" * 32).decode() + "@example.com:8388", "both", "base64 key"),
            (f"ss://2022-blake3-chacha20-poly1305:{k16}%3A{k16}@example.com:8388", "both", "single key"),
        ]
        for url, backends, message in cases:
            for backend in ("sing-box", "xray") if backends == "both" else (backends,):
                with self.subTest(url=url, backend=backend), self.assertRaisesRegex(ValueError, message):
                    build_outbound(url, "test-outbound", backend=backend)

    def test_values_one_backend_takes_still_parse(self):
        reality = (
            "vless://uuid@example.com:443?security=reality&sni=a.example.com"
            "&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=0123456789ABCDEF"
        )
        self.assertEqual(run_xray_parser(reality + "&flow=xtls-rprx-vision-udp443")["settings"]["flow"],
                         "xtls-rprx-vision-udp443")
        self.assertEqual(run_parser(reality)["tls"]["reality"]["short_id"], "0123456789ABCDEF")
        self.assertEqual(run_xray_parser(vmess_url({"scy": "aes-128-ctr"}))["settings"]["security"], "aes-128-ctr")
        self.assertEqual(run_parser(vmess_url({"scy": "aes-128-cfb"}))["security"], "aes-128-cfb")
        # XRay takes a space (and non-ASCII) in spiderX; only control characters and bad escapes kill it.
        spx = run_xray_parser(reality + "&spx=%2Fa%20b%C3%A9")["streamSettings"]["realitySettings"]["spiderX"]
        self.assertEqual(spx, "/a b\u00e9")
        self.assertEqual(run_xray_parser("ss://chacha20-poly1305:pw@example.com:8388")["settings"]["method"],
                         "chacha20-poly1305")
        self.assertEqual(run_parser("ss://aes-128-ctr:pw@example.com:8388")["method"], "aes-128-ctr")
        k16 = base64.b64encode(b"k" * 16).decode()
        ss2022 = run_parser(f"ss://2022-blake3-aes-128-gcm:{k16}%3A{k16}@example.com:8388")
        self.assertEqual(ss2022["password"], f"{k16}:{k16}")

    def test_hysteria2_port_hopping_takes_lone_ports(self):
        # sing-box refuses a bare "443"; it is the one-port range.
        ob = run_parser("hy2://pw@example.com:443?mport=443, 20000-30000")
        self.assertEqual(ob["server_ports"], ["443:443", "20000:30000"])
        remote = run_xray_parser("hy2://pw@example.com:443?mport=443,20000-30000")
        self.assertEqual(remote["streamSettings"]["finalmask"]["udp"][0]["settings"]["remotePorts"], "443-443,20000-30000")

    def test_hysteria2_pin_replaces_insecure_for_xray(self):
        pin = ":".join(["AB"] * 32)
        url = f"hy2://pw@example.com:443?sni=a.example.com&insecure=1&pinSHA256={pin}"
        tls = run_xray_parser(url)["streamSettings"]["tlsSettings"]
        self.assertEqual(tls["pinnedPeerCertSha256"], "ab" * 32)
        # sing-box pins only a public key: the link stays insecure there.
        self.assertTrue(run_parser(url)["tls"]["insecure"])

    def test_reality_without_pbk_is_rejected_clearly(self):
        with self.assertRaisesRegex(ValueError, "pbk"):
            run_parser("vless://uuid@example.com:443?security=reality&type=tcp")

    def test_vless_httpupgrade_transport(self):
        ob = run_parser(
            "vless://uuid@example.com:443?type=httpupgrade&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fupgrade"
        )
        self.assertEqual(ob["transport"]["type"], "httpupgrade")
        self.assertEqual(ob["transport"]["host"], "cdn.example.com")
        self.assertEqual(ob["transport"]["path"], "/upgrade")

    def test_vless_quic_transport(self):
        ob = run_parser("vless://uuid@example.com:443?type=quic&security=tls&sni=cdn.example.com")
        self.assertEqual(ob["transport"]["type"], "quic")

    def test_vless_xhttp_fails_loudly(self):
        with self.assertRaisesRegex(ValueError, "unsupported VLESS transport 'xhttp'"):
            run_parser(
                "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com"
            )

    def test_xray_vless_xhttp(self):
        ob = run_xray_parser(
            "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fx"
        )
        self.assertEqual(ob["protocol"], "vless")
        self.assertEqual(ob["settings"]["address"], "example.com")
        self.assertEqual(ob["settings"]["id"], "uuid")
        self.assertEqual(ob["streamSettings"]["network"], "xhttp")
        self.assertEqual(ob["streamSettings"]["xhttpSettings"]["path"], "/x")

    def test_xray_xhttp_extra_keeps_ordinary_settings(self):
        extra = json.dumps({"xPaddingBytes": "100-1000", "downloadSettings": {"address": "dl.example.com"}})
        ob = run_xray_parser(
            "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com&extra="
            + urllib.parse.quote(extra)
        )
        self.assertEqual(ob["streamSettings"]["xhttpSettings"]["extra"]["xPaddingBytes"], "100-1000")

    def test_xray_xhttp_extra_cannot_name_local_files(self):
        # XRay holds CAP_NET_ADMIN: a subscription must not make it write masterKeyLog or read a key.
        extra = json.dumps(
            {
                "downloadSettings": {
                    "tlsSettings": {"masterKeyLog": "/etc/x", "certificates": [{"keyFile": "/root/k"}]}
                }
            }
        )
        with self.assertRaisesRegex(ValueError, "keyfile, masterkeylog"):
            run_xray_parser(
                "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com&extra="
                + urllib.parse.quote(extra)
            )

    def test_xray_xhttp_extra_cannot_set_socket_options(self):
        # A mark or interface would step around proxy-suite's routing; a dialerProxy chains elsewhere.
        for extra, left in (
            ({"downloadSettings": {"address": "dl.example.com", "sockopt": {"mark": 0, "tcpFastOpen": True}}},
             {"downloadSettings": {"address": "dl.example.com", "sockopt": {"tcpFastOpen": True}}}),
            ({"downloadSettings": {"sockopt": {"customSockopt": [], "TProxy": "redirect"}}},
             {"downloadSettings": {"sockopt": {}}}),
            ({"downloadSettings": {"sockopt": {"dialerProxy": "direct", "interface": "eth0"}}},
             {"downloadSettings": {"sockopt": {}}}),
            ({"Mark": 1, "xPaddingBytes": "100-1000"}, {"xPaddingBytes": "100-1000"}),
            # The Kelvin sign, which Go folds to k as Python's lower() does.
            ({"downloadSettings": {"sockopt": {"mar\u212a": 0}}}, {"downloadSettings": {"sockopt": {}}}),
        ):
            with self.subTest(extra=extra):
                ob = run_xray_parser(
                    "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com&extra="
                    + urllib.parse.quote(json.dumps(extra))
                )
                self.assertEqual(ob["streamSettings"]["xhttpSettings"]["extra"], left)
        # Go's JSON decoding folds U+017F to s: XRay reads this as masterKeyLog, so a
        # non-ASCII key is refused outright.
        with self.assertRaisesRegex(ValueError, "names local files"):
            run_xray_parser(
                "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com&extra="
                + urllib.parse.quote(json.dumps({"downloadSettings": {"tlsSettings": {"ma\u017fterKeyLog": "/etc/x"}}}))
            )

    def test_xray_vless_ech(self):
        ob = run_xray_parser(
            "vless://uuid@example.com:443?type=tcp&security=tls&sni=cdn.example.com&ech=udp%3A%2F%2F1.1.1.1"
        )
        self.assertEqual(ob["streamSettings"]["tlsSettings"]["echConfigList"], "udp://1.1.1.1")

    def test_xray_socks_uses_current_flat_settings_shape(self):
        ob = run_xray_parser("socks5://user:pass@example.com:1080")
        self.assertEqual(ob["protocol"], "socks")
        self.assertEqual(ob["settings"]["address"], "example.com")
        self.assertEqual(ob["settings"]["user"], "user")
        self.assertNotIn("servers", ob["settings"])

    def test_xray_shadowsocks_uses_current_flat_settings_shape(self):
        credentials = (
            base64.urlsafe_b64encode(b"chacha20-ietf-poly1305:passw0rd")
            .decode()
            .rstrip("=")
        )
        ob = run_xray_parser(f"ss://{credentials}@ss.example.com:8388")
        self.assertEqual(ob["protocol"], "shadowsocks")
        self.assertEqual(ob["settings"]["address"], "ss.example.com")
        self.assertEqual(ob["settings"]["method"], "chacha20-ietf-poly1305")
        self.assertNotIn("servers", ob["settings"])

    def test_vless_ech_fails_loudly(self):
        with self.assertRaisesRegex(ValueError, "unsupported VLESS parameter 'ech'"):
            run_parser(
                "vless://uuid@example.com:443?type=tcp&security=tls&sni=cdn.example.com&ech=blob"
            )

    def test_vmess(self):
        payload = {
            "add": "vmess.example.com",
            "port": "443",
            "id": "00000000-0000-0000-0000-000000000000",
            "aid": "0",
            "scy": "auto",
            "net": "ws",
            "host": "cdn.example.com",
            "path": "/ws",
            "tls": "tls",
            "sni": "cdn.example.com",
        }
        encoded = base64.b64encode(json.dumps(payload).encode()).decode()
        ob = run_parser(f"vmess://{encoded}")
        self.assertEqual(ob["type"], "vmess")
        self.assertEqual(ob["transport"]["type"], "ws")
        self.assertEqual(ob["tls"]["server_name"], "cdn.example.com")

    def test_vmess_with_external_remark(self):
        payload = {
            "add": "vmess.example.com",
            "port": "443",
            "id": "00000000-0000-0000-0000-000000000000",
            "aid": "0",
            "scy": "auto",
        }
        encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
        ob = run_parser(f"vmess://{encoded}#Subscription Remark")
        self.assertEqual(ob["type"], "vmess")
        self.assertEqual(ob["server"], "vmess.example.com")

    def test_vmess_blank_fields_are_defaults(self):
        payload = {"add": "vmess.example.com", "port": 443, "id": "u", "aid": "", "scy": ""}
        encoded = base64.b64encode(json.dumps(payload).encode()).decode()
        ob = run_parser(f"vmess://{encoded}")
        self.assertEqual((ob["alter_id"], ob["security"]), (0, "auto"))

    def test_socks4_keeps_its_bare_userid(self):
        ob = run_parser("socks4://me@10.0.0.1:1080")
        self.assertEqual((ob["version"], ob["username"]), ("4", "me"))
        self.assertNotIn("password", ob)

    def test_blank_parameters_fall_back_to_the_server(self):
        # Panels emit "&sni=&host=&path=" for everything left unset.
        ob = run_parser("vless://uuid@example.com:443?security=tls&sni=&type=ws&host=&path=")
        self.assertEqual(ob["tls"]["server_name"], "example.com")
        self.assertEqual(ob["transport"]["headers"]["Host"], "example.com")
        self.assertEqual(ob["transport"]["path"], "/")
        tuic = run_parser(
            "tuic://00000000-0000-0000-0000-000000000000:pw@example.com:443?alpn=&congestion_control=&udp_relay_mode="
        )
        self.assertEqual(tuic["tls"]["alpn"], ["h3"])
        self.assertEqual((tuic["congestion_control"], tuic["udp_relay_mode"]), ("bbr", "native"))

    def test_vmess_alpn_list_and_string_agree(self):
        as_list = run_parser(vmess_url({"tls": "tls", "alpn": ["h2", "http/1.1"]}))
        as_text = run_parser(vmess_url({"tls": "tls", "alpn": "h2, http/1.1"}))
        self.assertEqual(as_list["tls"]["alpn"], ["h2", "http/1.1"])
        self.assertEqual(as_text["tls"]["alpn"], ["h2", "http/1.1"])

    def test_trojan(self):
        ob = run_parser("trojan://secret@example.com:443?sni=tls.example.com&fp=chrome")
        self.assertEqual(ob["type"], "trojan")
        self.assertEqual(ob["password"], "secret")
        self.assertEqual(ob["tls"]["server_name"], "tls.example.com")

    def test_shadowsocks(self):
        credentials = (
            base64.urlsafe_b64encode(b"chacha20-ietf-poly1305:passw0rd")
            .decode()
            .rstrip("=")
        )
        ob = run_parser(f"ss://{credentials}@ss.example.com:8388")
        self.assertEqual(ob["type"], "shadowsocks")
        self.assertEqual(ob["method"], "chacha20-ietf-poly1305")

    def test_shadowsocks_legacy_full_base64(self):
        legacy = (
            base64.urlsafe_b64encode(
                b"chacha20-ietf-poly1305:passw0rd@legacy.example.com:8388"
            )
            .decode()
            .rstrip("=")
        )
        ob = run_parser(f"ss://{legacy}#Legacy Server")
        self.assertEqual(ob["type"], "shadowsocks")
        self.assertEqual(ob["server"], "legacy.example.com")
        self.assertEqual(ob["server_port"], 8388)
        self.assertEqual(ob["method"], "chacha20-ietf-poly1305")
        self.assertEqual(ob["password"], "passw0rd")

    def test_shadowsocks_plain_userinfo(self):
        ob = run_parser("ss://none:plain%20pass@plain.example.com:8388")
        self.assertEqual(ob["type"], "shadowsocks")
        self.assertEqual(ob["method"], "none")
        self.assertEqual(ob["password"], "plain pass")

    def test_shadowsocks_legacy_ipv6_strips_brackets(self):
        legacy = (
            base64.urlsafe_b64encode(b"none:pass@[2001:db8::1]:8388")
            .decode()
            .rstrip("=")
        )
        ob = run_parser(f"ss://{legacy}#Legacy IPv6")
        self.assertEqual(ob["server"], "2001:db8::1")
        self.assertEqual(ob["server_port"], 8388)

    def test_hysteria2(self):
        ob = run_parser(
            "hy2://secret@example.com:443?sni=hy.example.com&insecure=1&obfs=salamander&obfs-password=mask"
        )
        self.assertEqual(ob["type"], "hysteria2")
        self.assertTrue(ob["tls"]["insecure"])
        self.assertEqual(ob["obfs"]["password"], "mask")

    def test_xray_hysteria2(self):
        ob = run_xray_parser(
            "hy2://secret@example.com:443?sni=hy.example.com&obfs=salamander&obfs-password=mask"
        )
        self.assertEqual(ob["protocol"], "hysteria")
        self.assertEqual(ob["settings"]["address"], "example.com")
        self.assertNotIn("password", ob["settings"])
        self.assertEqual(ob["streamSettings"]["network"], "hysteria")
        self.assertEqual(ob["streamSettings"]["tlsSettings"]["serverName"], "hy.example.com")
        self.assertEqual(ob["streamSettings"]["hysteriaSettings"]["auth"], "secret")
        self.assertEqual(
            ob["streamSettings"]["finalmask"]["udp"],
            [{"type": "salamander", "settings": {"password": "mask"}}],
        )

    def test_xray_hysteria2_insecure_fails_loudly(self):
        with self.assertRaisesRegex(ValueError, "allowInsecure"):
            run_xray_parser("hy2://secret@example.com:443?sni=hy.example.com&insecure=1")

    def test_tuic(self):
        ob = run_parser(
            "tuic://00000000-0000-0000-0000-000000000000:secret@example.com:443?sni=tuic.example.com&alpn=h3,hq-29"
        )
        self.assertEqual(ob["type"], "tuic")
        self.assertEqual(ob["tls"]["alpn"], ["h3", "hq-29"])

    def test_anytls(self):
        ob = run_parser("anytls://p%40ss@example.com:443?sni=a.example.com&insecure=1&fp=chrome#name")
        self.assertEqual(ob["type"], "anytls")
        self.assertEqual(ob["password"], "p@ss")
        self.assertEqual(ob["tls"], {"enabled": True, "server_name": "a.example.com", "insecure": True,
                                     "utls": {"enabled": True, "fingerprint": "chrome"}})
        with self.assertRaisesRegex(ValueError, "unsupported XRay outbound type"):
            run_xray_parser("anytls://pw@example.com:443")

    def test_naive(self):
        ob = run_parser("naive+https://user:pass@example.com:443#name")
        self.assertEqual((ob["type"], ob["username"], ob["password"]), ("naive", "user", "pass"))
        self.assertEqual(ob["tls"]["server_name"], "example.com")
        self.assertNotIn("quic", ob)
        self.assertTrue(run_parser("naive+quic://user:pass@example.com:443")["quic"])

    def test_socks5(self):
        ob = run_parser("socks5://user:pass@example.com:1080")
        self.assertEqual(ob["type"], "socks")
        self.assertEqual(ob["version"], "5")
        self.assertEqual(ob["username"], "user")

    def test_proxy_userinfo_allows_at_in_password(self):
        ob = run_parser("socks5://user:p@ss@example.com:1080")
        self.assertEqual(ob["username"], "user")
        self.assertEqual(ob["password"], "p@ss")
        self.assertEqual(ob["server"], "example.com")

    def test_https_proxy(self):
        ob = run_parser("https://proxy.example.com:8443")
        self.assertEqual(ob["type"], "http")
        self.assertEqual(ob["tls"]["server_name"], "proxy.example.com")

    def test_invalid_scheme_fails(self):
        with self.assertRaisesRegex(ValueError, "unsupported scheme"):
            run_parser("wireguard://example.com")

    def test_trojan_xhttp_fails_loudly_on_sing_box(self):
        url = "trojan://pw@example.com:443?security=tls&type=xhttp&path=/p"
        with self.assertRaisesRegex(ValueError, "unsupported Trojan transport 'xhttp'"):
            run_parser(url)
        self.assertEqual(
            run_xray_parser(url)["streamSettings"]["network"], "xhttp"
        )

    def test_vmess_kcp_fails_loudly(self):
        with self.assertRaisesRegex(ValueError, "unsupported VMess transport 'kcp'"):
            run_parser(vmess_url({"net": "kcp"}))

    def test_xray_only_fingerprint_rejected_for_sing_box_trojan_and_vmess(self):
        trojan = "trojan://pw@example.com:443?security=tls&fp=unsafe"
        with self.assertRaises(ValueError):
            run_parser(trojan)
        self.assertEqual(
            run_xray_parser(trojan)["streamSettings"]["tlsSettings"]["fingerprint"],
            "unsafe",
        )
        vmess = vmess_url({"tls": "tls", "fp": "unsafe"})
        with self.assertRaises(ValueError):
            run_parser(vmess)
        self.assertEqual(
            run_xray_parser(vmess)["streamSettings"]["tlsSettings"]["fingerprint"],
            "unsafe",
        )

    def test_backend_aware_parser_type_error_is_not_arity_fallback(self):
        def broken_parser(url: str, tag: str, backend: str):
            raise TypeError("real parser bug")

        proxy_parsing.PARSERS["broken"] = broken_parser
        proxy_parsing.BACKEND_AWARE_PARSERS.add("broken")
        try:
            with self.assertRaisesRegex(TypeError, "real parser bug"):
                build_outbound("broken://example.com:443", "test-outbound")
        finally:
            del proxy_parsing.PARSERS["broken"]
            proxy_parsing.BACKEND_AWARE_PARSERS.remove("broken")


if __name__ == "__main__":
    unittest.main()
