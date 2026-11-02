#!/usr/bin/env python3

import contextlib
import copy
import io
import json
import os
import secrets
import subprocess
import tempfile
import time
import unittest
from unittest import mock

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

    def test_the_shadowsocks_stand_in_for_nobody_is_no_user(self):
        # Its key is new at every render: never a change, never added or removed.
        def ss(*clients):
            return {"tag": "ss", "protocol": "shadowsocks", "port": 8388,
                    "settings": {"method": "2022-blake3-aes-128-gcm", "password": "k", "network": "tcp,udp",
                                 "clients": list(clients)}}

        def nobody():
            return {"password": secrets.token_hex(8), "email": ap.SS_NOBODY}

        user = {"password": "p", "email": "a"}
        self.assertTrue(ap.is_noop(ap.plan(rendering(ss(nobody())), rendering(ss(nobody())))))
        steps = ap.plan(rendering(ss(nobody())), rendering(ss(user)))
        self.assertEqual(steps["users"], {"ss": {"remove": [], "add": [user], "relevel": []}})
        steps = ap.plan(rendering(ss(user)), rendering(ss(nobody())))
        self.assertEqual(steps["users"], {"ss": {"remove": ["a"], "add": [], "relevel": []}})

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

    def test_a_level_change_alone_is_told_apart(self):
        def hysteria(*clients):
            return {"tag": "h", "protocol": "hysteria", "port": 443, "settings": {"version": 2, "clients": list(clients)}}

        old = rendering(hysteria({"auth": "a", "email": "u"}, {"auth": "b", "email": "v", "level": 1}))
        new = rendering(hysteria({"auth": "a", "email": "u", "level": 2}, {"auth": "c", "email": "v", "level": 3}))
        change = ap.plan(old, new)["users"]["h"]
        self.assertEqual(change["remove"], ["u", "v"])
        self.assertEqual(change["relevel"], ["u"])

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


    def test_a_level_change_alone_drops_no_udp(self):
        # The drop would shut out the user's next QUIC session too: their TCP goes, no UDP.
        tools = ap.Tools({"xray": "xray", "api": "unix:///run/api.sock"}, dry_run=True)
        hysteria = {"tag": "h", "protocol": "hysteria", "port": 8443, "settings": {"version": 2, "clients": []}}
        new = rendering(vless("a", [client("u", level=2)]), hysteria)
        steps = {"restart": [], "rules": None, "outbounds": {"remove": [], "add": []},
                 "addresses": {"remove": [], "add": []}, "outputs": False,
                 "users": {"a": {"remove": ["u"], "add": [client("u", level=2)], "relevel": ["u"]},
                           "h": {"remove": ["u", "v"], "add": [{"auth": "x", "email": "u", "level": 2}],
                                 "relevel": ["u"]}}}
        with mock.patch.object(ap, "online_ips", return_value=["198.51.100.7"]), \
                mock.patch.object(ap, "cut") as cut:
            done = ap.run_steps(tools, steps, new, None)
        # u by its TCP listener alone, v (gone) by both.
        self.assertEqual([call.args[1:] for call in cut.call_args_list],
                         [(["198.51.100.7"], {443}, set()), (["198.51.100.7"], set(), {8443})])
        self.assertEqual([line for line in done if line.startswith("cut")],
                         ["cut u (198.51.100.7)", "cut v (198.51.100.7)"])
        # Only its level changed, and only on a UDP listener: nothing to cut.
        steps["users"] = {"h": steps["users"]["h"] | {"remove": ["u"]}}
        with mock.patch.object(ap, "online_ips", return_value=["198.51.100.7"]), \
                mock.patch.object(ap, "cut") as cut:
            done = ap.run_steps(tools, steps, new, None)
        cut.assert_not_called()
        self.assertFalse([line for line in done if line.startswith("cut")])

    def test_behind_a_fallback_the_fronts_are_cut_too(self):
        # The client's socket is on the front's port: the back one's comes from loopback.
        tools = ap.Tools({"xray": "xray", "api": "unix:///run/api.sock"}, dry_run=True)
        front = vless("front", [client("f")])
        front["settings"]["fallbacks"] = [{"dest": "/run/web.sock"}, {"path": "/ws", "dest": "127.0.0.1:10444", "xver": 2}]
        back = vless("back", [client("u")], port=10444, listen="127.0.0.1")
        back["settings"]["fallbacks"] = [{"dest": "[::1]:10445", "xver": 2}]
        deep = vless("deep", [client("v")], port=10445, listen="::1")
        # Another host's port, and a bare one that is no listener's.
        other = vless("other", [client("w")], port=8443)
        other["settings"]["fallbacks"] = [{"dest": "198.51.100.9:10444"}, {"dest": 10446}]
        new = rendering(front, back, deep, other)
        self.assertEqual(ap.front_ports(new["inbounds"], deep), {443, 10444})
        self.assertEqual(ap.front_ports(new["inbounds"], other), set())
        self.assertEqual(ap.front_ports(new["inbounds"], vless("bare", [], port=10446)), {8443})
        steps = {"restart": [], "rules": None, "outbounds": {"remove": [], "add": []},
                 "addresses": {"remove": [], "add": []}, "outputs": False,
                 "users": {"back": {"remove": ["u"], "add": []}, "deep": {"remove": ["v"], "add": []},
                           "other": {"remove": ["w"], "add": []}}}
        with mock.patch.object(ap, "online_ips", return_value=["198.51.100.7"]), \
                mock.patch.object(ap, "cut") as cut:
            ap.run_steps(tools, steps, new, None)
        self.assertEqual([call.args[1:] for call in cut.call_args_list],
                         [(["198.51.100.7"], {443, 10444}, set()), (["198.51.100.7"], {443, 10444, 10445}, set()),
                          (["198.51.100.7"], {8443}, set())])

    def test_cut_takes_addresses_as_xray_gives_them(self):
        # IPv6 comes in brackets from statsonlineiplist: "[2001:db8::1]/128" is no ss filter,
        # "[2001:db8::1] . 443" no nft element.
        tools = ap.Tools({"ss": "ss", "nft": "nft", "nftTable": "t"}, dry_run=True)
        ap.cut(tools, ["[2001:db8::1]", "198.51.100.7", "[::ffff:203.0.113.5]:4433", "fe80::1%eth0", "nonsense"],
               {443}, {8443})
        log = "\n".join(tools.log)
        for prefix in ("2001:db8::1/128", "198.51.100.7/32", "203.0.113.5/32", "fe80::1/128"):
            self.assertIn(f"ss -K -n -t state established ( sport = :443 ) dst {prefix}", log)
        self.assertNotIn("[", log)
        self.assertNotIn("nonsense", log)
        with mock.patch.object(ap.subprocess, "run") as run:
            ap.cut(ap.Tools({"nft": "nft", "nftTable": "t"}), ["[2001:db8::1]", "198.51.100.7"], set(), {8443})
        self.assertEqual(run.call_args.kwargs["input"],
                         "add element inet t cut4 { 198.51.100.7 . 8443 timeout 90s }\n"
                         "add element inet t cut6 { 2001:db8::1 . 8443 timeout 90s }\n")

    def test_a_ban_takes_addresses_as_xray_gives_them(self):
        import inbound_netfilter

        netfilter = inbound_netfilter.Netfilter("nft", table="t")
        with mock.patch.object(netfilter, "_run") as run:
            netfilter.ban("[2001:db8::1]", [443, 8443], 300)
            run.assert_called_once_with("add", "element", "inet", "t", "ban6",
                                        "{ 2001:db8::1 . 443 timeout 300s, 2001:db8::1 . 8443 timeout 300s }")
            with self.assertRaises(RuntimeError):
                netfilter.ban("nonsense", [443], 300)


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


