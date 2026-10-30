#!/usr/bin/env python3

import base64
import copy
import http.client
import importlib.util
import json
import os
import socket
import tempfile
import threading
import time
import unittest
import uuid
from unittest import mock

import inbound_apply
import inbound_manager as im
import inbound_subscription
import inbound_policy as policy
import inbound_runtime as rt

# The runtime tests' spec, spool and all.
_spec = importlib.util.spec_from_file_location("runtime_tests", os.path.join(os.path.dirname(__file__), "test-inbound-runtime.py"))
runtime_tests = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runtime_tests)


class FakeNetfilter:
    enabled = True

    def __init__(self):
        self.banned = []
        self.limits = None

    def ensure(self):
        return False

    def ban(self, ip, ports, seconds):
        self.banned.append((ip, sorted(ports), seconds))

    def bans(self):
        return [{"ip": ip, "port": port, "expires": seconds} for ip, ports, seconds in self.banned for port in ports]

    def unban(self, ip):
        found = [b for b in self.banned if b[0] == ip]
        self.banned = [b for b in self.banned if b[0] != ip]
        return len(found)

    def sync_limits(self, users, peers):
        self.limits = (users, peers)
        return True


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


class ManagerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = self.tmp.name
        self.spool = os.path.join(base, "spool")
        os.makedirs(self.spool)
        self.runtime_dir = os.path.join(base, "run")
        os.makedirs(self.runtime_dir)
        self.spec = runtime_tests.make_spec(self.spool)
        self.config = {
            "policyFile": os.path.join(base, "policy.json"),
            "stateFile": os.path.join(base, "state.json"),
            "statsFile": os.path.join(base, "stats.json"),
            "speedLimits": True,
            "slots": 4,
            "apply": {"runtimeDir": self.runtime_dir},
            "subscriptions": {"baseUrl": "https://vpn.example.com/sub", "profileTitle": "VPN {user}", "updateInterval": 12},
            "ipLimit": {"banSeconds": 300},
        }
        self.spec["manager"] = {k: self.config[k] for k in ("policyFile", "stateFile", "statsFile", "speedLimits")}
        self.clock = Clock(time.time())
        self.netfilter = FakeNetfilter()
        self.webhooks = im.Webhooks([])
        self.applies = []
        patcher = mock.patch.object(inbound_apply, "apply", side_effect=lambda config, spec: self.applies.append(spec) or [])
        patcher.start()
        self.addCleanup(patcher.stop)
        self.cut = mock.patch.object(inbound_apply, "cut").start()
        self.addCleanup(mock.patch.stopall)
        self.manager = im.Manager(self.config, self.spec, clock=self.clock, netfilter=self.netfilter, webhooks=self.webhooks)

    def tearDown(self):
        self.tmp.cleanup()

    def events(self, kind=None):
        return [(e["event"], e["user"]) for e in self.webhooks.sent if kind is None or e["event"] == kind]

    def write_stats(self, stats):
        policy.write_json(self.config["statsFile"], stats)

    def write_rendered(self, rendered):
        with open(os.path.join(self.runtime_dir, "rendered.json"), "w", encoding="utf-8") as handle:
            json.dump(rendered, handle)

    # --- users and policies -----------------------------------------------------------

    def test_create_a_user_with_a_policy(self):
        row = self.manager.create_user({"name": "alice", "listeners": ["vless-in"],
                                        "policy": {"trafficLimit": "10G", "expiresAt": "+30d", "speedLimit": "20M/5M"}})
        self.assertEqual(row["source"], "runtime")
        self.assertEqual(row["listeners"], ["vless-in"])
        self.assertEqual(row["policy"]["trafficLimit"], 10 * 1024**3)
        self.assertEqual(row["expiresAt"], int(self.clock.now) + 30 * 86400)
        self.assertEqual(row["level"], 1)
        self.assertTrue(row["active"])
        self.assertEqual(len(self.applies), 1)
        self.assertIn(("user.created", "alice"), self.events())
        with self.assertRaises(im.ApiError) as raised:
            self.manager.create_user({"name": "alice"})
        self.assertEqual(raised.exception.status, 409)

    def test_bad_policy_is_refused_before_anything_is_written(self):
        with self.assertRaises(im.ApiError) as raised:
            self.manager.create_user({"name": "zed", "policy": {"trafficLimit": "lots"}})
        self.assertEqual(raised.exception.status, 400)
        self.assertNotIn("zed", rt.load_spool(self.spool)[0]["users"])

    def test_declared_users_get_policies_too(self):
        row = self.manager.set_policy("bob", {"enabled": False})
        self.assertFalse(row["active"])
        self.assertEqual(row["reasons"], ["disabled"])
        self.assertEqual(row["stored"], {"enabled": False})
        row = self.manager.set_policy("bob", {}, unset=["enabled"])
        self.assertTrue(row["active"])
        self.assertEqual(policy.load_policies(self.config["policyFile"]), {})

    def test_disabling_reaches_the_renderers(self):
        self.manager.set_policy("bob", {"enabled": False})
        merged, _, _ = rt.merge(self.spec)
        vless = next(l for l in merged["listeners"] if l["tag"] == "vless-in")
        bob = next(u for u in vless["users"] if u["name"] == "bob")
        self.assertFalse(bob["active"])

    def test_extend_from_the_later_of_now_and_the_expiry(self):
        now = int(self.clock.now)
        self.manager.set_policy("bob", {"expiresAt": now + 86400})
        row = self.manager.extend("bob", by="30d")
        self.assertEqual(row["expiresAt"], now + 31 * 86400)
        self.manager.set_policy("bob", {"expiresAt": now - 86400})
        self.assertEqual(self.manager.extend("bob", by="1d")["expiresAt"], now + 86400)
        with self.assertRaises(im.ApiError):
            self.manager.extend("bob")

    def test_extend_with_a_reset_starts_the_traffic_over(self):
        today = policy.day_key(self.clock.now)
        self.manager.create_user({"name": "alice", "policy": {"trafficLimit": 100}})
        self.manager.tick()
        self.write_stats({"days": {today: {"user": {"alice": {"up": 60, "down": 60}}}}})
        self.manager.tick()
        self.assertEqual(self.manager.overview("alice")[0]["reasons"], ["traffic"])
        row = self.manager.extend("alice", by="30d", reset=True)
        self.assertTrue(row["active"])
        self.assertEqual(row["traffic"]["used"], 0)
        self.assertEqual(row["expiresAt"], int(self.clock.now) + 30 * 86400)
        self.assertIn(("user.reset", "alice"), self.events())

    def test_on_hold_starts_with_the_first_connection(self):
        today = policy.day_key(self.clock.now)
        row = self.manager.create_user({"name": "alice", "policy": {"expiresAfter": "30d"}})
        self.assertTrue(row["active"])
        self.assertTrue(row["onHold"])
        self.assertIsNone(row["expiresAt"])
        # Extended while on hold: the term grows, nothing starts.
        row = self.manager.extend("alice", by="5d")
        self.assertEqual(row["policy"]["expiresAfter"], 35 * 86400)
        self.assertTrue(row["onHold"])
        self.manager.tick()
        self.clock.now += 3 * 86400
        self.manager.tick()
        self.assertTrue(self.manager.overview("alice")[0]["onHold"])
        self.assertEqual(self.events("user.activated"), [])
        self.write_stats({"days": {today: {"user": {"alice": {"up": 1, "down": 2}}}}})
        self.manager.tick()
        row = self.manager.overview("alice")[0]
        self.assertFalse(row["onHold"])
        self.assertEqual(row["expiresAt"], int(self.clock.now) + 35 * 86400)
        self.assertEqual(self.events("user.activated"), [("user.activated", "alice")])
        self.manager.tick()
        self.assertEqual(len(self.events("user.activated")), 1)

    def test_on_hold_starts_when_seen_online(self):
        self.manager.create_user({"name": "alice", "policy": {"expiresAfter": "1d", "trafficLimit": "1G"}})
        self.manager.create_user({"name": "zed", "policy": {"expiresAfter": policy.MAX_TIME - 1, "trafficLimit": "1G"}})
        self.write_stats({"online": [{"email": name, "ips": [{"ip": "198.51.100.1"}]} for name in ("alice", "zed")]})
        self.manager.tick()
        self.assertEqual(self.manager.overview("alice")[0]["expiresAt"], int(self.clock.now) + 86400)
        # A term past the year 9999 ends just before it: the rest of the policy stays.
        zed = self.manager.overview("zed")[0]
        self.assertEqual(zed["expiresAt"], policy.MAX_TIME - 1)
        self.assertEqual(zed["policy"]["trafficLimit"], 1024**3)

    def test_expired_runtime_users_are_deleted_after_a_while(self):
        self.config["deleteExpiredAfter"] = "7d"
        now = int(self.clock.now)
        self.manager.create_user({"name": "alice", "policy": {"expiresAt": now + 86400}})
        self.manager.create_user({"name": "carol"})
        self.manager.set_policy("bob", {"expiresAt": now + 86400})
        self.clock.now += 7 * 86400
        self.manager.tick()
        self.assertIn("alice", self.manager.names())
        self.clock.now += 86400 + 1
        self.manager.tick()
        names = self.manager.names()
        self.assertNotIn("alice", names)
        # Declared in the config: kept. Never expires: kept.
        self.assertIn("bob", names)
        self.assertIn("carol", names)
        deleted = [e for e in self.webhooks.sent if e["event"] == "user.deleted"]
        self.assertEqual([(e["user"], e["data"]) for e in deleted], [("alice", {"reason": "expired"})])

    def test_delete_forgets_the_policy(self):
        self.manager.create_user({"name": "alice", "policy": {"ipLimit": 2}})
        self.manager.delete_user("alice")
        self.assertNotIn("alice", policy.load_policies(self.config["policyFile"]))
        with self.assertRaises(im.ApiError) as raised:
            self.manager.delete_user("bob")
        self.assertEqual(raised.exception.status, 409)

    def test_set_listeners(self):
        self.manager.create_user({"name": "alice", "listeners": ["vless-in"]})
        self.assertEqual(self.manager.set_listeners("alice", [])["listeners"], [])
        self.assertEqual(self.manager.set_listeners("alice", ["vless-in"])["listeners"], ["vless-in"])
        # A single-user shadowsocks listener takes no second user.
        with self.assertRaises(im.ApiError) as raised:
            self.manager.set_listeners("alice", ["ss-in"])
        self.assertEqual(raised.exception.status, 409)

    def test_slots_run_out(self):
        for name in ("a1", "a2", "a3", "a4"):
            self.manager.create_user({"name": name, "policy": {"speedLimit": "1M"}})
        with self.assertRaises(im.ApiError):
            self.manager.create_user({"name": "a5", "policy": {"speedLimit": "1M"}})
        # Refused whole: no user without the slot their policy needs.
        self.assertNotIn("a5", rt.load_spool(self.spool)[0]["users"])
        self.manager.create_user({"name": "a5"})
        with self.assertRaises(im.ApiError):
            self.manager.set_policy("a5", {"speedLimit": "1M"})
        self.assertNotIn("a5", self.manager.stored_policies())
        # A slot comes back when its user's limit goes.
        self.manager.set_policy("a1", {"speedLimit": None})
        self.manager.tick()
        self.assertNotIn("a1", self.manager.state()["slots"])
        self.manager.set_policy("a5", {"speedLimit": "1M"})
        self.assertIn("a5", self.manager.state()["slots"])

    # --- the tick ---------------------------------------------------------------------

    def test_traffic_runs_out_and_comes_back_with_the_period(self):
        today = policy.day_key(self.clock.now)
        self.manager.create_user({"name": "alice", "policy": {"trafficLimit": 1000, "trafficPeriod": "daily"}})
        self.manager.tick()
        self.write_stats({"days": {today: {"user": {"alice": {"up": 300, "down": 600}}}}})
        self.manager.tick()
        self.assertIn(("user.traffic", "alice"), self.events())
        self.assertTrue(self.manager.overview("alice")[0]["active"])
        self.write_stats({"days": {today: {"user": {"alice": {"up": 400, "down": 700}}}}})
        applies = len(self.applies)
        self.manager.tick()
        row = self.manager.overview("alice")[0]
        self.assertFalse(row["active"])
        self.assertEqual(row["reasons"], ["traffic"])
        self.assertEqual(len(self.applies), applies + 1)
        self.assertIn(("user.disabled", "alice"), self.events())
        self.assertEqual([e for e in self.events("user.traffic")], [("user.traffic", "alice")] * 2)
        # The next day: a new period.
        self.clock.now += 86400
        self.manager.tick()
        self.assertTrue(self.manager.overview("alice")[0]["active"])
        self.assertIn(("user.enabled", "alice"), self.events())

    def test_expiry_warnings_and_expiry(self):
        self.manager.create_user({"name": "alice", "policy": {"expiresAt": int(self.clock.now) + 2 * 86400}})
        self.manager.tick()
        self.assertEqual(self.events("user.expiring"), [("user.expiring", "alice")])
        self.manager.tick()
        self.assertEqual(len(self.events("user.expiring")), 1)
        self.clock.now += 2 * 86400 + 1
        self.manager.tick()
        self.assertEqual(self.manager.overview("alice")[0]["reasons"], ["expired"])
        self.assertIn(("user.disabled", "alice"), self.events())

    def test_ip_limit_bans_the_newest(self):
        self.manager.create_user({"name": "alice", "listeners": ["vless-in"], "policy": {"ipLimit": 1}})
        self.write_rendered({"inbounds": [
            {"tag": "vless-in", "listen": "::", "port": 443, "protocol": "vless", "settings": {"clients": [{"email": "alice"}]}},
            {"tag": "behind", "listen": "127.0.0.1", "port": 9000, "protocol": "vless", "settings": {"clients": [{"email": "alice"}]}},
        ]})
        self.write_stats({"online": [{"email": "alice", "ips": [{"ip": "198.51.100.1"}]}]})
        self.manager.tick()
        self.assertEqual(self.netfilter.banned, [])
        self.clock.now += 10
        self.write_stats({"online": [{"email": "alice", "ips": [{"ip": "198.51.100.1"}, {"ip": "203.0.113.9"}]}]})
        self.manager.tick()
        self.assertEqual(self.netfilter.banned, [("203.0.113.9", [443], 300)])
        self.assertTrue(self.cut.called)
        self.assertEqual(self.events("user.ip-limit"), [("user.ip-limit", "alice")])

    def test_speed_limits_follow_activity(self):
        self.manager.create_user({"name": "alice", "policy": {"speedLimit": "8M/2M"}})
        users, _ = self.netfilter.limits
        self.assertEqual(users, {1: {"up": 2_000_000, "down": 8_000_000}})
        self.manager.set_policy("alice", {"enabled": False})
        self.assertEqual(self.netfilter.limits[0], {})

    # --- subscriptions ----------------------------------------------------------------

    def test_subscription_headers(self):
        today = policy.day_key(self.clock.now)
        self.manager.create_user({"name": "alice", "policy": {"trafficLimit": 5000, "expiresAt": 2_000_000_000}})
        self.manager.tick()
        self.write_stats({"days": {today: {"user": {"alice": {"up": 10, "down": 20}}}}})
        self.write_rendered({"subscriptions": [{"user": "alice", "token": "a" * 32, "body": "Ym9keQ=="}]})
        body, headers = self.manager.subscription("a" * 32)
        self.assertEqual(body, b"Ym9keQ==")
        self.assertEqual(headers["subscription-userinfo"], "upload=10; download=20; total=5000; expire=2000000000")
        self.assertEqual(base64.b64decode(headers["profile-title"][len("base64:"):]).decode(), "VPN alice")
        self.assertEqual(headers["Content-Type"], "text/plain; charset=utf-8")
        self.assertEqual(headers["profile-update-interval"], "12")
        self.assertIsNone(self.manager.subscription("b" * 32))
        self.assertEqual(self.manager.overview("alice")[0]["subscription"]["url"], "https://vpn.example.com/sub/" + "a" * 32)

    def test_subscription_formats(self):
        self.manager.create_user({"name": "alice", "policy": {"expiresAfter": "30d"}})
        link = "trojan://pass@vpn.example.com:8443?security=tls&sni=vpn.example.com#tr"
        self.write_rendered({
            "subscriptions": [{"user": "alice", "token": "a" * 32, "body": base64.b64encode(link.encode()).decode()}],
            "links": [{"tag": "tr", "user": "alice", "link": link,
                       "outbound": {"type": "trojan", "tag": "tr", "server": "vpn.example.com", "server_port": 8443,
                                    "password": "pass", "tls": {"enabled": True, "server_name": "vpn.example.com"}}}],
        })
        body, headers = self.manager.subscription("a" * 32, user_agent="ClashMetaForAndroid/2.11")
        self.assertEqual(json.loads(body)["proxies"][0]["name"], "tr")
        self.assertIn("subscription-userinfo", headers)
        body, headers = self.manager.subscription("a" * 32, user_agent="Mozilla/5.0", accept="text/html",
                                                  accept_language="ru")
        self.assertEqual(headers["Content-Type"], "text/html; charset=utf-8")
        self.assertEqual(headers["Referrer-Policy"], "no-referrer")
        self.assertEqual(headers["Content-Security-Policy"], inbound_subscription.PAGE_HEADERS["Content-Security-Policy"])
        self.assertNotIn("content-disposition", headers)
        page = body.decode()
        self.assertIn("Начнётся с первого подключения", page)
        # baseUrl wins over the address asked at: it is what clients are given.
        self.assertIn("https://vpn.example.com/sub/" + "a" * 32, page)
        body, headers = self.manager.subscription("a" * 32, fmt="links")
        self.assertEqual(body.decode().strip(), link)
        # Every format: not cached, sniffed, sent on or indexed; the page's CSP on the page only.
        self.assertEqual({k: headers[k] for k in inbound_subscription.HEADERS}, inbound_subscription.HEADERS)
        self.assertNotIn("Content-Security-Policy", headers)

    def test_rotate_subscription(self):
        self.manager.create_user({"name": "alice", "listeners": ["vless-in"]})
        merged, _, _ = rt.merge(self.spec)
        self.assertEqual(merged["subscriptionSalts"], {})
        status, _ = im.handle_api(self.manager, "POST", "/api/v1/users/alice/rotate-subscription", {}, None)
        self.assertEqual(status, 200)
        salt = policy.load_state(self.config["stateFile"])["subscriptions"]["alice"]
        self.assertTrue(policy.is_subscription_salt(salt))
        # The renderers take it (proxy_inbound.subscription_token), on the apply it asked for.
        self.assertEqual(rt.merge(self.spec)[0]["subscriptionSalts"], {"alice": salt})
        self.assertEqual(self.applies[-1], self.spec)
        self.assertEqual(self.webhooks.sent[-1]["data"], {"subscription": "rotated"})
        self.manager.rotate_subscription("alice")
        self.assertNotEqual(policy.load_state(self.config["stateFile"])["subscriptions"]["alice"], salt)
        with self.assertRaises(im.ApiError) as raised:
            self.manager.rotate_subscription("nobody")
        self.assertEqual(raised.exception.status, 404)
        # It travels with an export; a deleted user's goes with them.
        bundle = self.manager.export()
        self.assertIn("alice", bundle["state"]["subscriptions"])
        self.manager.delete_user("alice")
        self.assertNotIn("alice", policy.load_state(self.config["stateFile"])["subscriptions"])
        self.manager.import_bundle(bundle)
        self.assertEqual(policy.load_state(self.config["stateFile"])["subscriptions"]["alice"],
                         bundle["state"]["subscriptions"]["alice"])
        with self.assertRaises(im.ApiError):
            self.manager.import_bundle({**bundle, "state": {"subscriptions": {"alice": "../x"}}})
        # A salt that does not hold up is left out.
        state = policy.load_state(self.config["stateFile"])
        state["subscriptions"]["bob"] = "short"
        policy.write_json(self.config["stateFile"], state)
        self.assertNotIn("bob", policy.load_state(self.config["stateFile"])["subscriptions"])

    def test_misses_are_logged_sparingly(self):
        clock = Clock(1000.0)
        misses = im.Misses(every=60, clock=clock)
        with mock.patch.object(im, "_log") as log:
            for _ in range(5):
                misses.note("203.0.113.7")
            misses.note("198.51.100.1")
            clock.now += 61
            misses.note("203.0.113.7")
        self.assertEqual([c.args[0] for c in log.call_args_list], [
            "subscription: unknown token from 203.0.113.7",
            "subscription: unknown token from 198.51.100.1",
            "subscription: unknown token from 203.0.113.7 (4 more since the last line)",
        ])

    # --- export and import ------------------------------------------------------------

    def test_export_and_import_into_an_empty_server(self):
        self.manager.create_user({"name": "alice", "listeners": ["vless-in"], "policy": {"trafficLimit": "1G"}})
        self.write_stats({"days": {"2026-10-01": {"user": {"alice": {"up": 1, "down": 2}}}}})
        awg_state = os.path.join(self.tmp.name, "awg.json")
        self.spec["listeners"][2]["amneziaWg"] = {"stateFile": awg_state, "interfaceName": "awgi-awg", "subnet": "10.66.0.0/24"}
        server_key = base64.b64encode(b"S" * 32).decode()
        policy.write_json(awg_state, {"version": 1, "server": {"publicKey": server_key}, "users": {"bob": {"offset": 2}}})
        bundle = json.loads(json.dumps(self.manager.export()))
        self.assertEqual(sorted(bundle["runtime"]["users"]), ["alice"])
        self.assertEqual(bundle["amneziaWg"]["awg"]["server"]["publicKey"], server_key)

        other = tempfile.TemporaryDirectory()
        self.addCleanup(other.cleanup)
        spool = os.path.join(other.name, "spool")
        os.makedirs(spool)
        spec = runtime_tests.make_spec(spool)
        spec["listeners"][2]["amneziaWg"] = {"stateFile": os.path.join(other.name, "awg.json"), "interfaceName": "awgi-awg", "subnet": "10.66.0.0/24"}
        config = copy.deepcopy(self.config)
        for key in ("policyFile", "stateFile", "statsFile"):
            config[key] = os.path.join(other.name, os.path.basename(config[key]))
        spec["manager"] = {k: config[k] for k in ("policyFile", "stateFile", "statsFile", "speedLimits")}
        target = im.Manager(config, spec, clock=self.clock, netfilter=FakeNetfilter(), webhooks=im.Webhooks([]))
        report = target.import_bundle(bundle)
        self.assertEqual(report["users"], ["alice"])
        self.assertEqual(report["amneziaWg"], ["awg"])
        row = target.overview("alice")[0]
        self.assertEqual(row["policy"]["trafficLimit"], 1024**3)
        self.assertEqual(rt.load_spool(spool)[0]["users"]["alice"]["uuid"], rt.load_spool(self.spool)[0]["users"]["alice"]["uuid"])
        self.assertEqual(policy.read_stats(config["statsFile"])["days"]["2026-10-01"]["user"]["alice"], {"up": 1, "down": 2})
        with self.assertRaises(im.ApiError) as raised:
            target.import_bundle(bundle)
        self.assertEqual(raised.exception.status, 409)
        self.assertEqual(target.import_bundle(bundle, replace=True)["users"], ["alice"])

    def test_the_generated_subscription_key_travels(self):
        key_path = os.path.join(self.tmp.name, "inbounds", "subscription-key")
        self.spec["subscriptionKeyStateFile"] = key_path
        self.assertIsNone(self.manager.export()["subscriptionKey"])
        os.makedirs(os.path.dirname(key_path))
        with open(key_path, "w", encoding="utf-8") as handle:
            handle.write("e" * 64 + "\n")
        bundle = self.manager.export()
        self.assertEqual(bundle["subscriptionKey"], "e" * 64)
        # A key the config names is the config's: not exported.
        named = im.Manager(self.config, {**self.spec, "subscriptionKeyFile": "/run/secrets/k"}, netfilter=FakeNetfilter())
        self.assertIsNone(named.export()["subscriptionKey"])

        other = tempfile.TemporaryDirectory()
        self.addCleanup(other.cleanup)
        target_path = os.path.join(other.name, "inbounds", "subscription-key")
        target = im.Manager(self.config, {**self.spec, "subscriptionKeyStateFile": target_path},
                            clock=self.clock, netfilter=FakeNetfilter(), webhooks=im.Webhooks([]))
        report = {"skipped": []}
        target._import_subscription_key(bundle["subscriptionKey"], False, report)
        self.assertTrue(report["subscriptionKey"])
        with open(target_path, encoding="utf-8") as handle:
            self.assertEqual(handle.read().strip(), "e" * 64)
        self.assertEqual(os.stat(target_path).st_mode & 0o777, 0o600)
        # One of its own already: kept, unless replace.
        report = {"skipped": []}
        target._import_subscription_key("f" * 64, False, report)
        self.assertIn("kept this server's", report["skipped"][0])
        target._import_subscription_key("f" * 64, True, report)
        with open(target_path, encoding="utf-8") as handle:
            self.assertEqual(handle.read().strip(), "f" * 64)
        # None to keep it in: said so.
        report = {"skipped": []}
        im.Manager(self.config, {**self.spec, "subscriptionKeyStateFile": None},
                   netfilter=FakeNetfilter())._import_subscription_key("f" * 64, False, report)
        self.assertIn("keyFile is false", report["skipped"][0])
        with self.assertRaises(im.ApiError):
            self.manager.import_bundle({**bundle, "subscriptionKey": "short\nline"})

    def test_import_refuses_garbage(self):
        for bad in (None, {}, {"format": "x"}, {"format": im.BUNDLE_FORMAT, "version": 99}):
            with self.assertRaises(im.ApiError):
                self.manager.import_bundle(bad)
        bundle = self.manager.export()
        bundle["runtime"]["users"]["evil"] = {"order": 1, "uuid": "nope", "password": "x"}
        with self.assertRaises(im.ApiError) as raised:
            self.manager.import_bundle(bundle)
        self.assertEqual(raised.exception.status, 400)

    def test_import_refuses_what_would_escape_or_break_its_files(self):
        clean = self.manager.export()
        awg_state = os.path.join(self.tmp.name, "awg.json")
        self.spec["listeners"][2]["amneziaWg"] = {"stateFile": awg_state, "interfaceName": "awgi-awg", "subnet": "10.66.0.0/24"}
        key = base64.b64encode(b"k" * 32).decode()
        bad_parts = [
            # A tag is a directory under the Salamander state: not a way out of it.
            ("salamander", {"../../escape": "password"}),
            ("salamander", {"hy2": "two\nlines"}),
            # A key with a line break would add a line (PostUp = ...) to what awg-quick runs.
            ("amneziaWg", {"awg": {"version": 1, "server": {"privateKey": key + "\nPostUp = touch /x"}, "users": {}}}),
            ("amneziaWg", {"awg": {"version": 1, "server": {}, "users": {"bob": {"offset": 2, "presharedKey": "short"}}}}),
            # A state of another version: its keys would be made anew.
            ("amneziaWg", {"awg": {"server": {"privateKey": key}, "users": {}}}),
            # The renderers and the collector read these at every start and run.
            ("state", {"users": {"alice": {"periodStart": "yesterday"}}, "slots": {}}),
            ("stats", {"days": {"2026-10-01": {"user": {"alice": {"up": "lots"}}}}}),
        ]
        for section, value in bad_parts:
            bundle = copy.deepcopy(clean)
            bundle[section] = value
            with self.subTest(section=section, value=value), self.assertRaises(im.ApiError) as raised:
                self.manager.import_bundle(bundle)
            self.assertEqual(raised.exception.status, 400)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "escape")))
        self.assertFalse(os.path.exists(awg_state))

    def test_import_takes_declared_names_outside_the_runtime_pattern(self):
        # Declared tags and user names are any string; only a path made of one is checked.
        awg_state = os.path.join(self.tmp.name, "awg.json")
        salamander_file = os.path.join(self.tmp.name, "declared-salamander")
        self.spec["listeners"][2]["amneziaWg"] = {"stateFile": awg_state, "interfaceName": "awgi-awg", "subnet": "10.66.0.0/24"}
        self.spec["listeners"][0]["salamanderStateFile"] = salamander_file
        tag = self.spec["listeners"][0]["tag"]
        bundle = self.manager.export()
        bundle["amneziaWg"] = {"awg": {"version": 1, "server": {}, "users": {"bob smith": {"offset": 3}}}}
        bundle["salamander"] = {tag: "secret-password"}
        report = self.manager.import_bundle(bundle)
        self.assertEqual(report["amneziaWg"], ["awg"])
        self.assertEqual(report["salamander"], [tag])
        with open(salamander_file, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "secret-password\n")

    def test_generated_keys_travel_with_the_bundle(self):
        listener = self.spec["listeners"][0]
        tag = listener["tag"]
        listener["encryptionStateFile"] = os.path.join(self.tmp.name, "declared", "vless-encryption-key")
        os.makedirs(os.path.join(self.tmp.name, "declared"))
        with open(listener["encryptionStateFile"] + ".x25519", "w", encoding="utf-8") as handle:
            handle.write("uFStM_0LKZjQECFmgDDInScNCEN7EgwOd6CY1i_BJVE\n")
        bundle = self.manager.export()
        self.assertEqual(bundle["keys"], {tag: {"vless-encryption-key.x25519": "uFStM_0LKZjQECFmgDDInScNCEN7EgwOd6CY1i_BJVE"}})
        os.unlink(listener["encryptionStateFile"] + ".x25519")
        report = self.manager.import_bundle(bundle)
        self.assertEqual(report["keys"], [f"{tag}/vless-encryption-key.x25519"])
        with open(listener["encryptionStateFile"] + ".x25519", encoding="utf-8") as handle:
            self.assertEqual(handle.read().strip(), "uFStM_0LKZjQECFmgDDInScNCEN7EgwOd6CY1i_BJVE")
        for keys in ({tag: {"../escape": "k"}}, {tag: {"shadowsocks-server-key": "two\nlines"}}, {"../x": {}}):
            with self.subTest(keys=keys), self.assertRaises(im.ApiError):
                self.manager.import_bundle({**bundle, "keys": keys})

    def test_import_refuses_a_runtime_user_named_as_a_declared_one(self):
        bundle = self.manager.export()
        declared = sorted(self.spec["users"])[0]
        bundle["runtime"]["users"][declared] = {"order": 900, "uuid": str(uuid.uuid4()), "password": "x" * 16}
        with self.assertRaises(im.ApiError) as raised:
            self.manager.import_bundle(bundle)
        self.assertEqual(raised.exception.status, 409)
        self.assertNotIn(declared, rt.load_spool(self.spool)[0]["users"])

    def test_a_malformed_state_entry_is_left_out(self):
        policy.write_json(self.config["stateFile"], {"users": {"alice": {"periodStart": "x"}, "bob": {"periodStart": 5}},
                                                     "slots": {"alice": "1", "bob": 2}})
        state = policy.load_state(self.config["stateFile"])
        self.assertEqual(state["users"], {"bob": {"periodStart": 5}})
        self.assertEqual(state["slots"], {"bob": 2})


