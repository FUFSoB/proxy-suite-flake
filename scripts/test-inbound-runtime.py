#!/usr/bin/env python3

import base64
import contextlib
import copy
import io
import json
import os
import stat
import tempfile
import unittest

import inbound_runtime as rt

# What config.nix renders as runtime.listenerDefaults: the option with nothing set.
LISTENER_DEFAULTS = {
    "acceptProxyProtocol": False,
    "address": "::",
    "fallbacks": [],
    "flow": None,
    "hysteria": {"masquerade": None, "portHopping": None, "salamander": {"enable": False, "password": None, "passwordFile": None}},
    "method": "2022-blake3-aes-128-gcm",
    "order": 1000,
    "port": 443,
    "reality": {
        "dest": "www.microsoft.com:443",
        "enable": False,
        "privateKey": None,
        "privateKeyFile": None,
        "publicKey": None,
        "serverNames": [],
        "shortIds": [""],
        "xver": 0,
    },
    "serverPassword": None,
    "serverPasswordFile": None,
    "shareAddress": None,
    "sharePort": None,
    "tls": {"alpn": None, "certificateFile": None, "enable": False, "keyFile": None, "serverName": None},
    "transport": {"host": None, "mode": None, "path": "/", "serviceName": "", "trustedXForwardedFor": [], "type": "raw"},
    "type": None,
    "via": None,
}


def declared_user(name, **fields):
    user = {
        "name": name,
        "order": None,
        "uuid": None,
        "uuidFile": None,
        "password": None,
        "passwordFile": None,
        "publicKey": None,
        "privateKeyFile": None,
        "presharedKeyFile": None,
        "address": None,
    }
    user.update(fields)
    return user


def declared_listener(tag, users, **fields):
    listener = copy.deepcopy(LISTENER_DEFAULTS)
    listener.pop("address")
    listener.update({"tag": tag, "type": "vless", "listen": "::", "via": "proxy", "users": users, "front": None,
                     "xrayJson": None, "jsonFile": None, "salamanderStateFile": f"/tmp/{tag}"})
    listener.update(fields)
    return listener


BOB = declared_user("bob", order=1, uuid="11111111-1111-4111-8111-111111111111")
ANON = declared_user("anon", uuid="22222222-2222-4222-8222-222222222222")
SS = declared_user("ss", password="c2VydmVyLWtleS0xNmJ5dGU=")


