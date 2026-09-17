#!/usr/bin/env python3

import base64
import hashlib
import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest

import awg_inbound
from amneziawg_config import conf_sections, decode_vpn_link, extract_vpn_config
from proxy_inbound import build_inbounds

# Stands in for `awg`: keys are random, a public key is a hash of its private key, and
# `show <interface> dump` prints $AWG_DUMP_<interface, dashes as underscores>.
STUB_AWG = f"#!{sys.executable}\n" + textwrap.dedent(
    """\
    import base64, hashlib, os, sys
    command = sys.argv[1]
    if command in ("genkey", "genpsk"):
        print(base64.b64encode(os.urandom(32)).decode())
    elif command == "pubkey":
        print(base64.b64encode(hashlib.sha256(sys.stdin.read().strip().encode()).digest()).decode())
    elif command == "show":
        dump = os.environ.get("AWG_DUMP_" + sys.argv[2].replace("-", "_"))
        if dump is None:
            sys.exit(1)
        sys.stdout.write(dump)
    else:
        sys.exit(2)
    """
)


def public_of(private: str) -> str:
    return base64.b64encode(hashlib.sha256(private.encode()).digest()).decode()


OBFUSCATION_FIELDS = (
    "jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 headerProtectionKey headerProtectionKeyFile "
    "randomTrailers contentPaddingAddition disableCookies keepaliveTimeout maxHandshakeAttempts "
    "rejectAfterTime rekeyAfterTime rekeyTimeout"
).split()


def user(name, **overrides):
    entry = {
        "name": name,
        "address": None,
        "publicKey": None,
        "privateKeyFile": None,
        "presharedKeyFile": None,
        "uuid": None,
        "uuidFile": None,
        "password": None,
        "passwordFile": None,
    }
    entry.update(overrides)
    return entry


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.awg = os.path.join(self.dir, "awg")
        with open(self.awg, "w", encoding="utf-8") as handle:
            handle.write(STUB_AWG)
        os.chmod(self.awg, stat.S_IRWXU)
        self.runtime = os.path.join(self.dir, "run")
        os.mkdir(self.runtime)
        self.keys = awg_inbound.Keys(self.awg)

    def tearDown(self):
        self.tmp.cleanup()

    def listener(self, tag="awg-in", users=None, **awg_overrides):
        awg = {
            "mode": "proxy",
            "interfaceName": f"awgi-{tag}",
            "subnet": "10.66.0.0/24",
            "subnet6": None,
            "privateKeyFile": None,
            "obfuscation": {field: None for field in OBFUSCATION_FIELDS},
            "dns": ["1.1.1.1", "1.0.0.1"],
            "mtu": None,
            "persistentKeepalive": 25,
            "clientAllowedIPs": ["0.0.0.0/0", "::/0"],
            "internalPort": 18700,
            "internalListen": "127.0.0.1",
            "stateFile": os.path.join(self.dir, "state", tag, "state.json"),
            "fwmark": 2,
        }
        awg.update(awg_overrides)
        return {
            "tag": tag,
            "type": "amneziawg",
            "port": 51820,
            "sharePort": None,
            "listen": "::",
            "users": users if users is not None else [user("alice"), user("bob")],
            "amneziaWg": awg,
        }

    def spec(self, *listeners):
        return {"serverAddress": "vpn.example.com", "shareLinks": True, "listeners": list(listeners)}

    def state(self, listener):
        with open(listener["amneziaWg"]["stateFile"], encoding="utf-8") as handle:
            return json.load(handle)

    def secret_file(self, name, value):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(value + "\n")
        return path


class ObfuscationTests(unittest.TestCase):
    def test_generated_values_are_valid(self):
        for _ in range(200):
            values = awg_inbound.generate_obfuscation({}, {})
            self.assertEqual(set(values), set(awg_inbound.GENERATED_OBFUSCATION))
            self.assertTrue(3 <= values["jc"] <= 10)
            self.assertTrue(values["jmin"] + 8 <= values["jmax"] <= 250)
            self.assertNotEqual(values["s1"] + 56, values["s2"])
            headers = [values[key] for key in ("h1", "h2", "h3", "h4")]
            self.assertEqual(len(set(headers)), 4)
            self.assertTrue(all(5 <= header < 2**31 for header in headers))

    def test_stored_values_are_kept(self):
        first = awg_inbound.generate_obfuscation({}, {})
        self.assertEqual(awg_inbound.generate_obfuscation({}, first), first)

    def test_declared_values_are_not_generated(self):
        values = awg_inbound.generate_obfuscation({"jc": 4, "h1": 7, "jmax": 20}, {})
        self.assertNotIn("jc", values)
        self.assertNotIn("h1", values)
        self.assertTrue(values["jmin"] < 20)
        self.assertNotIn(7, [values[key] for key in ("h2", "h3", "h4")])


