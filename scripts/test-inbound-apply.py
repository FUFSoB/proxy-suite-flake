#!/usr/bin/env python3

import copy
import json
import os
import secrets
import subprocess
import tempfile
import time
import unittest

import inbound_apply as ap

UUID_A = "b831381d-6324-4d53-ad4f-8cda48b30811"
UUID_B = "11111111-2222-3333-4444-555555555555"


def vless(tag, clients, port=443, **extra):
    inbound = {"tag": tag, "listen": "::", "port": port, "protocol": "vless",
               "settings": {"clients": clients, "decryption": "none"},
               "streamSettings": {"network": "raw", "security": "none"}}
    inbound.update(extra)
    return inbound


def client(email, uuid=UUID_A, **extra):
    return {"id": uuid, "email": email, **extra}


def rendering(*inbounds, **extra):
    return {"inbounds": list(inbounds), "links": [], "subscriptions": [], **extra}


class Plan(unittest.TestCase):
    def test_nothing_changed(self):
        old = rendering(vless("a", [client("u")]))
        steps = ap.plan(old, copy.deepcopy(old))
        self.assertTrue(ap.is_noop(steps))

    def test_users_come_and_go(self):
        old = rendering(vless("a", [client("u"), client("v", UUID_B)]))
        new = rendering(vless("a", [client("v", UUID_B, level=3), client("w")]))
        steps = ap.plan(old, new)
        self.assertEqual(steps["restart"], [])
        self.assertEqual(steps["users"]["a"]["remove"], ["u", "v"])
        self.assertEqual([c["email"] for c in steps["users"]["a"]["add"]], ["v", "w"])

    def test_a_changed_listener_restarts(self):
        old = rendering(vless("a", [client("u")]))
        new = rendering(vless("a", [client("u")], port=8443))
        self.assertEqual(ap.plan(old, new)["restart"], ["listener 'a' changed"])

    def test_listeners_added_or_gone_restart(self):
        old = rendering(vless("a", [client("u")]))
        new = rendering(vless("a", [client("u")]), vless("b", [client("u")], port=8443))
        self.assertEqual(ap.plan(old, new)["restart"], ["listeners added: b"])
        self.assertEqual(ap.plan(new, old)["restart"], ["listeners gone: b"])

    def test_accounts_and_single_user_shadowsocks_restart(self):
        socks = {"tag": "s", "protocol": "socks", "port": 1080, "settings": {"accounts": [{"user": "u", "pass": "1"}]}}
        changed = copy.deepcopy(socks)
        changed["settings"]["accounts"].append({"user": "v", "pass": "2"})
        self.assertTrue(ap.plan(rendering(socks), rendering(changed))["restart"])
        single = {"tag": "ss", "protocol": "shadowsocks", "port": 8388,
                  "settings": {"method": "aes-128-gcm", "password": "x", "email": "u"}}
        other = copy.deepcopy(single)
        other["settings"]["level"] = 2
        self.assertTrue(ap.plan(rendering(single), rendering(other))["restart"])

    def test_routing_outbounds_addresses_and_outputs(self):
        old = rendering(vless("a", []), rules=[{"ruleTag": "x"}],
                        selfOutbounds=[{"tag": "direct-self4-1", "sendThrough": "10.0.0.1"}],
                        selfAddresses=[{"ipv4": "10.0.0.1", "ipv6": None}])
        new = rendering(vless("a", []), rules=[{"ruleTag": "x"}, {"ruleTag": "y"}],
                        selfOutbounds=[{"tag": "direct-self4-2", "sendThrough": "10.0.0.2"}],
                        selfAddresses=[{"ipv4": "10.0.0.2", "ipv6": "fd00::2"}])
        new["links"] = [{"link": "vless://..."}]
        steps = ap.plan(old, new)
        self.assertEqual(steps["rules"], [{"ruleTag": "x"}, {"ruleTag": "y"}])
        self.assertEqual(steps["outbounds"]["remove"], ["direct-self4-1"])
        self.assertEqual([o["tag"] for o in steps["outbounds"]["add"]], ["direct-self4-2"])
        self.assertEqual(steps["addresses"]["remove"], [("4", "10.0.0.1")])
        self.assertEqual(steps["addresses"]["add"], [("4", "10.0.0.2"), ("6", "fd00::2")])
        self.assertTrue(steps["outputs"])

    def test_udp_inbounds(self):
        self.assertTrue(ap.udp_inbound({"protocol": "hysteria"}))
        self.assertTrue(ap.udp_inbound({"protocol": "vless", "streamSettings": {"network": "xhttp", "tlsSettings": {"alpn": ["h3"]}}}))
        self.assertFalse(ap.udp_inbound(vless("a", [])))