class Outputs(unittest.TestCase):
    def test_a_failed_write_is_tried_again(self):
        with tempfile.TemporaryDirectory() as directory:
            old = rendering(vless("a", [client("u")]))
            new = rendering(vless("a", [client("u")]), links=[{"link": "vless://..."}])
            for name, value in (("rendered.json", old), ("render-args.json", {}), ("config.json", {})):
                with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
                    json.dump(value, handle)
            tools = ap.Tools({"runtimeDir": directory, "unit": "proxy-suite-inbounds.service", "systemctl": "false",
                              "outputsScript": "/nonexistent/write-outputs"})
            with mock.patch.object(ap, "render", return_value=(new, [])), \
                    mock.patch.object(ap, "write_outputs", side_effect=ap.ApplyError("disk full")) as write, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ap.apply_xray(tools, {}), [])
            self.assertEqual(write.call_count, 1)
            saved = ap.load_json(os.path.join(directory, "rendered.json"))
            self.assertTrue(saved[ap.OUTPUTS_PENDING])
            self.assertEqual(saved["links"], new["links"])
            # Nothing else changed, and they are written again.
            with mock.patch.object(ap, "render", return_value=(new, [])), \
                    mock.patch.object(ap, "write_outputs") as write:
                self.assertEqual(ap.apply_xray(tools, {}), ["links and subscriptions"])
            self.assertEqual(write.call_count, 1)
            self.assertEqual(ap.load_json(os.path.join(directory, "rendered.json")), new)
            with mock.patch.object(ap, "render", return_value=(new, [])), \
                    mock.patch.object(ap, "write_outputs") as write:
                self.assertEqual(ap.apply_xray(tools, {}), [])
            write.assert_not_called()


class Netfilter(unittest.TestCase):
    def test_unban_takes_the_address_as_ban_does(self):
        import inbound_netfilter

        netfilter = inbound_netfilter.Netfilter("nft", table="t")
        listed = [{"ip": "2001:db8::1", "port": 443, "expires": 100}, {"ip": "198.51.100.7", "port": 443, "expires": 100}]
        for written in ("[2001:db8::1]", "2001:DB8:0:0::1", "[2001:db8::1]:443"):
            with mock.patch.object(netfilter, "bans", return_value=listed), mock.patch.object(netfilter, "_run") as run:
                self.assertEqual(netfilter.unban(written), 1)
                run.assert_called_once_with("delete", "element", "inet", "t", "ban6", "{ 2001:db8::1 . 443 }")
        with mock.patch.object(netfilter, "bans", return_value=listed), mock.patch.object(netfilter, "_run") as run:
            self.assertEqual(netfilter.unban("::ffff:198.51.100.7"), 1)
            run.assert_called_once_with("delete", "element", "inet", "t", "ban4", "{ 198.51.100.7 . 443 }")

    def test_limits_look_past_zapret_marks(self):
        # zapret's CONNMARKER may OR 0x40000000 into an exit connection's mark: still its user's.
        import inbound_netfilter

        ruleset = inbound_netfilter.ruleset("t")
        self.assertIn("ct direction reply ct mark & 0x0fff0000 == 0x04000000 limit name ct mark & 0x0fffffff map @down drop",
                      ruleset)
        self.assertIn("ct direction original ct mark & 0x0fff0000 == 0x04000000 limit name ct mark & 0x0fffffff map @up drop",
                      ruleset)
        # The socket's own mark, though, whole.
        self.assertIn("ct state new meta mark & 0xffff0000 == 0x04000000 ct mark set meta mark", ruleset)
        self.assertEqual(0x44000007 & inbound_netfilter.CT_MARK_KEY, inbound_netfilter.MARK_BASE + 7)


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