class StateTests(Fixture):
    def test_prepare_creates_private_state_and_server_config(self):
        listener = self.listener()
        prepared = awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        self.assertEqual(len(prepared), 1)
        self.assertEqual(prepared[0]["interface"], "awgi-awg-in")
        self.assertIn(prepared[0]["implementation"], ("auto", "userspace"))

        state_path = listener["amneziaWg"]["stateFile"]
        self.assertEqual(stat.S_IMODE(os.stat(state_path).st_mode), 0o600)
        state = self.state(listener)
        self.assertEqual(state["server"]["publicKey"], public_of(state["server"]["privateKey"]))
        self.assertEqual(state["users"]["alice"]["offset"], 2)
        self.assertEqual(state["users"]["bob"]["offset"], 3)

        with open(prepared[0]["config"], encoding="utf-8") as handle:
            config = handle.read()
        self.assertEqual(stat.S_IMODE(os.stat(prepared[0]["config"]).st_mode), 0o600)
        sections = conf_sections(config)
        interface = dict(sections[0][1])
        self.assertEqual(interface["address"], "10.66.0.1/24")
        self.assertEqual(interface["listenport"], "51820")
        self.assertEqual(interface["table"], "off")
        self.assertEqual(interface["fwmark"], "2")
        self.assertEqual(interface["privatekey"], state["server"]["privateKey"])
        peers = [dict(values) for name, values in sections if name == "peer"]
        self.assertEqual(
            {peer["publickey"]: peer["allowedips"] for peer in peers},
            {
                state["users"]["alice"]["publicKey"]: "10.66.0.2/32",
                state["users"]["bob"]["publicKey"]: "10.66.0.3/32",
            },
        )
        self.assertTrue(all("presharedkey" in peer for peer in peers))

    def test_state_is_stable_across_runs_and_reorders(self):
        listener = self.listener()
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        before = self.state(listener)
        listener["users"].reverse()
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        self.assertEqual(self.state(listener), before)

    def test_departed_users_are_pruned_and_their_address_reused(self):
        listener = self.listener()
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        alice = self.state(listener)["users"]["alice"]
        listener["users"] = [user("bob")]
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        self.assertNotIn("alice", self.state(listener)["users"])
        listener["users"] = [user("bob"), user("carol"), user("alice")]
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        state = self.state(listener)
        self.assertEqual(state["users"]["bob"]["offset"], 3)
        self.assertEqual(state["users"]["carol"]["offset"], 2)
        self.assertEqual(state["users"]["alice"]["offset"], 4)
        self.assertNotEqual(state["users"]["alice"]["privateKey"], alice["privateKey"])

    def test_declared_address_wins(self):
        listener = self.listener()
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        listener["users"] = [user("alice"), user("bob", address="10.66.0.2")]
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        state = self.state(listener)
        self.assertEqual(state["users"]["bob"]["offset"], 2)
        self.assertEqual(state["users"]["alice"]["offset"], 3)

    def test_invalid_addresses_are_rejected(self):
        for address in ("10.67.0.5", "10.66.0.1", "10.66.0.255", "10.66.0.0"):
            with self.subTest(address=address):
                listener = self.listener(users=[user("alice", address=address)])
                with self.assertRaises(awg_inbound.ConfigError):
                    awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        listener = self.listener(users=[user("alice", address="10.66.0.5"), user("bob", address="10.66.0.5")])
        with self.assertRaises(awg_inbound.ConfigError):
            awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)

    def test_full_subnet_is_rejected(self):
        listener = self.listener(subnet="10.66.0.0/30", users=[user("alice"), user("bob")])
        with self.assertRaises(awg_inbound.ConfigError):
            awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)

    def test_ipv6_subnet_adds_addresses(self):
        listener = self.listener(subnet6="fd00:66::/64")
        prepared = awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        with open(prepared[0]["config"], encoding="utf-8") as handle:
            sections = conf_sections(handle.read())
        interface = sections[0][1]
        addresses = ",".join(value for key, value in interface if key == "address")
        self.assertIn("10.66.0.1/24", addresses)
        self.assertIn("fd00:66::1/64", addresses)
        peer = dict(sections[1][1])
        self.assertIn("fd00:66::2/128", peer["allowedips"])

    def test_key_overrides(self):
        server_private = "c2VydmVyLXByaXZhdGUta2V5LXNlcnZlci1wcml2YXRlLWs="
        user_private = "dXNlci1wcml2YXRlLWtleS11c2VyLXByaXZhdGUta2V5LXU="
        psk = "cHNrLXBzay1wc2stcHNrLXBzay1wc2stcHNrLXBzay1wc2s="
        listener = self.listener(
            privateKeyFile=self.secret_file("server.key", server_private),
            users=[
                user("alice", privateKeyFile=self.secret_file("alice.key", user_private)),
                user("bob", publicKey="Ym9iLXB1YmxpYy1rZXktYm9iLXB1YmxpYy1rZXktYm9iLXA="),
                user("carol", presharedKeyFile=self.secret_file("carol.psk", psk)),
            ],
        )
        prepared = awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        state = self.state(listener)
        # Declared secrets stay out of the state.
        self.assertEqual(state["server"], {"publicKey": public_of(server_private)})
        self.assertEqual(state["users"]["alice"], {"offset": 2, "publicKey": public_of(user_private), "presharedKey": state["users"]["alice"]["presharedKey"]})
        self.assertEqual(
            state["users"]["bob"],
            {"offset": 3, "publicKey": "Ym9iLXB1YmxpYy1rZXktYm9iLXB1YmxpYy1rZXktYm9iLXA="},
        )
        self.assertNotIn("presharedKey", state["users"]["carol"])
        self.assertNotIn(psk, json.dumps(state))

        with open(prepared[0]["config"], encoding="utf-8") as handle:
            config = handle.read()
        self.assertIn(server_private, config)
        self.assertIn(psk, config)

        entries = awg_inbound.client_entries(listener, "vpn.example.com", 51820)
        self.assertEqual([entry["user"] for entry in entries], ["alice", "carol"])
        self.assertIn(user_private, entries[0]["config"])
        self.assertIn(psk, entries[1]["config"])

    def test_switching_server_key_to_generated_derives_its_public_key(self):
        listener = self.listener(privateKeyFile=self.secret_file("server.key", "c2VydmVy"))
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        listener["amneziaWg"]["privateKeyFile"] = None
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        server = self.state(listener)["server"]
        self.assertEqual(server["publicKey"], public_of(server["privateKey"]))

    def test_declared_obfuscation_wins(self):
        listener = self.listener()
        listener["amneziaWg"]["obfuscation"]["jc"] = 7
        listener["amneziaWg"]["obfuscation"]["i1"] = "<b 0xf6ab3267fa><c><t><r 10>"
        prepared = awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        self.assertNotIn("jc", self.state(listener)["obfuscation"])
        with open(prepared[0]["config"], encoding="utf-8") as handle:
            interface = dict(conf_sections(handle.read())[0][1])
        self.assertEqual(interface["jc"], "7")
        self.assertEqual(interface["i1"], "<b 0xf6ab3267fa><c><t><r 10>")
        config = awg_inbound.client_entries(listener, "vpn.example.com", 51820)[0]["config"]
        self.assertEqual(dict(conf_sections(config)[0][1])["jc"], "7")