class Steps(unittest.TestCase):
    def test_the_commands(self):
        config = {"xray": "xray", "api": "unix:///run/api.sock", "ss": "ss", "nft": "nft", "nftTable": "t",
                  "ip": "ip", "selfInterface": "ps-self"}
        tools = ap.Tools(config, dry_run=True)
        new = rendering(vless("a", [client("w")]), {"tag": "h", "protocol": "hysteria", "port": 443, "settings": {"clients": []}})
        steps = {"restart": [], "users": {"a": {"remove": ["u"], "add": [client("w")]}, "h": {"remove": ["u"], "add": []}},
                 "rules": None, "outbounds": {"remove": [], "add": []},
                 "addresses": {"remove": [("4", "10.0.0.1")], "add": [("6", "fd00::2")]}, "outputs": False}
        done = ap.run_steps(tools, steps, new, None)
        self.assertIn("a: -u", done)
        self.assertIn("a: +w", done)
        log = "\n".join(tools.log)
        self.assertIn("xray api statsonlineiplist --server=unix:///run/api.sock -email u", log)
        self.assertIn("xray api rmu --server=unix:///run/api.sock -tag=a u", log)
        self.assertIn("xray api adu --server=unix:///run/api.sock", log)
        self.assertIn("ip -4 addr del 10.0.0.1/32 dev ps-self", log)
        self.assertIn("ip -6 addr add fd00::2/128 dev ps-self nodad", log)


class SyncConfig(unittest.TestCase):
    def test_config_json_follows_in_place(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.json")
            running = {"inbounds": [vless("a", [client("u")]), vless("b", [client("u")], port=8443)],
                       "routing": {"rules": [{"ruleTag": "x"}]},
                       "outbounds": [{"tag": "direct"}, {"tag": "direct-self4-1"}]}
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(running, handle)
            os.chmod(path, 0o440 | 0o200)
            inode = os.stat(path).st_ino
            new = rendering(vless("a", [client("w")]), vless("b", [client("u")], port=8443))
            steps = {"users": {"a": {"remove": ["u"], "add": [client("w")]}}, "rules": [{"ruleTag": "y"}],
                     "outbounds": {"remove": ["direct-self4-1"], "add": [{"tag": "direct-self4-2"}]}}
            ap.sync_config(directory, steps, new)
            with open(path, encoding="utf-8") as handle:
                synced = json.load(handle)
            self.assertEqual(os.stat(path).st_ino, inode)
            self.assertEqual([c["email"] for c in synced["inbounds"][0]["settings"]["clients"]], ["w"])
            self.assertEqual([c["email"] for c in synced["inbounds"][1]["settings"]["clients"]], ["u"])
            self.assertEqual(synced["routing"]["rules"], [{"ruleTag": "y"}])
            self.assertEqual([o["tag"] for o in synced["outbounds"]], ["direct", "direct-self4-2"])


class SingBox(unittest.TestCase):
    def config(self, cert, users):
        return {"inbounds": [{"type": "anytls", "tag": "any", "users": users,
                              "tls": {"enabled": True, "certificate_path": cert, "key_path": "/k"}}],
                "outbounds": [], "route": {"rules": []}}

    def test_written_in_place_with_its_copies_and_reloaded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "sing-box.json")
            old = self.config("/acme/cert.pem", [{"name": "a"}])
            # The start script swapped the certificate for a copy sing-box can read.
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(self.config(f"{directory}/tls/1-cert.pem", [{"name": "a"}]), handle)
            inode = os.stat(path).st_ino
            tools = ap.Tools({"systemctl": "true", "singBoxUnit": "proxy-suite-inbounds-sing-box.service",
                              "unit": "proxy-suite-inbounds.service"})
            done = ap.sync_sing_box(tools, directory, old, self.config("/acme/cert.pem", [{"name": "a"}, {"name": "b"}]))
            self.assertEqual(done, ["sing-box listeners"])
            self.assertIn("true try-reload-or-restart proxy-suite-inbounds-sing-box.service", tools.log)
            with open(path, encoding="utf-8") as handle:
                written = json.load(handle)
            self.assertEqual(os.stat(path).st_ino, inode)
            self.assertEqual(written["inbounds"][0]["users"], [{"name": "a"}, {"name": "b"}])
            self.assertEqual(written["inbounds"][0]["tls"]["certificate_path"], f"{directory}/tls/1-cert.pem")
            self.assertEqual(written["inbounds"][0]["tls"]["key_path"], "/k")
            # Nothing changed, nothing done.
            self.assertEqual(ap.sync_sing_box(tools, directory, old, old), [])
            # From none (no user let in at start): the start script, with its copies, again.
            tools = ap.Tools({"systemctl": "systemctl", "singBoxUnit": "x.service", "unit": "proxy-suite-inbounds.service"},
                             dry_run=True)
            self.assertEqual(ap.sync_sing_box(tools, directory, None, old),
                             ["restarted proxy-suite-inbounds.service: sing-box's listeners changed"])


