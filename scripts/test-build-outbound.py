#!/usr/bin/env python3

import base64
import json
import unittest

from proxy_parsing import build_outbound


def run_parser(url: str):
    return build_outbound(url, "test-outbound")


class BuildOutboundTests(unittest.TestCase):
    def test_vless_reality(self):
        ob = run_parser(
            "vless://uuid@example.com:443?security=reality&pbk=pubkey&fp=chrome&sni=cdn.example.com&sid=abcd"
        )
        self.assertEqual(ob["type"], "vless")
        self.assertEqual(ob["server"], "example.com")
        self.assertEqual(ob["tls"]["reality"]["public_key"], "pubkey")

    def test_vless_reality_germany_main_shape(self):
        ob = run_parser(
            "vless://uuid@example.com:443?type=tcp&security=reality&pbk=pubkey&fp=qq&sni=last.fm&sid=8a54&spx=%2F-%2Fen%2Fgp%2Fbestsellers&flow=xtls-rprx-vision&encryption=none"
        )
        self.assertEqual(ob["type"], "vless")
        self.assertEqual(ob["server_port"], 443)
        self.assertEqual(ob["flow"], "xtls-rprx-vision")
        self.assertEqual(ob["tls"]["server_name"], "last.fm")
        self.assertEqual(ob["tls"]["utls"]["fingerprint"], "qq")
        self.assertEqual(ob["tls"]["reality"]["short_id"], "8a54")
        self.assertNotIn("transport", ob)

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

    def test_tuic(self):
        ob = run_parser(
            "tuic://00000000-0000-0000-0000-000000000000:secret@example.com:443?sni=tuic.example.com&alpn=h3,hq-29"
        )
        self.assertEqual(ob["type"], "tuic")
        self.assertEqual(ob["tls"]["alpn"], ["h3", "hq-29"])

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


if __name__ == "__main__":
    unittest.main()