class ClientTests(Fixture):
    def test_client_config_matches_server(self):
        listener = self.listener(subnet6="fd00:66::/64", mtu=1280)
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        state = self.state(listener)
        entries = awg_inbound.client_entries(listener, "2001:db8::1", 443)
        self.assertEqual([entry["user"] for entry in entries], ["alice", "bob"])
        sections = conf_sections(entries[1]["config"])
        interface = dict(sections[0][1])
        peer = dict(sections[1][1])
        addresses = [value for key, value in sections[0][1] if key == "address"]
        self.assertEqual(interface["privatekey"], state["users"]["bob"]["privateKey"])
        self.assertIn("10.66.0.3/32", ",".join(addresses))
        self.assertIn("fd00:66::3/128", ",".join(addresses))
        self.assertIn("1.1.1.1", interface["dns"])
        self.assertEqual(interface["mtu"], "1280")
        for key in ("jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"):
            self.assertEqual(interface[key], str(state["obfuscation"][key]))
        self.assertEqual(peer["publickey"], state["server"]["publicKey"])
        self.assertEqual(peer["presharedkey"], state["users"]["bob"]["presharedKey"])
        self.assertEqual(peer["endpoint"], "[2001:db8::1]:443")
        self.assertEqual(peer["persistentkeepalive"], "25")
        self.assertNotIn("fwmark", interface)
        self.assertNotIn("table", interface)

    def test_vpn_link_round_trip(self):
        listener = self.listener()
        awg_inbound.prepare(self.spec(listener), self.awg, self.runtime)
        for entry in awg_inbound.client_entries(listener, "vpn.example.com", 51820):
            with self.subTest(user=entry["user"]):
                self.assertTrue(entry["link"].startswith("vpn://"))
                data = decode_vpn_link(entry["link"])
                self.assertEqual(data["hostName"], "vpn.example.com")
                self.assertEqual(data["dns1"], "1.1.1.1")
                self.assertEqual(data["containers"][0]["container"], "amnezia-awg")
                decoded = extract_vpn_config(data)

                def without_listen_port(config):
                    return [
                        (name, sorted((key, value) for key, value in values if key != "listenport"))
                        for name, values in conf_sections(config)
                    ]

                self.assertEqual(without_listen_port(decoded), without_listen_port(entry["config"]))

    def test_missing_state_yields_no_entries(self):
        listener = self.listener()
        self.assertEqual(awg_inbound.client_entries(listener, "vpn.example.com", 51820), [])

    def test_build_inbounds(self):
        listener = self.listener()
        listener["sharePort"] = 443
        other = {
            "tag": "vless-in",
            "type": "vless",
            "port": 8443,
            "sharePort": None,
            "listen": "::",
            "users": [user("alice", uuid="11111111-1111-1111-1111-111111111111")],
            "flow": None,
            "method": "2022-blake3-aes-128-gcm",
            "transport": {"type": "raw", "path": "/", "host": None, "mode": None, "serviceName": "", "trustedXForwardedFor": []},
            "tls": {"enable": False, "certificateFile": None, "keyFile": None, "serverName": None},
            "reality": {"enable": False, "dest": "", "serverNames": [], "privateKey": None, "privateKeyFile": None, "publicKey": None, "shortIds": [""]},
            "xrayJson": None,
            "jsonFile": None,
        }
        spec = self.spec(listener, other)
        awg_inbound.prepare(spec, self.awg, self.runtime)
        rendered = build_inbounds(spec, "vpn.example.com")
        inbound = next(ib for ib in rendered["inbounds"] if ib["tag"] == "awg-in")
        self.assertEqual(inbound["protocol"], "tunnel")
        self.assertEqual((inbound["listen"], inbound["port"]), ("127.0.0.1", 18700))
        self.assertEqual(inbound["streamSettings"]["sockopt"]["tproxy"], "tproxy")
        self.assertTrue(inbound["settings"]["followRedirect"])

        awg_links = [link for link in rendered["links"] if link["tag"] == "awg-in"]
        self.assertEqual([link["user"] for link in awg_links], ["alice", "bob"])
        for link in awg_links:
            self.assertEqual(link["port"], 443)
            self.assertTrue(link["link"].startswith("vpn://"))
            self.assertIn("Endpoint = vpn.example.com:443", link["config"])
        # Subscriptions carry only what v2ray-style clients read.
        for subscription in rendered["subscriptions"]:
            body = base64.b64decode(subscription["body"]).decode()
            self.assertNotIn("vpn://", body)


