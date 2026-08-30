#!/usr/bin/env python3

import base64
import json
import tempfile
import unittest
import zlib
from pathlib import Path

from amneziawg_config import (
    ConfigError,
    decode_vpn_link,
    extract_vpn_config,
    prepare,
    probe_address,
    render_settings,
    transport_implementation,
    validate_config,
    write_private,
)


BASE_CONFIG = """[Interface]
PrivateKey = private
Address = 10.8.0.2/32
DNS = $PRIMARY_DNS,$SECONDARY_DNS
Jc = 5
S3 = 12
S4 = 12
HeaderProtectionKey = header
ContentPaddingAddition = 8-16

[Peer]
PublicKey = public
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example.com:51820
"""


def vpn_data(*entries):
    return {
        "defaultContainer": entries[0][0],
        "dns1": "1.1.1.1",
        "dns2": "8.8.8.8",
        "containers": [
            {
                "container": container,
                key: {
                    "last_config": json.dumps(
                        {"config": config, "mtu": "1280", "port": 41111}
                    )
                },
            }
            for container, key, config in entries
        ],
    }


def encode_vpn(data, compressed=True):
    raw = json.dumps(data).encode()
    if compressed:
        raw = len(raw).to_bytes(4, "big") + zlib.compress(raw)
    encoded = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    return f"vpn://{encoded}"