class Api(ManagerTest):
    def test_routes(self):
        status, value = im.handle_api(self.manager, "POST", "/api/v1/users", {}, {"name": "alice", "policy": {"ipLimit": 2}})
        self.assertEqual(status, 201)
        self.assertEqual(value["policy"]["ipLimit"], 2)
        status, value = im.handle_api(self.manager, "PATCH", "/api/v1/users/alice", {}, {"trafficLimit": "1G", "unset": ["ipLimit"]})
        self.assertIsNone(value["policy"]["ipLimit"])
        status, value = im.handle_api(self.manager, "POST", "/api/v1/users/alice/disable", {}, None)
        self.assertFalse(value["active"])
        with self.assertRaises(im.ApiError) as raised:
            im.handle_api(self.manager, "PUT", "/api/v1/users/alice", {}, {})
        self.assertEqual(raised.exception.status, 405)
        with self.assertRaises(im.ApiError) as raised:
            im.handle_api(self.manager, "GET", "/api/v1/users/nobody", {}, None)
        self.assertEqual(raised.exception.status, 404)

    def request(self, path, method="GET", body=None, headers=None, sock=None):
        connection = http.client.HTTPConnection("localhost")
        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.sock.connect(sock)
        payload = body if isinstance(body, bytes) or body is None else json.dumps(body).encode()
        connection.request(method, path, body=payload, headers=headers or {})
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()

    def test_over_the_sockets(self):
        api_socket = os.path.join(self.tmp.name, "api.sock")
        sub_socket = os.path.join(self.tmp.name, "sub.sock")
        misses = mock.Mock()
        servers = [im.unix_server(api_socket, im._handler(self.manager, "api", []), None, 0o600),
                   im.unix_server(sub_socket, im._handler(self.manager, "sub", [], misses), None, 0o600)]
        for server in servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.shutdown)
        status, _, body = self.request("/api/v1/users", "POST", {"name": "alice"}, sock=api_socket)
        self.assertEqual(status, 201, body)
        status, _, body = self.request("/api/v1/users/alice", sock=api_socket)
        self.assertEqual(json.loads(body)["name"], "alice")
        status, _, body = self.request("/api/v1/users", "POST", b"x", sock=api_socket)
        self.assertEqual(status, 400)
        # The subscription socket answers subscriptions only.
        self.write_rendered({"subscriptions": [{"user": "alice", "token": "c" * 32, "body": "eA=="}]})
        status, headers, body = self.request("/sub/" + "c" * 32, sock=sub_socket)
        self.assertEqual((status, body), (200, b"eA=="))
        self.assertIn("subscription-userinfo", {k.lower() for k in headers})
        status, headers, _ = self.request("/api/v1/users", sock=sub_socket)
        self.assertEqual(status, 404)
        self.assertEqual(headers.get("X-Content-Type-Options"), "nosniff")
        # A miss is noted by the address the web server says it came from, when that is one.
        self.request("/sub/" + "d" * 32, sock=sub_socket, headers={"X-Real-IP": "203.0.113.7"})
        self.request("/sub/" + "d" * 32, sock=sub_socket, headers={"X-Forwarded-For": "10.0.0.1, 198.51.100.1"})
        self.request("/sub/" + "d" * 32, sock=sub_socket, headers={"X-Real-IP": "forged words"})
        self.assertEqual([c.args[0] for c in misses.note.call_args_list][-3:], ["203.0.113.7", "198.51.100.1", "unix"])
        # The format from the query or the client; a page that names the address it was asked at.
        status, headers, body = self.request("/sub/" + "c" * 32 + "?format=sing-box", sock=sub_socket)
        self.assertEqual(json.loads(body)["route"]["final"], "direct")
        del self.config["subscriptions"]["baseUrl"]
        status, headers, body = self.request("/sub/" + "c" * 32, sock=sub_socket, headers={
            "User-Agent": "Mozilla/5.0", "Accept": "text/html", "Host": "vpn.example.org", "X-Forwarded-Proto": "https"})
        self.assertEqual(status, 200)
        self.assertIn("https://vpn.example.org/sub/" + "c" * 32, body.decode())
        status, headers, body = self.request("/sub/" + "c" * 32, sock=sub_socket, headers={
            "User-Agent": "Mozilla/5.0", "Accept": "text/html", "Host": "evil\"><script>"})
        self.assertNotIn("evil", body.decode())

    def test_tokens(self):
        path = os.path.join(self.tmp.name, "tokens")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("# bots\nbot:s3cret\nplain\n")
        self.assertEqual(im.read_tokens(path), [b"s3cret", b"plain"])


if __name__ == "__main__":
    unittest.main()