class Stopped(unittest.TestCase):
    def test_stopped_inbounds_are_left_to_try_restart(self):
        config = {"runtimeDir": "/nonexistent/proxy-suite-inbounds", "unit": "proxy-suite-inbounds.service",
                  "systemctl": "systemctl"}
        done = ap.apply(config, {"listeners": []}, dry_run=True)
        self.assertEqual(done, ["restarted proxy-suite-inbounds.service: the inbounds are not running"])


class AmneziaWG(unittest.TestCase):
    CONFIG = "[Interface]\nPrivateKey = k\nAddress = 10.66.0.1/24\nListenPort = 51820\nMTU = 1380\nTable = off\nJc = 4\n\n[Peer]\nPublicKey = p\nAllowedIPs = 10.66.0.2/32\n"

    def test_strip(self):
        stripped = ap.strip_config(self.CONFIG)
        self.assertNotIn("Address", stripped)
        self.assertNotIn("MTU", stripped)
        self.assertIn("Jc = 4", stripped)
        self.assertIn("AllowedIPs = 10.66.0.2/32", stripped)

    def test_interface_part_ignores_peers(self):
        other = self.CONFIG.replace("10.66.0.2/32", "10.66.0.3/32")
        self.assertEqual(ap.interface_part(self.CONFIG), ap.interface_part(other))
        self.assertNotEqual(ap.interface_part(self.CONFIG), ap.interface_part(self.CONFIG.replace("Jc = 4", "Jc = 5")))


@unittest.skipUnless(os.environ.get("XRAY"), "XRAY is not set: no live XRay to talk to")
class LiveXray(unittest.TestCase):
    """The API steps against a running XRay: users added and removed, rules replaced."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.socket = f"@proxy-suite-test-{secrets.token_hex(4)}"
        self.api = f"unix-abstract:{self.socket[1:]}"
        template = {"routing": {"domainStrategy": "AsIs", "rules": [{"ruleTag": "inbound-stats-api", "inboundTag": ["api-in"], "outboundTag": "api"}]}}
        config = {
            "log": {"loglevel": "warning"},
            "api": {"tag": "api", "services": ["StatsService", "HandlerService", "RoutingService"]},
            "stats": {},
            "inbounds": [
                {"tag": "api-in", "protocol": "dokodemo-door", "listen": self.socket,
                 "settings": {"address": "127.0.0.1", "network": "unix"}},
                vless("a", [client("u")], port=0, listen="127.0.0.1"),
            ],
            "outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "api", "protocol": "freedom"}],
            "routing": template["routing"],
        }
        self.template = template
        # Port 0 is no port to XRay: take a free one.
        import socket
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            config["inbounds"][1]["port"] = probe.getsockname()[1]
        self.inbound = config["inbounds"][1]
        path = os.path.join(self.dir.name, "config.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(config, handle)
        self.xray = subprocess.Popen([os.environ["XRAY"], "run", "-c", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.tools = ap.Tools({"xray": os.environ["XRAY"], "api": self.api, "tmpDir": self.dir.name})
        for _ in range(50):
            try:
                self.tools.xray_api("lsi", what="waiting")
                break
            except ap.ApplyError:
                time.sleep(0.1)

    def tearDown(self):
        self.xray.terminate()
        self.xray.wait()
        self.dir.cleanup()

    def users(self):
        out = self.tools.xray_api("inbounduser", "-tag=a", what="listing")
        return sorted(u["email"] for u in json.loads(out or "{}").get("users") or [])

    def test_users_and_rules(self):
        old = rendering(self.inbound)
        new_inbound = copy.deepcopy(self.inbound)
        new_inbound["settings"]["clients"] = [client("v", UUID_B, level=4)]
        new = rendering(new_inbound, rules=self.template["routing"]["rules"] + [{"ruleTag": "extra", "user": ["v"], "outboundTag": "direct"}])
        steps = ap.plan(old, new)
        self.assertEqual(steps["restart"], [])
        ap.run_steps(self.tools, steps, new, self.template)
        self.assertEqual(self.users(), ["v"])
        rules = json.loads(self.tools.xray_api("lsrules", what="rules"))["rules"]
        self.assertEqual([r["ruleTag"] for r in rules], ["inbound-stats-api", "extra"])


if __name__ == "__main__":
    unittest.main()
