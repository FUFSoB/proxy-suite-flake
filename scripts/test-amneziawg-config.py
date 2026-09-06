#!/usr/bin/env python3

import base64
import json
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest.mock import patch

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
    def secret_settings(self, path, **public):
        return {
            "addresses": ["10.8.0.2/32"],
            "privateKey": "private",
            "obfuscation": public,
            "obfuscationFile": str(path),
            "peers": [{"publicKey": "public", "allowedIPs": ["0.0.0.0/0"]}],
        }

    def test_partial_obfuscation_all_fields(self):
        secret = {
            "jc": 0, "jmin": 10, "jmax": 20,
            "s1": 60, "s2": 90, "s3": 12, "s4": 16,
            "h1": "100-200", "h2": 300, "h3": "400", "h4": "(off)",
            "i1": "<b 0x1234>", "i2": "second", "i3": "third",
            "i4": "fourth", "i5": "fifth", "headerProtectionKey": "header-secret",
            "contentPaddingAddition": "8-16", "rekeyAfterTime": 120,
            "rekeyTimeout": "5", "rejectAfterTime": "(off)",
            "keepaliveTimeout": "10-20", "maxHandshakeAttempts": 10,
            "randomTrailers": True, "disableCookies": False,
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret.json"
            path.write_text(json.dumps(secret))
            settings = self.secret_settings(path)
            config = prepare({"kind": "settings", "settings": settings})
            for key, value in secret.items():
                rendered = ("on" if value else "off") if type(value) is bool else str(value)
                self.assertIn(f"{key[0].upper() + key[1:]} = {rendered}\n", config)
            self.assertIn("MTU = 1280", config)
            self.assertEqual(transport_implementation(config), "userspace")
            settings["mtu"] = 1312
            self.assertIn("MTU = 1312", prepare({"kind": "settings", "settings": settings}))
            self.assertEqual(settings["obfuscation"], {})

    def test_partial_obfuscation_merge_and_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret.json"
            settings = self.secret_settings(path, s1=60, s2=90, i1=None)
            for secret in ({}, {"i1": None, "s1": None}, {"i1": "first"}, {"i1": "rotated"}):
                with self.subTest(secret=secret):
                    path.write_text(json.dumps(secret))
                    config = render_settings(settings)
                    self.assertIn("S1 = 60", config)
                    self.assertIn("S2 = 90", config)
                    if secret.get("i1"):
                        self.assertIn(f"I1 = {secret['i1']}\n", config)
                    else:
                        self.assertNotIn("I1 =", config)
            self.assertIsNone(settings["obfuscation"]["i1"])

    def test_partial_obfuscation_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret.json"
            for secret, public in [
                ({"i1": "same"}, {"i1": "same"}),
                ({"jc": 0}, {"jc": 0}),
                ({"randomTrailers": False}, {"randomTrailers": False}),
                ({"headerProtectionKey": "secret"}, {"headerProtectionKey": "inline"}),
                ({"headerProtectionKey": "secret"}, {"headerProtectionKeyFile": "/missing"}),
            ]:
                with self.subTest(public=public):
                    path.write_text(json.dumps(secret))
                    with self.assertRaisesRegex(ConfigError, "multiple sources"):
                        render_settings(self.secret_settings(path, **public))

    def test_partial_obfuscation_rejects_invalid_values(self):
        invalid = {
            "jc": [-1, True, "5", 1.5, [], {}],
            "h1": [-1, False, "1 - 2", "off", "1-2-3", "1\n", 1.5],
            "randomTrailers": [0, 1, "on", "false", [], {}],
            "i1": ["", " ", 42, True, [], {}, "secret\nPostUp = command",
                   "secret\rPostUp = command", "secret\u2028PostUp = command",
                   "secret\n", "secret\x00"],
            "headerProtectionKey": ["", 42, "secret\nPostUp = command"],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret.json"
            for key, values in invalid.items():
                for value in values:
                    with self.subTest(key=key, value=value):
                        path.write_text(json.dumps({key: value}))
                        with self.assertRaisesRegex(ConfigError, "invalid value"):
                            render_settings(self.secret_settings(path))

    def test_partial_obfuscation_safe_cli_failures_preserve_output(self):
        inputs = [
            b'{"i1": "SECRET",}', b'{"i1": "SECRET", "i1": null}',
            b'{"SECRET": null}', b'{"headerProtectionKeyFile": "SECRET"}',
            b'{"privateKey": "SECRET"}', b'{"peers": []}', b'{"mtu": 1280}',
            b'{"i1": "SECRET\\nPostUp = command"}', b'{"jc": NaN}',
            b'{"i1": "SECRET\\ud800"}',
            b'{"jc": Infinity}', b'{"i1": "SECRET\xff"}',
            b'[]', b'null', b'"SECRET"', b'',
            b'[' * 2000 + b'"SECRET"' + b']' * 2000,
        ]
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            path = directory / "secret.json"
            output = directory / "runtime" / "awg.conf"
            manifest = directory / "manifest.json"
            manifest.write_text(json.dumps({"kind": "settings", "settings": self.secret_settings(path)}))
            write_private(str(output), "previous config")
            for data in inputs + [None]:
                with self.subTest(data=data[:60] if data else data):
                    if data is None:
                        path.unlink()
                    else:
                        path.write_bytes(data)
                    result = subprocess.run(
                        [sys.executable, str(Path(__file__).with_name("amneziawg_config.py")),
                         "--manifest", str(manifest), "--output", str(output)],
                        capture_output=True, text=True,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("SECRET", result.stderr + result.stdout)
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertEqual(output.read_text(), "previous config")
                    self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(output.parent.stat().st_mode & 0o777, 0o700)
                    self.assertEqual(list(output.parent.iterdir()), [output])

    def test_partial_obfuscation_unreadable_and_oversized(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret.json"
            path.write_text('{"i1": "SECRET"}')
            with patch("amneziawg_config.MAX_INPUT_BYTES", 4):
                with self.assertRaisesRegex(ConfigError, "exceeds"):
                    render_settings(self.secret_settings(path))
            with patch("amneziawg_config._read_limited", side_effect=PermissionError("SECRET")):
                with self.assertRaisesRegex(ConfigError, "^cannot read or decode obfuscationFile$"):
                    render_settings(self.secret_settings(path))

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
