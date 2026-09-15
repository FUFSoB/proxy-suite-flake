#!/usr/bin/env python3
"""proxy_export: host-only parts leave, the routing stays, and sing-box accepts the result."""

import json
import os
import subprocess
import tempfile
import unittest

import proxy_export as export

GEOSITE = "/nix/store/x-sing-geosite/share/sing-box/rule-set/geosite-google.srs"


def sing_box_config():
    """The socks unit's config on hybrid sing-box, with autoProxy, the test listener and local auth."""
    return {
        "log": {"level": "warn"},
        "dns": {
            "servers": [
                {"tag": "remote", "type": "tls", "server": "1.1.1.1", "server_port": 853, "detour": "proxy"},
                {"tag": "local", "type": "udp", "server": "77.88.8.8", "server_port": 53},
            ],
            "rules": [{"rule_set": ["geosite-google"], "server": "remote"}],
            "final": "remote",
        },
        "inbounds": [
            {"type": "direct", "tag": "xray-dns-in", "listen": "127.0.0.1", "listen_port": 5353},
            {"type": "mixed", "tag": "mixed-in", "listen": "0.0.0.0", "listen_port": 1080, "users": [{"username": "u", "password": "p"}]},
            {"type": "tproxy", "tag": "tproxy-in", "listen": "127.0.0.1", "listen_port": 7894},
            {"type": "mixed", "tag": "probe-in-1", "listen": "127.0.0.1", "listen_port": 20001},
        ],
        "outbounds": [
            {"type": "vless", "tag": "vps", "server": "vps.example.com", "server_port": 443, "uuid": "a4a0b7a8-7b35-4bb4-9a9b-2b7b33e9b7a1", "routing_mark": 1},
            {"type": "trojan", "tag": "sub-de", "server": "de.example.com", "server_port": 443, "password": "x", "routing_mark": 1},
            {"type": "socks", "tag": "xhttp-vps", "server": "127.0.0.1", "server_port": 30001},
            {"type": "socks", "tag": "warp", "server": "127.0.0.1", "server_port": 40000},
            {"type": "urltest", "tag": "proxy", "outbounds": ["vps", "sub-de", "xhttp-vps", "warp"]},
            {"type": "selector", "tag": "proxy-suite-test", "outbounds": ["vps", "sub-de"]},
            {"type": "direct", "tag": "direct", "routing_mark": 1},
            {"type": "block", "tag": "block"},
        ],
        "route": {
            "default_domain_resolver": "local",
            "rule_set": [
                {"type": "local", "tag": "geosite-google", "format": "binary", "path": GEOSITE},
                {"type": "local", "tag": "autoproxy-1", "format": "source", "path": "/var/lib/proxy-suite/autoproxy/rs-1.json"},
            ],
            "rules": [
                {"inbound": ["probe-in-1"], "outbound": "sub-de"},
                {"inbound": ["xray-dns-in"], "network": ["tcp", "udp"], "action": "hijack-dns"},
                {"domain_suffix": ["x.test"], "outbound": "xhttp-vps"},
                {"rule_set": ["geosite-google"], "outbound": "proxy"},
                {"rule_set": ["autoproxy-1"], "outbound": "sub-de"},
                {"inbound": ["mixed-in"], "ip_is_private": True, "action": "reject"},
            ],
            "final": "direct",
        },
        "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}},
    }


def xray_config():
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {"tag": "mixed-in", "protocol": "socks", "listen": "0.0.0.0", "port": 1080, "settings": {"auth": "password", "accounts": [{"user": "u", "pass": "p"}]}},
            {"tag": "tproxy-in", "protocol": "tunnel", "listen": "127.0.0.1", "port": 7894},
        ],
        "outbounds": [
            {"protocol": "vless", "tag": "proxy-suite-ob-vps", "settings": {"vnext": [{"address": "vps.example.com", "port": 443}]}, "streamSettings": {"sockopt": {"mark": 1}}},
            {"protocol": "vless", "tag": "proxy-suite-ob-de", "settings": {"vnext": [{"address": "de.example.com", "port": 443}]}},
            {"protocol": "socks", "tag": "proxy-suite-ob-warp", "settings": {"address": "127.0.0.1", "port": 40000}},
            {"protocol": "freedom", "tag": "direct", "streamSettings": {"sockopt": {"mark": 1}}},
            {"protocol": "blackhole", "tag": "block"},
        ],
        "routing": {
            "rules": [
                {"type": "field", "inboundTag": ["tproxy-in"], "outboundTag": "direct"},
                {"type": "field", "domain": ["geosite:google"], "outboundTag": "proxy-suite-ob-warp"},
                {"type": "field", "network": "tcp,udp", "balancerTag": "proxy"},
            ],
            "balancers": [{"tag": "proxy", "selector": ["proxy-suite-ob-"], "strategy": {"type": "leastPing"}}],
        },
    }


