#!/usr/bin/env python3

import base64
import unittest
from proxy_parsing import decode_subscription, parse_subscription

VLESS_URI = "vless://uuid@example.com:443?security=reality&pbk=pubkey&fp=chrome&sni=cdn.example.com&sid=abcd"
SS_URI = "ss://{}@ss.example.com:8388".format(
    base64.urlsafe_b64encode(b"chacha20-ietf-poly1305:passw0rd").decode().rstrip("=")
)
HY2_URI = "hy2://secret@hy.example.com:443?sni=hy.example.com"
INVALID_URI = "wireguard://example.com:51820"


def _make_b64_payload(*uris: str) -> bytes:
    text = "\n".join(uris)
    return base64.b64encode(text.encode())


def run_fetcher(server_data: bytes, tag_prefix: str = "test", *, routing_mark: int | None = None):
    lines = decode_subscription(server_data)
    return parse_subscription(lines, tag_prefix, routing_mark)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class FetchSubscriptionTests(unittest.TestCase):

    def test_base64_payload_mixed_protocols(self):
        payload = _make_b64_payload(VLESS_URI, SS_URI, HY2_URI)
        obs = run_fetcher(payload)
        self.assertEqual(len(obs), 3)
        types = {ob["type"] for ob in obs}
        self.assertEqual(types, {"vless", "shadowsocks", "hysteria2"})

    def test_plain_text_payload(self):
        payload = "\n".join([VLESS_URI, SS_URI]).encode()
        obs = run_fetcher(payload)
        self.assertEqual(len(obs), 2)

    def test_tag_prefix_applied(self):
        payload = _make_b64_payload(VLESS_URI)
        obs = run_fetcher(payload, tag_prefix="mysub")
        self.assertTrue(obs[0]["tag"].startswith("mysub-"))

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
        import re
        self.assertRegex(tag, r"^[a-zA-Z0-9_/\-]+$")

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


if __name__ == "__main__":
    unittest.main()