class AmneziaWgConfigTests(unittest.TestCase):
    def test_qcompress_vpn_link(self):
        data = decode_vpn_link(encode_vpn(vpn_data(("amnezia-awg", "awg", BASE_CONFIG))))
        config = extract_vpn_config(data)
        self.assertIn("DNS = 1.1.1.1,8.8.8.8", config)
        self.assertIn("MTU = 1280", config)
        self.assertIn("ListenPort = 41111", config)
        self.assertIn("HeaderProtectionKey = header", config)

    def test_uncompressed_vpn_link(self):
        data = decode_vpn_link(
            encode_vpn(vpn_data(("amnezia-awg2", "amnezia-awg", BASE_CONFIG)), False)
        )
        self.assertIn("[Peer]", extract_vpn_config(data))

    def test_uncompressed_direct_conf_vpn_link(self):
        direct = BASE_CONFIG.replace("$PRIMARY_DNS,$SECONDARY_DNS", "1.1.1.1,8.8.8.8")
        link = "vpn://" + base64.urlsafe_b64encode(direct.encode()).decode()
        data = decode_vpn_link(link)
        config = extract_vpn_config(data)
        self.assertIn("[Interface]", config)
        self.assertIn("[Peer]", config)
        self.assertIn("MTU = 1280", config)

    def test_awg3_vpn_mtu_fallback_preserves_explicit_values(self):
        data = vpn_data(("amnezia-awg3", "awg", BASE_CONFIG))
        last = json.loads(data["containers"][0]["awg"]["last_config"])
        del last["mtu"]
        data["containers"][0]["awg"]["last_config"] = last
        self.assertIn("MTU = 1280", extract_vpn_config(data))

        explicit = BASE_CONFIG.replace("Address =", "MTU = 1312\nAddress =")
        data = vpn_data(("amnezia-awg3", "awg", explicit))
        last = json.loads(data["containers"][0]["awg"]["last_config"])
        del last["mtu"]
        data["containers"][0]["awg"]["last_config"] = last
        config = extract_vpn_config(data)
        self.assertIn("MTU = 1312", config)
        self.assertNotIn("MTU = 1280", config)

    def test_legacy_vpn_without_mtu_keeps_awg_quick_default(self):
        legacy = BASE_CONFIG.replace("HeaderProtectionKey = header\n", "").replace(
            "ContentPaddingAddition = 8-16\n", ""
        )
        data = vpn_data(("amnezia-awg", "awg", legacy))
        last = json.loads(data["containers"][0]["awg"]["last_config"])
        del last["mtu"]
        data["containers"][0]["awg"]["last_config"] = last
        self.assertNotIn("MTU =", extract_vpn_config(data))

    def test_legacy_direct_last_config_shape(self):
        data = vpn_data(("amnezia-awg", "awg", BASE_CONFIG))
        last_config = data["containers"][0]["awg"]["last_config"]
        data["containers"] = [
            {"container": "amnezia-awg", "last_config": last_config}
        ]
        self.assertIn("MTU = 1280", extract_vpn_config(data))

    def test_awg3_fields_are_restored_from_last_config(self):
        data = vpn_data(("amnezia-awg3", "awg", BASE_CONFIG))
        last = json.loads(data["containers"][0]["awg"]["last_config"])
        last.update(
            {
                "HeaderProtectionKey": "json-header",
                "content_padding_addition": "20-40",
                "RekeyAfterTime": "100-120",
                "MaxHandshakeAttempts": "15-20",
                "S4": 48,
            }
        )
        data["containers"][0]["awg"]["last_config"] = last
        config = extract_vpn_config(data)
        self.assertIn("HeaderProtectionKey = json-header", config)
        self.assertIn("ContentPaddingAddition = 20-40", config)
        self.assertIn("RekeyAfterTime = 100-120", config)
        self.assertIn("MaxHandshakeAttempts = 15-20", config)
        self.assertIn("S4 = 48", config)

    def test_awg3_boolean_fields_are_restored_from_last_config(self):
        data = vpn_data(("amnezia-awg3", "awg", BASE_CONFIG))
        last = json.loads(data["containers"][0]["awg"]["last_config"])
        last.update({"RandomTrailers": "on", "DisableCookies": True})
        data["containers"][0]["awg"]["last_config"] = last
        config = extract_vpn_config(data)
        self.assertIn("RandomTrailers = on", config)
        self.assertIn("DisableCookies = on", config)

    def test_explicit_container_resolves_ambiguity(self):
        data = vpn_data(
            ("amnezia-awg", "awg", BASE_CONFIG),
            ("amnezia-awg2", "awg", BASE_CONFIG.replace("10.8.0.2", "10.9.0.2")),
        )
        data["defaultContainer"] = "not-awg"
        with self.assertRaisesRegex(ConfigError, "multiple AmneziaWG"):
            extract_vpn_config(data)
        selected = extract_vpn_config(data, "amnezia-awg2")
        self.assertIn("10.9.0.2", selected)

    def test_default_protocol_key_resolves_ambiguity(self):
        data = vpn_data(
            ("client-a", "awg", BASE_CONFIG),
            ("client-b", "amnezia-awg2", BASE_CONFIG.replace("10.8.0.2", "10.9.0.2")),
        )
        data["defaultContainer"] = "awg"
        self.assertIn("10.8.0.2", extract_vpn_config(data))

    def test_api_backed_short_key_is_rejected(self):
        with self.assertRaisesRegex(ConfigError, "API-backed"):
            decode_vpn_link("vpn://short-key")

    def test_qcompress_length_is_checked(self):
        raw = json.dumps(vpn_data(("amnezia-awg", "awg", BASE_CONFIG))).encode()
        payload = (len(raw) + 1).to_bytes(4, "big") + zlib.compress(raw)
        link = "vpn://" + base64.urlsafe_b64encode(payload).decode().rstrip("=")
        with self.assertRaisesRegex(ConfigError, "length header"):
            decode_vpn_link(link)

    def test_decompression_limit_is_enforced(self):
        raw = b"{" + b" " * (8 * 1024 * 1024) + b"}"
        payload = len(raw).to_bytes(4, "big") + zlib.compress(raw)
        link = "vpn://" + base64.urlsafe_b64encode(payload).decode().rstrip("=")
        with self.assertRaisesRegex(ConfigError, "exceeds"):
            decode_vpn_link(link)

    def test_missing_and_malformed_candidates_fail_cleanly(self):
        with self.assertRaisesRegex(ConfigError, "no containers"):
            extract_vpn_config({})
        with self.assertRaisesRegex(ConfigError, "no AmneziaWG"):
            extract_vpn_config({"containers": [{"container": "xray"}]})
        unresolved = vpn_data(("amnezia-awg", "awg", BASE_CONFIG))
        del unresolved["dns2"]
        with self.assertRaisesRegex(ConfigError, "unresolved DNS"):
            extract_vpn_config(unresolved)

    def test_hooks_rejected_by_default_and_allowed_explicitly(self):
        hooked = BASE_CONFIG.replace("Address =", "PostUp = touch /root/pwned\nAddress =")
        with self.assertRaisesRegex(ConfigError, "privileged"):
            validate_config(hooked)
        validate_config(hooked, allow_hooks=True)

    def test_declarative_awg3_and_secret_files(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            private_key = directory / "private"
            psk = directory / "psk"
            header = directory / "header"
            private_key.write_text("private-file\n")
            psk.write_text("psk-file\n")
            header.write_text("header-file\n")
            config = render_settings(
                {
                    "addresses": ["10.8.0.2/32"],
                    "dns": ["1.1.1.1"],
                    "privateKeyFile": str(private_key),
                    "obfuscation": {
                        "s1": 12,
                        "s2": 12,
                        "s3": 12,
                        "s4": 12,
                        "h1": "100-200",
                        "i1": "<b 0x0102><r 4>",
                        "headerProtectionKeyFile": str(header),
                        "rekeyAfterTime": "120-180",
                        "maxHandshakeAttempts": 10,
                        "randomTrailers": True,
                        "disableCookies": True,
                    },
                    "peers": [
                        {
                            "publicKey": "public",
                            "presharedKeyFile": str(psk),
                            "allowedIPs": ["0.0.0.0/0", "::/0"],
                            "endpoint": "vpn.example.com:51820",
                            "persistentKeepalive": "20-30",
                            "advancedSecurity": True,
                        }
                    ],
                }
            )
            self.assertIn("PrivateKey = private-file", config)
            self.assertIn("HeaderProtectionKey = header-file", config)
            self.assertIn("RekeyAfterTime = 120-180", config)
            self.assertIn("RandomTrailers = on", config)
            self.assertIn("DisableCookies = on", config)
            self.assertIn("AdvancedSecurity = on", config)

            prepared = prepare({"kind": "settings", "settings": {
                "addresses": ["10.8.0.2/32"],
                "privateKeyFile": str(private_key),
                "obfuscation": {"headerProtectionKeyFile": str(header)},
                "peers": [{"publicKey": "public", "allowedIPs": ["0.0.0.0/0"]}],
            }})
            self.assertIn("MTU = 1280", prepared)

    def test_prepare_config_file_and_private_output(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            source = directory / "source.conf"
            output = directory / "runtime" / "awg.conf"
            source.write_text(BASE_CONFIG.replace("$PRIMARY_DNS,$SECONDARY_DNS", "1.1.1.1"))
            config = prepare({"kind": "configFile", "path": str(source)})
            self.assertIn("MTU = 1280", config)
            write_private(str(output), config)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_probe_address_prefers_public_address_covered_by_default_route(self):
        config = BASE_CONFIG.replace("$PRIMARY_DNS,$SECONDARY_DNS", "1.1.1.1")
        self.assertEqual(probe_address(config), "1.1.1.1")

    def test_probe_address_uses_host_inside_narrow_route(self):
        config = BASE_CONFIG.replace(
            "AllowedIPs = 0.0.0.0/0", "AllowedIPs = 10.23.42.0/24"
        )
        self.assertEqual(probe_address(config), "10.23.42.1")

    def test_random_trailers_with_ranged_handshake_headers_forces_userspace(self):
        config = BASE_CONFIG.replace(
            "ContentPaddingAddition = 8-16",
            "ContentPaddingAddition = 8-16\nH1 = 213818264-462596257\nRandomTrailers = on",
        )
        self.assertEqual(transport_implementation(config), "userspace")
        self.assertEqual(
            transport_implementation(config.replace("RandomTrailers = on", "RandomTrailers = off")),
            "auto",
        )


if __name__ == "__main__":
    unittest.main()