class SingBoxTest(unittest.TestCase):
    def test_host_parts_leave(self):
        cfg, warnings = export.portable(sing_box_config())
        self.assertEqual(cfg["inbounds"], [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 1080}])
        tags = [o["tag"] for o in cfg["outbounds"]]
        self.assertEqual(tags, ["vps", "sub-de", "proxy", "direct", "block"])
        self.assertEqual(cfg["outbounds"][2]["outbounds"], ["vps", "sub-de"])
        self.assertFalse(any("routing_mark" in o for o in cfg["outbounds"]))
        self.assertEqual(sorted(warnings), ["left out warp: this host reaches it through a local hop", "left out xhttp-vps: this host reaches it through a local hop"])
        self.assertNotIn("experimental", cfg)
        self.assertTrue(cfg["route"]["auto_detect_interface"])

    def test_routing_stays(self):
        route = export.portable(sing_box_config())[0]["route"]
        self.assertEqual(
            route["rules"],
            [
                {"domain_suffix": ["x.test"], "outbound": "proxy"},
                {"rule_set": ["geosite-google"], "outbound": "proxy"},
                {"inbound": ["mixed-in"], "ip_is_private": True, "action": "reject"},
            ],
        )
        self.assertEqual(
            route["rule_set"],
            [{"type": "remote", "tag": "geosite-google", "format": "binary", "download_detour": "proxy",
              "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs"}],
        )

    def test_one_server(self):
        cfg, _ = export.portable(sing_box_config(), only="sub-de")
        self.assertEqual([o["tag"] for o in cfg["outbounds"]], ["sub-de", "proxy", "direct", "block"])
        self.assertEqual(cfg["outbounds"][1]["outbounds"], ["sub-de"])
        with self.assertRaises(ValueError):
            export.portable(sing_box_config(), only="nope")

    def test_chains(self):
        base = sing_box_config()
        base["outbounds"][1]["detour"] = "vps"
        base["outbounds"].insert(4, {"type": "trojan", "tag": "via-warp", "server": "nl.example.com", "server_port": 443, "password": "x", "detour": "warp"})
        base["outbounds"][5]["outbounds"].append("via-warp")
        # One server takes its hop along, but not into the group.
        cfg, _ = export.portable(base, only="sub-de")
        self.assertEqual([o["tag"] for o in cfg["outbounds"]], ["vps", "sub-de", "proxy", "direct", "block"])
        self.assertEqual(cfg["outbounds"][2]["outbounds"], ["sub-de"])
        # Chained through a hop that stays behind: stays behind too.
        cfg, warnings = export.portable(base)
        self.assertNotIn("via-warp", [o["tag"] for o in cfg["outbounds"]])
        self.assertIn("left out via-warp: it chains through warp", warnings)

    def test_collapsed_proxy(self):
        base = sing_box_config()
        base["outbounds"] = [{**base["outbounds"][0], "tag": "proxy"}, base["outbounds"][1], *base["outbounds"][6:]]
        base["route"]["rules"] = []
        cfg, _ = export.portable(base, only="vps")
        self.assertEqual([o["tag"] for o in cfg["outbounds"]], ["proxy", "direct", "block"])

    def test_nothing_portable(self):
        base = sing_box_config()
        base["outbounds"] = base["outbounds"][2:4] + base["outbounds"][6:]
        with self.assertRaises(ValueError):
            export.portable(base)

    @unittest.skipUnless(os.environ.get("SING_BOX"), "SING_BOX not set")
    def test_sing_box_accepts_it(self):
        cfg, _ = export.portable(sing_box_config())
        # Remote rule-sets are fetched at start, not by check.
        with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            json.dump(cfg, f)
            f.flush()
            result = subprocess.run([os.environ["SING_BOX"], "check", "-c", f.name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


class XrayTest(unittest.TestCase):
    def test_host_parts_leave(self):
        cfg, warnings = export.portable(xray_config())
        self.assertEqual([i["tag"] for i in cfg["inbounds"]], ["mixed-in", "http-in"])
        self.assertEqual(cfg["inbounds"][0]["settings"], {"auth": "noauth", "udp": True})
        self.assertEqual([o["tag"] for o in cfg["outbounds"]], ["proxy-suite-ob-vps", "proxy-suite-ob-de", "direct", "block"])
        self.assertEqual(cfg["outbounds"][0]["streamSettings"]["sockopt"], {})
        self.assertEqual(warnings, ["left out proxy-suite-ob-warp: this host reaches it through a local hop"])
        self.assertEqual(
            cfg["routing"]["rules"],
            [
                {"type": "field", "domain": ["geosite:google"], "balancerTag": "proxy"},
                {"type": "field", "network": "tcp,udp", "balancerTag": "proxy"},
            ],
        )

    def test_one_server(self):
        cfg, _ = export.portable(xray_config(), only="de")
        self.assertEqual([o["tag"] for o in cfg["outbounds"]], ["proxy-suite-ob-de", "direct", "block"])

    def test_chains(self):
        base = xray_config()
        base["outbounds"][1]["streamSettings"] = {"sockopt": {"dialerProxy": "proxy-suite-ob-vps"}}
        cfg, _ = export.portable(base, only="de")
        self.assertEqual([o["tag"] for o in cfg["outbounds"]], ["proxy-suite-ob-vps", "proxy-suite-ob-de", "direct", "block"])
        self.assertEqual(cfg["routing"]["balancers"][0]["selector"], ["proxy-suite-ob-de"])


if __name__ == "__main__":
    unittest.main()
