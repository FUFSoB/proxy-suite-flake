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
                {"type": "field", "inboundTag": ["local"], "outboundTag": "direct"},
                {"type": "field", "domain": ["geosite:google"], "outboundTag": "proxy-suite-ob-warp"},
                {"type": "field", "network": "tcp,udp", "balancerTag": "proxy"},
            ],
            "balancers": [{"tag": "proxy", "selector": ["proxy-suite-ob-"], "strategy": {"type": "leastPing"}}],
        },
    }


def dangling(cfg):
    """Outbound tags the config names without having them, a default outside its group
    included: sing-box stops on those as it starts (which `check` does not catch)."""
    tags = {o["tag"] for o in cfg["outbounds"]}
    named = {r["outbound"] for r in cfg["route"]["rules"] if "outbound" in r} | {cfg["route"].get("final", "direct")}
    named |= {s["detour"] for s in cfg.get("dns", {}).get("servers", []) if "detour" in s}
    named |= {rs["download_detour"] for rs in cfg["route"].get("rule_set", []) if "download_detour" in rs}
    for o in cfg["outbounds"]:
        named |= set(o.get("outbounds") or []) | ({o["detour"]} if "detour" in o else set())
        if "default" in o and o["default"] not in o["outbounds"]:
            named.add(f"default {o['default']} of {o['tag']}")
    return named - tags


