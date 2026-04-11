#!/usr/bin/env python3

import base64
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(os.environ.get("BUILD_OUTBOUND_SCRIPT", Path(__file__).with_name("build-outbound.py")))


def run_parser(url: str, *, expect_ok: bool = True):
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--tag", "test-outbound"],
        input=url,
        text=True,
        capture_output=True,
        check=False,
        env=env,
    )
    if expect_ok:
        if proc.returncode != 0:
            raise AssertionError(proc.stderr)
        return json.loads(proc.stdout)
    return proc


class BuildOutboundTests(unittest.TestCase):
    def test_vless_reality(self):
        ob = run_parser(
            "vless://uuid@example.com:443?security=reality&pbk=pubkey&fp=chrome&sni=cdn.example.com&sid=abcd"
        )
        self.assertEqual(ob["type"], "vless")
        self.assertEqual(ob["server"], "example.com")
        self.assertEqual(ob["tls"]["reality"]["public_key"], "pubkey")

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

    def test_trojan(self):
        ob = run_parser("trojan://secret@example.com:443?sni=tls.example.com&fp=chrome")
        self.assertEqual(ob["type"], "trojan")
        self.assertEqual(ob["password"], "secret")
        self.assertEqual(ob["tls"]["server_name"], "tls.example.com")

    def test_shadowsocks(self):
        credentials = base64.urlsafe_b64encode(b"chacha20-ietf-poly1305:passw0rd").decode().rstrip("=")
        ob = run_parser(f"ss://{credentials}@ss.example.com:8388")
        self.assertEqual(ob["type"], "shadowsocks")
        self.assertEqual(ob["method"], "chacha20-ietf-poly1305")

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

    def test_https_proxy(self):
        ob = run_parser("https://proxy.example.com:8443")
        self.assertEqual(ob["type"], "http")
        self.assertEqual(ob["tls"]["server_name"], "proxy.example.com")

    def test_invalid_scheme_fails(self):
        proc = run_parser("wireguard://example.com", expect_ok=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("unsupported scheme", proc.stderr)


if __name__ == "__main__":
    unittest.main()