def make_spec(spool, **runtime):
    spec = {
        "serverAddress": "vpn.example.com",
        "shareLinks": True,
        "users": {u["name"]: {k: v for k, v in u.items() if k != "name"} for u in (BOB, ANON, SS)},
        "serverSource": {"ipv4": "10.78.0.0/24", "ipv6": "fd78::/64",
                         "declared": [{"name": "bob", "number": 1}, {"name": "anon", "number": 2}, {"name": "ss", "number": 3}]},
        "listeners": [
            declared_listener("vless-in", [BOB, ANON], order=1000),
            declared_listener("ss-in", [SS], type="shadowsocks", port=8388, method="aes-128-gcm"),
            declared_listener("awg", [], type="amneziawg", port=51820),
        ],
        "runtime": {
            "spool": spool,
            "ports": [8443, "20000-20010"],
            "vias": ["proxy", "direct", "block"],
            "defaultVia": "proxy",
            "fallbackDests": ["127.0.0.1:8080"],
            "tlsCertificates": {"main": {"certificateFile": "/run/cert", "keyFile": "/run/key", "serverName": None}},
            "selfFinalRules": [{"action": "block", "ip": ["geoip:private"]}],
            "salamanderStateDir": "/tmp/salamander",
            "listenerDefaults": LISTENER_DEFAULTS,
        },
    }
    spec["runtime"].update(runtime)
    return spec


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.spool = os.path.join(self.tmp.name, "spool")
        os.makedirs(self.spool)
        self.spec = make_spec(self.spool)
        # `xray x25519` as XRay 26 prints it.
        self.xray = os.path.join(self.tmp.name, "xray")
        with open(self.xray, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\necho 'PrivateKey: private-x'\necho 'Password (PublicKey): public-x'\necho 'Hash32: h'\n")
        os.chmod(self.xray, 0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def state(self):
        return rt.load_spool(self.spool)[0]

    def write(self, kind, name, entry):
        rt.write_entry(self.spool, kind, name, entry)

    def add_listener(self, tag, **entry):
        return rt.cmd_add(self.spec, self.spool, tag, entry, self.xray)

    # --- users -------------------------------------------------------------------

    def test_user_orders_go_around_declared_numbers(self):
        rt.cmd_users_add(self.spec, self.spool, "alice", None, ["vless-in"])
        rt.cmd_users_add(self.spec, self.spool, "carol", 9, [])
        users = self.state()["users"]
        self.assertEqual(users["alice"]["order"], 4)  # bob 1, anon 2, ss 3
        self.assertEqual(users["carol"]["order"], 9)
        self.assertRegex(users["alice"]["uuid"], r"^[0-9a-f-]{36}$")
        self.assertTrue(users["alice"]["password"])
        with self.assertRaisesRegex(rt.RuntimeError_, "declared user 'anon'"):
            rt.cmd_users_add(self.spec, self.spool, "dave", 2, [])
        with self.assertRaisesRegex(rt.RuntimeError_, "runtime user 'carol'"):
            rt.cmd_users_order(self.spec, self.spool, "alice", 9)
        with self.assertRaisesRegex(rt.RuntimeError_, "declared user"):
            rt.cmd_users_add(self.spec, self.spool, "bob", None, [])
        with self.assertRaisesRegex(rt.RuntimeError_, "Unknown listener"):
            rt.cmd_users_add(self.spec, self.spool, "erin", None, ["nope"])
        with self.assertRaisesRegex(rt.RuntimeError_, "Invalid user name"):
            rt.cmd_users_add(self.spec, self.spool, "a b", None, [])
        rt.cmd_users_order(self.spec, self.spool, "alice", 12)
        self.assertEqual(self.state()["users"]["alice"]["order"], 12)

    def test_a_number_past_the_ipv6_group_gets_no_address(self):
        # The last group holds four hex digits: 0x10000 would be no address, and the start
        # script would fail on it for every listener.
        spec = {"serverSource": {"ipv4": None, "ipv6": "fd78::/64", "declared": []}, "users": {}}
        warnings = []
        numbered = rt.number_users(spec, ["big", "ok"], {"big": {"order": 70000}, "ok": {"order": 65535}}, warnings)
        self.assertEqual([(n["email"], n["ipv6"]) for n in numbered], [("ok", "fd78::ffff")])
        self.assertIn("runtime user 'big': number 70000 does not fit in serverSource.ipv6", warnings[0])

    def test_runtime_users_join_declared_listeners(self):
        rt.cmd_users_add(self.spec, self.spool, "alice", None, ["vless-in", "awg"])
        merged, result, warnings = rt.merge(self.spec)
        by_tag = {l["tag"]: l for l in merged["listeners"]}
        self.assertEqual([u["name"] for u in by_tag["vless-in"]["users"]], ["bob", "anon", "alice"])
        # An AmneziaWG listener takes it as a peer, its keys and address left to awg_inbound.py.
        self.assertEqual([u["name"] for u in by_tag["awg"]["users"]], ["alice"])
        self.assertIsNone(by_tag["awg"]["users"][0]["address"])
        self.assertEqual(result["users"], ["alice"])
        self.assertEqual(result["selfSources"][0]["ipv4"], "10.78.0.4")
        self.assertEqual(result["selfSources"][0]["ipv6"], "fd78::4")
        self.assertEqual(warnings, [])

    def test_a_second_user_on_a_plain_shadowsocks_listener_is_refused(self):
        with self.assertRaisesRegex(rt.RuntimeError_, "2022-blake3-aes method"):
            rt.cmd_users_add(self.spec, self.spool, "alice", None, ["ss-in"])
        self.assertEqual(self.state()["users"], {})

    def test_shadowsocks_2022_keys_fit_the_method(self):
        rt.cmd_users_add(self.spec, self.spool, "alice", None, [])
        self.add_listener("ss2", type="shadowsocks", port=20003, method="2022-blake3-aes-128-gcm", users=["alice"])
        entry = self.state()["listeners"]["ss2"]
        self.assertEqual(len(base64.b64decode(entry["serverPassword"])), 16)
        merged, _, _ = rt.merge(self.spec)
        alice = next(l for l in merged["listeners"] if l["tag"] == "ss2")["users"][0]
        self.assertEqual(len(base64.b64decode(alice["password"])), 16)
        self.assertNotEqual(alice["password"], self.state()["users"]["alice"]["password"])

    def test_a_taken_order_moves_the_runtime_user_with_a_warning(self):
        # Written by hand, or the configuration gave the number to a declared user since.
        self.write("users", "zed", {"order": 1, "uuid": "33333333-3333-4333-8333-333333333333", "password": "p", "listeners": ["vless-in"]})
        _, result, warnings = rt.merge(self.spec)
        self.assertEqual(result["selfSources"][0]["number"], 4)
        self.assertTrue(any("order 1 is taken; using 4" in w for w in warnings))

    def test_bind_writes_the_runtime_side(self):
        rt.cmd_users_add(self.spec, self.spool, "alice", None, [])
        self.add_listener("friends", type="vless", port=20001)
        rt.cmd_bind(self.spec, self.spool, "alice", "vless-in", True)
        rt.cmd_bind(self.spec, self.spool, "bob", "friends", True)
        state = self.state()
        self.assertEqual(state["users"]["alice"]["listeners"], ["vless-in"])
        self.assertEqual(state["listeners"]["friends"]["users"], ["bob"])
        with self.assertRaisesRegex(rt.RuntimeError_, "Both bob and vless-in are declared"):
            rt.cmd_bind(self.spec, self.spool, "bob", "vless-in", True)
        rt.cmd_bind(self.spec, self.spool, "bob", "friends", False)
        self.assertEqual(self.state()["listeners"]["friends"]["users"], [])
        with self.assertRaisesRegex(rt.RuntimeError_, "not bound"):
            rt.cmd_bind(self.spec, self.spool, "bob", "friends", False)
        # A declared user without the secret the protocol needs.
        self.add_listener("tro", type="trojan", port=20002, tls={"enable": True, "certificate": "main"})
        with self.assertRaisesRegex(rt.RuntimeError_, "no password"):
            rt.cmd_bind(self.spec, self.spool, "bob", "tro", True)

    def test_removing_takes_the_bindings_along(self):
        rt.cmd_users_add(self.spec, self.spool, "alice", None, [])
        self.add_listener("friends", type="vless", port=20001, users=["alice", "bob"])
        rt.cmd_bind(self.spec, self.spool, "alice", "friends", True)
        rt.cmd_users_rm(self.spec, self.spool, "alice")
        self.assertEqual(self.state()["listeners"]["friends"]["users"], ["bob"])
        rt.cmd_users_add(self.spec, self.spool, "carol", None, ["friends", "vless-in"])
        rt.cmd_rm(self.spec, self.spool, "friends")
        self.assertEqual(self.state()["users"]["carol"]["listeners"], ["vless-in"])
        with self.assertRaisesRegex(rt.RuntimeError_, "declared in the configuration"):
            rt.cmd_rm(self.spec, self.spool, "vless-in")
        with self.assertRaisesRegex(rt.RuntimeError_, "declared in the configuration"):
            rt.cmd_users_rm(self.spec, self.spool, "bob")

    # --- listeners ---------------------------------------------------------------

    def test_reality_listener_gets_generated_keys(self):
        args = rt.main.__globals__["argparse"].Namespace(
            port=20001, listen=None, via=None, share_port=None, share_address=None, fingerprint="firefox", order=None, method=None,
            flow="vision", transport=None, path=None, host=None, mode=None, service_name=None, tls=None, alpn=None,
            sni=None, reality="www.example.com,example.com", reality_dest=None, short_id=None, masquerade=None,
            salamander=False, user=["bob"],
        )
        entry = rt.listener_from_flags("vless", args)
        self.assertEqual(entry["reality"]["dest"], "www.example.com:443")
        self.assertEqual(entry["flow"], "xtls-rprx-vision")
        self.assertEqual(entry["shareFingerprint"], "firefox")
        rt.cmd_add(self.spec, self.spool, "friends", entry, self.xray)
        saved = self.state()["listeners"]["friends"]
        self.assertEqual((saved["reality"]["privateKey"], saved["reality"]["publicKey"]), ("private-x", "public-x"))
        self.assertRegex(saved["reality"]["shortIds"][0], r"^[0-9a-f]{8}$")
        merged, result, _ = rt.merge(self.spec)
        friends = next(l for l in merged["listeners"] if l["tag"] == "friends")
        self.assertEqual(friends["listen"], "::")
        self.assertEqual(friends["shareFingerprint"], "firefox")
        self.assertEqual(friends["via"], "proxy")
        self.assertTrue(friends["runtime"])
        self.assertEqual(result["listeners"], ["friends"])

    def test_fences(self):
        cases = [
            ({"type": "vless", "port": 30000}, "not in inbounds.runtime.ports"),
            ({"type": "vless", "port": 443}, "not in inbounds.runtime.ports"),
            ({"type": "vless", "port": 20001, "via": "elsewhere"}, "via 'elsewhere'"),
            ({"type": "trojan", "port": 20001}, "TLS needs tls.certificate"),
            ({"type": "trojan", "port": 20001, "tls": {"enable": True, "certificate": "other"}}, "'other' is not in"),
            ({"type": "vless", "port": 20001, "tls": {"certificateFile": "/etc/shadow"}}, "not something a runtime entry can set"),
            ({"type": "vless", "port": 20001, "xrayJson": {}}, "not something a runtime entry can set"),
            ({"type": "amneziawg", "port": 20001}, "type: invalid value"),
            ({"type": "vless", "port": 20001, "shareFingerprint": "netscape"}, "shareFingerprint: invalid value"),
            ({"type": "hysteria2", "port": 20001, "hysteria": {"portHopping": "1-2"}}, "not something"),
            ({"type": "vless", "port": 20001, "fallbacks": [{"dest": 22}]}, "not in inbounds.runtime.fallbackDests"),
            ({"type": "vless", "port": 20001, "fallbacks": [{"listener": "vless-in"}]}, "must be another runtime listener"),
            ({"type": "vless", "port": 20001, "flow": "xtls-rprx-vision", "transport": {"type": "ws"}}, "flow is only valid"),
            ({"type": "vmess", "port": 20001, "reality": {"enable": True, "serverNames": ["a.com"]}}, "reality only for vless"),
            # XRay would take these as Unix socket paths.
            ({"type": "vless", "port": 20001, "address": "/run/x.sock"}, "not an IP address"),
            ({"type": "vless", "port": 20001, "address": "@abstract"}, "not an IP address"),
        ]
        for entry, message in cases:
            with self.subTest(entry=entry), self.assertRaisesRegex(rt.RuntimeError_, message):
                self.add_listener("x", **entry)
        self.assertEqual(self.state()["listeners"], {})
        with self.assertRaisesRegex(rt.RuntimeError_, "declared in the configuration"):
            self.add_listener("vless-in", type="vless", port=20001)
        self.add_listener("a", type="vless", port=20001)
        with self.assertRaisesRegex(rt.RuntimeError_, "taken by another listener"):
            self.add_listener("b", type="vless", port=20001)

    def test_fallback_to_a_runtime_listener(self):
        self.add_listener("ws", type="vless", port=20002, address="127.0.0.1", transport={"type": "ws", "path": "/ws"}, users=["bob"])
        self.add_listener("front", type="vless", port=8443, tls={"enable": True, "certificate": "main"},
                          fallbacks=[{"path": "/ws", "listener": "ws"}, {"dest": "127.0.0.1:8080"}], users=["bob"])
        merged, _, warnings = rt.merge(self.spec)
        self.assertEqual(warnings, [])
        by_tag = {l["tag"]: l for l in merged["listeners"]}
        self.assertEqual(by_tag["front"]["fallbacks"][0], {"name": None, "alpn": None, "path": "/ws", "dest": "127.0.0.1:20002", "xver": 2})
        self.assertEqual(by_tag["ws"]["front"]["port"], 8443)
        self.assertEqual(by_tag["front"]["tls"]["certificateFile"], "/run/cert")
        with self.assertRaisesRegex(rt.RuntimeError_, "already the fallback listener"):
            self.add_listener("front2", type="vless", port=20003, fallbacks=[{"path": "/ws", "listener": "ws"}], users=["bob"])

    def test_listener_without_users_waits(self):
        self.add_listener("empty", type="vless", port=20001)
        merged, result, warnings = rt.merge(self.spec)
        self.assertNotIn("empty", [l["tag"] for l in merged["listeners"]])
        self.assertTrue(any("'empty' has no users yet" in w for w in warnings))
        # AmneziaWG listeners run with no peers.
        self.assertIn("awg", [l["tag"] for l in merged["listeners"]])

    # --- the spool ---------------------------------------------------------------

    def test_bad_spool_entries_are_left_out(self):
        os.makedirs(os.path.join(self.spool, "users"))
        target = os.path.join(self.tmp.name, "secret.json")
        with open(target, "w", encoding="utf-8") as f:
            f.write(json.dumps({"order": 5, "uuid": "44444444-4444-4444-8444-444444444444", "password": "p", "listeners": []}))
        os.symlink(target, os.path.join(self.spool, "users", "link.json"))
        with open(os.path.join(self.spool, "users", "broken.json"), "w", encoding="utf-8") as f:
            f.write("{")
        os.mkfifo(os.path.join(self.spool, "users", "fifo.json"))
        self.write("users", "noorder", {"uuid": "44444444-4444-4444-8444-444444444444", "password": "p"})
        state, warnings = rt.load_spool(self.spool)
        self.assertEqual(sorted(state["users"]), ["noorder"])
        self.assertEqual(len(warnings), 3)
        _, result, more = rt.merge_state(self.spec, state)
        self.assertIn(("user", "noorder"), result["problems"])

    def test_entries_are_group_readable_only(self):
        self.write("users", "alice", {"order": 5})
        mode = stat.S_IMODE(os.stat(os.path.join(self.spool, "users", "alice.json")).st_mode)
        self.assertEqual(mode & 0o027, 0)

    # --- routing -----------------------------------------------------------------

    def test_expand_rules(self):
        exception = {"notVia": ["block"]}
        rules = [
            {"ruleTag": "inbound-block-private", "ip": ["geoip:private"], "outboundTag": "block"},
            {"ruleTag": "inbound-server-address-self-ip4-1", "user": ["bob"], "inboundTag": ["vless-in"], "_members": exception},
            {"_anchor": "selfIp", "inboundTag": ["vless-in"], "port": "443,20000-20010", "ip4": ["203.0.113.10"], "ip6": [], "_members": exception},
            {"ruleTag": "inbound-server-address-sniffed-direct", "inboundTag": [], "_members": {"via": ["direct"]}},
            {"ruleTag": "inbound-server-address-sniffed-proxy", "inboundTag": ["vless-in"], "_members": {"via": ["proxy"]}},
            {"_anchor": "selfName", "inboundTag": ["vless-in"], "port": "443", "domain": ["full:vpn.example.com"], "_members": exception},
            {"ruleTag": "inbound-final", "outboundTag": "proxy"},
        ]
        listeners = [{"tag": "friends", "via": "proxy"}, {"tag": "out", "via": "direct"}, {"tag": "shut", "via": "block"}]
        sources = [{"email": "alice", "number": 4, "id": "4", "ipv4": "10.78.0.4", "ipv6": None}]
        expanded = rt.expand_rules(rules, listeners, sources, "proxy")
        tags = [r.get("ruleTag") for r in expanded]
        self.assertEqual(tags, [
            "inbound-block-private",
            "inbound-server-address-self-ip4-1",
            "inbound-server-address-self-ip4-4",
            "inbound-server-address-sniffed-direct",
            "inbound-server-address-sniffed-proxy",
            "inbound-server-address-self-4",
            "inbound-via-out",
            "inbound-via-shut",
            "inbound-final",
        ])
        by_tag = {r.get("ruleTag"): r for r in expanded}
        self.assertEqual(by_tag["inbound-server-address-self-ip4-4"]["inboundTag"], ["vless-in", "friends", "out"])
        self.assertEqual(by_tag["inbound-server-address-self-ip4-4"]["outboundTag"], "direct-self4-4")
        self.assertEqual(by_tag["inbound-server-address-self-ip4-4"]["user"], ["alice"])
        self.assertEqual(by_tag["inbound-server-address-sniffed-direct"]["inboundTag"], ["out"])
        self.assertEqual(by_tag["inbound-server-address-self-4"]["domain"], ["full:vpn.example.com"])
        self.assertFalse(any("_members" in r or "_anchor" in r for r in expanded))
        # Nobody on direct: its guard goes.
        again = rt.expand_rules(rules, listeners[:1], [], "proxy")
        self.assertNotIn("inbound-server-address-sniffed-direct", [r.get("ruleTag") for r in again])

    def test_self_outbounds(self):
        outbounds = rt.self_outbounds([{"email": "a", "number": 4, "id": "4", "ipv4": "10.78.0.4", "ipv6": "fd78::4"}], [{"action": "block"}])
        self.assertEqual([o["tag"] for o in outbounds], ["direct-self4-4", "direct-self6-4"])
        self.assertEqual(outbounds[1]["settings"]["domainStrategy"], "UseIPv6")

    # --- the command line --------------------------------------------------------

    def run_main(self, *argv, stdin=None):
        spec_path = os.path.join(self.tmp.name, "spec.json")
        with open(spec_path, "w", encoding="utf-8") as f:
            json.dump(self.spec, f)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = rt.main(["--spec", spec_path, "--xray", self.xray, *argv])
        return status, out.getvalue(), err.getvalue()

    def test_main(self):
        status, out, _ = self.run_main("users", "add", "alice", "--listener", "vless-in")
        self.assertEqual((status, out), (0, "Added user alice (order 4) on vless-in\n"))
        status, out, _ = self.run_main("add", "hy", "hysteria2", "--port", "20005", "--tls", "main", "--salamander", "--user", "alice")
        self.assertEqual(status, 0, out)
        status, out, _ = self.run_main("users", "--json")
        rows = {r["name"]: r for r in json.loads(out)}
        self.assertEqual(rows["alice"]["listeners"], ["hy", "vless-in"])  # in listing order
        self.assertEqual(rows["alice"]["address"], "10.78.0.4")
        self.assertEqual(rows["anon"]["order"], 2)
        status, _, err = self.run_main("users", "add", "alice")
        self.assertEqual(status, 1)
        self.assertIn("already exists", err)
        status, out, _ = self.run_main("show", "hy")
        self.assertTrue(json.loads(out)["hysteria"]["salamander"]["enable"])

    def test_check_names_the_awg_unit_when_its_peers_change(self):
        users = os.path.join(self.tmp.name, "users.json")
        with open(users, "w", encoding="utf-8") as f:
            json.dump({"awg": []}, f)
        self.assertEqual(self.run_main("check", "--awg-users", users)[1], "")
        rt.cmd_users_add(self.spec, self.spool, "alice", None, ["awg"])
        self.assertEqual(self.run_main("check", "--awg-users", users)[1], "proxy-suite-inbounds-awg.service\n")

    def test_no_write_access(self):
        os.chmod(self.spool, 0o500)
        try:
            if os.access(self.spool, os.W_OK):
                self.skipTest("running as root")
            status, _, err = self.run_main("users", "add", "alice")
            self.assertEqual(status, 77)
            self.assertIn("Cannot write", err)
        finally:
            os.chmod(self.spool, 0o700)


if __name__ == "__main__":
    unittest.main()