class PeerCounterTests(Fixture):
    def test_counters_are_matched_to_users(self):
        listener = self.listener()
        spec = self.spec(listener, self.listener(tag="down", subnet="10.67.0.0/24"))
        awg_inbound.prepare(spec, self.awg, self.runtime)
        state = self.state(listener)
        alice = state["users"]["alice"]["publicKey"]
        bob = state["users"]["bob"]["publicKey"]
        dump = (
            "private\tpublic\t51820\toff\n"
            f"{alice}\tpsk\t203.0.113.5:40000\t10.66.0.2/32\t1790000000\t1000\t2000\t25\n"
            f"{bob}\tpsk\t(none)\t10.66.0.3/32\t0\t0\t0\t25\n"
            "stranger\t(none)\t(none)\t10.66.0.9/32\t0\t5\t5\toff\n"
        )
        os.environ["AWG_DUMP_awgi_awg_in"] = dump
        try:
            peers = awg_inbound.peer_counters(spec, self.awg)
        finally:
            del os.environ["AWG_DUMP_awgi_awg_in"]
        self.assertEqual(
            peers,
            [
                {"key": alice, "endpoint": "203.0.113.5:40000", "handshake": 1790000000, "rx": 1000, "tx": 2000, "interface": "awgi-awg-in", "tag": "awg-in", "user": "alice"},
                {"key": bob, "endpoint": None, "handshake": 0, "rx": 0, "tx": 0, "interface": "awgi-awg-in", "tag": "awg-in", "user": "bob"},
            ],
        )


if __name__ == "__main__":
    unittest.main()