def groups(cfg):
    return {o["tag"]: o for o in cfg["outbounds"] if o["type"] in export.GROUPS}


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

    def test_one_server_behind_a_first_selector(self):
        """selection = "first": "proxy" is a selector of the one picked. Another server, exported,
        is what "proxy" holds then: rules and DNS go through it, and must not go direct."""
        base = sing_box_config()
        base["outbounds"][4] = {"type": "selector", "tag": "proxy", "outbounds": ["vps"], "default": "vps"}
        cfg, _ = export.portable(base, only="sub-de")
        self.assertEqual(groups(cfg)["proxy"], {"type": "selector", "tag": "proxy", "outbounds": ["sub-de"]})
        self.assertEqual(cfg["dns"]["servers"][0]["detour"], "proxy")
        self.assertEqual(dangling(cfg), set())
        # Its one exit a loopback hop: the first one left, not direct.
        base["outbounds"][4] = {"type": "selector", "tag": "proxy", "outbounds": ["warp"], "default": "warp"}
        cfg, _ = export.portable(base)
        self.assertEqual(groups(cfg)["proxy"]["outbounds"], ["vps"])
        self.assertEqual(dangling(cfg), set())

    def test_nested_groups(self):
        base = sing_box_config()
        base["outbounds"][4:5] = [
            {"type": "selector", "tag": "proxy", "outbounds": ["grp"], "default": "grp"},
            {"type": "urltest", "tag": "grp", "outbounds": ["vps", "sub-de"]},
            {"type": "selector", "tag": "other", "outbounds": ["vps", "warp"], "default": "vps"},
        ]
        cfg, _ = export.portable(base, only="sub-de")
        found = groups(cfg)
        self.assertEqual(found["grp"]["outbounds"], ["sub-de"])
        self.assertEqual(found["proxy"]["outbounds"], ["sub-de"])
        self.assertEqual(found["other"]["outbounds"], ["proxy"])
        self.assertEqual(dangling(cfg), set())
        # A group of loopback hops only, inside "proxy": through "proxy" would be a loop.
        base["outbounds"][4:7] = [
            {"type": "selector", "tag": "proxy", "outbounds": ["vps", "grp"], "default": "grp"},
            {"type": "urltest", "tag": "grp", "outbounds": ["warp", "xhttp-vps"]},
            {"type": "urltest", "tag": "other", "outbounds": ["warp"]},
        ]
        cfg, _ = export.portable(base)
        found = groups(cfg)
        self.assertEqual(found["proxy"], {"type": "selector", "tag": "proxy", "outbounds": ["vps", "grp"], "default": "grp"})
        self.assertEqual(found["grp"]["outbounds"], ["vps"])
        self.assertEqual(found["other"]["outbounds"], ["proxy"])
        self.assertEqual(dangling(cfg), set())

    def test_default_left_out_of_its_group(self):
        """The one server takes its hop along, out of the groups: a group's default can be that hop."""
        base = sing_box_config()
        base["outbounds"][1]["detour"] = "vps"
        base["outbounds"][4] = {"type": "selector", "tag": "proxy", "outbounds": ["vps", "sub-de"], "default": "vps"}
        # perAppRouting's pin slots: block by default.
        base["outbounds"].append({"type": "selector", "tag": "proxy-suite-pin-tproxy-0", "outbounds": ["block", "direct", "proxy", "vps", "sub-de"], "default": "block"})
        cfg, _ = export.portable(base, only="sub-de")
        self.assertIn("vps", [o["tag"] for o in cfg["outbounds"]])
        self.assertEqual(groups(cfg)["proxy"], {"type": "selector", "tag": "proxy", "outbounds": ["sub-de"]})
        self.assertNotIn("default", groups(cfg)["proxy-suite-pin-tproxy-0"])
        self.assertEqual(dangling(cfg), set())

    def test_logical_rules(self):
        """A rule-set left behind can sit inside a logical rule; sing-box stops on it as it starts."""
        base = sing_box_config()
        guard = {"type": "logical", "mode": "and", "action": "reject",
                 "rules": [{"inbound": ["mixed-in"]}, {"source_ip_cidr": ["127.0.0.0/8"], "invert": True}]}
        base["route"]["rules"] += [
            {"type": "logical", "mode": "or", "rules": [{"rule_set": ["autoproxy-1"]}, {"domain": ["a.test"]}], "outbound": "sub-de"},
            {"type": "logical", "mode": "and", "outbound": "vps",
             "rules": [{"type": "logical", "mode": "or", "rules": [{"inbound": "tproxy-in"}]}, {"domain": ["b.test"]}]},
            guard,
        ]
        base["dns"]["rules"].append({"type": "logical", "mode": "or", "rules": [{"rule_set": "autoproxy-1"}, {"domain": ["c.test"]}], "server": "local"})
        cfg, _ = export.portable(base)
        self.assertEqual(cfg["route"]["rules"][-2:], [{"inbound": ["mixed-in"], "ip_is_private": True, "action": "reject"}, guard])
        self.assertEqual(cfg["dns"]["rules"], [{"rule_set": ["geosite-google"], "server": "remote"}])

    def test_interface_outbound_stays(self):
        """An AmneziaWG "interface" outbound is direct bound to an interface only this host has:
        elsewhere it would be plain direct, inside "proxy"."""
        base = sing_box_config()
        base["outbounds"][4]["outbounds"].append("awg-home")
        base["outbounds"][4:4] = [
            {"type": "direct", "tag": "awg-home", "bind_interface": "awg-home", "domain_resolver": "awg-dns-awg-home", "routing_mark": 1},
            {"type": "trojan", "tag": "via-awg", "server": "nl.example.com", "server_port": 443, "password": "x", "detour": "awg-home"},
        ]
        base["route"]["rules"].append({"domain": ["h.test"], "outbound": "awg-home"})
        base["dns"]["servers"].append({"tag": "awg-dns-awg-home", "type": "udp", "server": "1.1.1.1", "server_port": 53, "bind_interface": "awg-home", "routing_mark": 1})
        cfg, warnings = export.portable(base)
        self.assertEqual([o["tag"] for o in cfg["outbounds"]], ["vps", "sub-de", "proxy", "direct", "block"])
        self.assertEqual(groups(cfg)["proxy"]["outbounds"], ["vps", "sub-de"])
        self.assertEqual(cfg["outbounds"][3], {"type": "direct", "tag": "direct"})
        self.assertIn("left out awg-home: it goes out through an interface of this host", warnings)
        self.assertIn("left out via-awg: it chains through awg-home", warnings)
        self.assertEqual(cfg["route"]["rules"][-1], {"domain": ["h.test"], "outbound": "proxy"})
        self.assertEqual([s["tag"] for s in cfg["dns"]["servers"]], ["remote", "local"])
        self.assertEqual(dangling(cfg), set())
        # Nothing left to export says why.
        with self.assertRaises(export.NothingPortable) as raised:
            export.portable(base, only="awg-home")
        self.assertEqual(raised.exception.warnings, ["left out awg-home: it goes out through an interface of this host"])

    def test_left_behind_downloads_and_marks(self):
        """A remote rule-set downloads through an outbound, which can be one left behind; a DNS
        server's own mark goes, as an outbound's does."""
        base = sing_box_config()
        base["route"]["rule_set"].append({"type": "remote", "tag": "ads", "format": "binary", "url": "https://rs.test/ads.srs", "download_detour": "warp"})
        base["route"]["rule_set"].append({"type": "remote", "tag": "cn", "format": "binary", "url": "https://rs.test/cn.srs", "download_detour": "vps"})
        base["dns"]["servers"][1]["routing_mark"] = 1
        cfg, _ = export.portable(base)
        self.assertEqual([rs.get("download_detour") for rs in cfg["route"]["rule_set"]], ["proxy", "proxy", "vps"])
        self.assertEqual(cfg["dns"]["servers"][1], {"tag": "local", "type": "udp", "server": "77.88.8.8", "server_port": 53})
        self.assertEqual(dangling(cfg), set())

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

    def test_kept_loopback_hop_leaves_no_dangling_reference(self):
        """Asking for a loopback hop drops it, so nothing may still point at it:
        sing-box stops with "default outbound not found" (which `check` does not catch)."""
        base = sing_box_config()
        # No group named "proxy", so the export has to choose the target itself.
        base["outbounds"] = [
            {"type": "socks", "tag": "warp", "server": "127.0.0.1", "server_port": 40000, "detour": "vps"},
            base["outbounds"][0],
            *base["outbounds"][6:],
        ]
        base["route"] = {"rules": [{"domain": ["a.test"], "outbound": "warp"}], "final": "warp"}
        cfg, warnings = export.portable(base, only="warp")
        tags = {o["tag"] for o in cfg["outbounds"]}
        self.assertNotIn("warp", tags)
        referenced = {r["outbound"] for r in cfg["route"]["rules"]} | {cfg["route"]["final"]}
        for o in cfg["outbounds"]:
            referenced |= set(o.get("outbounds") or [])
        self.assertEqual(referenced - tags, set(), warnings)

    def test_nothing_portable(self):
        base = sing_box_config()
        base["outbounds"] = base["outbounds"][2:4] + base["outbounds"][6:]
        with self.assertRaises(ValueError):
            export.portable(base)

    @unittest.skipUnless(os.environ.get("SING_BOX"), "SING_BOX not set")
    def test_sing_box_accepts_it(self):
        first = sing_box_config()
        first["outbounds"][4] = {"type": "selector", "tag": "proxy", "outbounds": ["vps"], "default": "vps"}
        logical = sing_box_config()
        logical["route"]["rules"].append({"type": "logical", "mode": "or", "rules": [{"rule_set": ["autoproxy-1"]}], "outbound": "sub-de"})
        awg = sing_box_config()
        awg["outbounds"].insert(0, {"type": "direct", "tag": "awg-home", "bind_interface": "awg-home", "domain_resolver": "awg-dns-awg-home"})
        awg["dns"]["servers"].append({"tag": "awg-dns-awg-home", "type": "udp", "server": "1.1.1.1", "bind_interface": "awg-home"})
        for base, only in ((sing_box_config(), None), (first, "sub-de"), (logical, None), (awg, None)):
            cfg, _ = export.portable(base, only)
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
                {"type": "field", "inboundTag": ["local"], "outboundTag": "direct"},
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

    def test_interface_outbound_stays(self):
        """The XRay side of an AmneziaWG "interface" outbound: freedom bound to the interface."""
        base = xray_config()
        base["outbounds"].insert(3, {"protocol": "freedom", "tag": "proxy-suite-ob-awg", "streamSettings": {"sockopt": {"interface": "awg-awg", "mark": 1}}})
        base["routing"]["rules"].insert(2, {"type": "field", "domain": ["h.test"], "outboundTag": "proxy-suite-ob-awg"})
        cfg, warnings = export.portable(base)
        self.assertEqual([o["tag"] for o in cfg["outbounds"]], ["proxy-suite-ob-vps", "proxy-suite-ob-de", "direct", "block"])
        self.assertIn("left out proxy-suite-ob-awg: it goes out through an interface of this host", warnings)
        self.assertEqual(cfg["routing"]["rules"][1], {"type": "field", "domain": ["h.test"], "balancerTag": "proxy"})
        self.assertEqual(cfg["outbounds"][2], {"protocol": "freedom", "tag": "direct", "streamSettings": {"sockopt": {}}})
        with self.assertRaises(export.NothingPortable) as raised:
            export.portable(base, only="awg")
        self.assertEqual(raised.exception.warnings, ["left out proxy-suite-ob-awg: it goes out through an interface of this host"])


if __name__ == "__main__":
    unittest.main()
