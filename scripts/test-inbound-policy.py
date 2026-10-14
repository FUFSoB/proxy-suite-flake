#!/usr/bin/env python3

import datetime
import json
import os
import tempfile
import time
import unittest

import inbound_policy as policy
import inbound_runtime as rt
from proxy_inbound import render_xray_inbound


def midnight(year, month, day):
    return int(time.mktime(datetime.date(year, month, day).timetuple()))


class Parsing(unittest.TestCase):
    def test_sizes_are_binary(self):
        self.assertEqual(policy.parse_size("50G"), 50 * 1024**3)
        self.assertEqual(policy.parse_size("1.5T"), int(1.5 * 1024**4))
        self.assertEqual(policy.parse_size("512MiB"), 512 * 1024**2)
        self.assertEqual(policy.parse_size(1000), 1000)
        for none in (None, 0, "", "none", "unlimited", "0"):
            self.assertIsNone(policy.parse_size(none))
        for bad in ("lots", "-5G", -1, 1.5, "5X"):
            with self.assertRaises(policy.PolicyError):
                policy.parse_size(bad)

    def test_rates_are_decimal_bits(self):
        self.assertEqual(policy.parse_rate("10M"), 10_000_000)
        self.assertEqual(policy.parse_rate("500k"), 500_000)
        self.assertEqual(policy.parse_rate("1Gbit"), 1_000_000_000)
        self.assertIsNone(policy.parse_rate("0"))

    def test_speed_forms(self):
        self.assertEqual(policy.parse_speed("20M"), {"up": 20_000_000, "down": 20_000_000})
        self.assertEqual(policy.parse_speed("20M/5M"), {"up": 5_000_000, "down": 20_000_000})
        self.assertEqual(policy.parse_speed({"down": "8M"}), {"up": None, "down": 8_000_000})
        self.assertIsNone(policy.parse_speed("0/0"))
        with self.assertRaises(policy.PolicyError):
            policy.parse_speed({"sideways": "1M"})

    def test_times(self):
        now = 1_800_000_000
        self.assertEqual(policy.parse_time("+30d", now), now + 30 * 86400)
        self.assertEqual(policy.parse_time("+2h", now), now + 7200)
        # A date is the end of that day.
        self.assertEqual(policy.parse_time("2026-12-31"), midnight(2027, 1, 1))
        self.assertEqual(policy.parse_time("2026-12-31T00:00:00+00:00"), 1798675200)
        self.assertEqual(policy.parse_time(str(now)), now)
        self.assertIsNone(policy.parse_time("never"))
        with self.assertRaises(policy.PolicyError):
            policy.parse_time("next tuesday")


class Policies(unittest.TestCase):
    def test_normalize_and_store_round_trip(self):
        fields = policy.normalize(
            {"trafficLimit": "10G", "speedLimit": "10M/2M", "ipLimit": "2", "trafficPeriod": "monthly",
             "meta": {"telegram": "42"}, "enabled": False, "expiresAt": "+1d"},
            now=1_800_000_000,
        )
        self.assertEqual(fields["trafficLimit"], 10 * 1024**3)
        self.assertEqual(fields["ipLimit"], 2)
        self.assertEqual(fields["expiresAt"], 1_800_086_400)
        self.assertEqual(policy.check_stored(fields), fields)
        self.assertIsNone(policy.normalize({"expiresAt": 0})["expiresAt"])

    def test_unknown_and_bad_fields(self):
        for bad in ({"colour": "red"}, {"enabled": "yes"}, {"trafficPeriod": "yearly"}, {"ipLimit": -1},
                    {"meta": {"a b": "x"}}, {"meta": {"k": 5}}):
            with self.assertRaises(policy.PolicyError, msg=bad):
                policy.normalize(bad)

    def test_stored_overrides_declared_field_by_field(self):
        declared = {"trafficLimit": 100, "ipLimit": 3}
        stored = {"ipLimit": None, "enabled": False}
        merged = policy.effective(declared, stored)
        self.assertEqual(merged["trafficLimit"], 100)
        self.assertIsNone(merged["ipLimit"])
        self.assertFalse(merged["enabled"])

    def test_declared_nulls_do_not_override(self):
        spec = {"users": {"phone": {"policy": {"trafficLimit": None, "ipLimit": 2, "expiresAt": None}}}}
        self.assertEqual(policy.declared_policies(spec), {"phone": {"ipLimit": 2}})


class Traffic(unittest.TestCase):
    STATS = {
        "days": {
            "2026-10-01": {"user": {"a": {"up": 10, "down": 90}, "b": {"up": 1, "down": 1}}},
            "2026-10-02": {"user": {"a": {"up": 5, "down": 5}}},
        }
    }

    def test_usage_from_period_start_less_baseline(self):
        start = midnight(2026, 10, 1) + 3600
        self.assertEqual(policy.used_bytes(self.STATS, {"periodStart": start, "baselineUp": 10, "baselineDown": 30}, "a"), 70)
        self.assertEqual(policy.period_traffic(self.STATS, {"periodStart": start, "baselineDown": 30}, "a"), (15, 65))
        self.assertEqual(policy.used_bytes(self.STATS, {"periodStart": midnight(2026, 10, 2)}, "a"), 10)
        # Not measured yet: the history before the manager saw the user does not count.
        self.assertEqual(policy.used_bytes(self.STATS, {}, "a"), 0)
        self.assertEqual(policy.used_bytes(self.STATS, {"periodStart": 1, "baselineUp": 500, "baselineDown": 500}, "a"), 0)

    def test_start_period_takes_the_day_so_far(self):
        now = midnight(2026, 10, 1) + 7200
        state = policy.start_period(self.STATS, "a", now)
        self.assertEqual((state["baselineUp"], state["baselineDown"]), (10, 90))
        self.assertEqual(policy.used_bytes(self.STATS, state, "a"), 10)

    def test_monthly_periods_renew_at_midnight_on_the_anchor_day(self):
        state = {"periodStart": midnight(2026, 1, 31) + 5000, "baselineUp": 7, "anchorDay": 31}
        pol = {"trafficPeriod": "monthly"}
        self.assertEqual(policy.period_end(pol, state), midnight(2026, 2, 28))
        self.assertTrue(policy.roll_period(pol, state, midnight(2026, 3, 5)))
        # Feb 28, then Mar 31 is still ahead: the anchor day survives the short month.
        self.assertEqual(state["periodStart"], midnight(2026, 2, 28))
        self.assertEqual(state["baselineUp"], 0)
        self.assertEqual(policy.period_end(pol, state), midnight(2026, 3, 31))
        self.assertFalse(policy.roll_period(pol, state, midnight(2026, 3, 6)))

    def test_no_period_never_rolls(self):
        state = {"periodStart": 1, "baselineUp": 3}
        self.assertFalse(policy.roll_period({"trafficPeriod": None}, state, time.time()))
        self.assertEqual(state["baselineUp"], 3)

    def test_durations(self):
        self.assertEqual(policy.parse_duration("30d"), 30 * 86400)
        self.assertEqual(policy.parse_duration("+12h"), 12 * 3600)
        self.assertEqual(policy.parse_duration(90), 90)
        for none in (None, 0, "", "none", "0d"):
            self.assertIsNone(policy.parse_duration(none))
        for bad in ("30 days", "-1d", -5, 1.5):
            with self.assertRaises(policy.PolicyError):
                policy.parse_duration(bad)
        self.assertEqual(policy.normalize({"expiresAfter": "1w"}), {"expiresAfter": 7 * 86400})
        policy.check_stored({"expiresAfter": 604800})

    def test_on_hold_until_an_expiry_is_set(self):
        self.assertTrue(policy.on_hold(policy.effective({"expiresAfter": 86400}, None)))
        # A term started, or an expiry given by hand: no longer on hold.
        self.assertFalse(policy.on_hold(policy.effective({"expiresAfter": 86400}, {"expiresAt": 2_000_000_000})))
        self.assertFalse(policy.on_hold(policy.effective(None, None)))
        self.assertTrue(policy.status(policy.effective({"expiresAfter": 86400}, None), 0, 2_000_000_000)["active"])

    def test_status_reasons(self):
        now = 2_000_000_000
        self.assertEqual(policy.status(policy.effective(None, None), 10**12, now), {"active": True, "reasons": []})
        pol = policy.effective({"trafficLimit": 100, "expiresAt": now - 1}, {"enabled": False})
        self.assertEqual(policy.status(pol, 100, now)["reasons"], ["disabled", "expired", "traffic"])
        self.assertTrue(policy.status(policy.effective({"trafficLimit": 100}, None), 99, now)["active"])


class Statuses(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        base = self.dir.name
        self.manager = {
            "policyFile": os.path.join(base, "policy.json"),
            "stateFile": os.path.join(base, "state.json"),
            "statsFile": os.path.join(base, "stats.json"),
            "speedLimits": True,
        }

    def tearDown(self):
        self.dir.cleanup()

    def write(self, key, value):
        with open(self.manager[key], "w", encoding="utf-8") as handle:
            json.dump(value, handle)

    def test_without_the_manager_nothing_changes(self):
        self.assertEqual(policy.statuses({"users": {"a": {}}}, []), {})

    def test_statuses_from_the_files(self):
        now = time.time()
        today = policy.day_key(now)
        self.write("policyFile", {"users": {"rt": {"trafficLimit": 50}, "phone": {"speedLimit": {"up": 1000, "down": 1000}}}})
        self.write("stateFile", {"users": {"rt": {"periodStart": int(now) - 60}}, "slots": {"phone": 3, "rt": 4}})
        self.write("statsFile", {"days": {today: {"user": {"rt": {"up": 30, "down": 30}}}}})
        spec = {"manager": self.manager, "users": {"phone": {"policy": {"expiresAt": None}}}}
        views = policy.statuses(spec, ["rt"], now)
        self.assertEqual(views["rt"], {"active": False, "reasons": ["traffic"], "level": 0})
        self.assertEqual(views["phone"], {"active": True, "reasons": [], "level": 3})

    def test_a_broken_policy_file_is_no_policy(self):
        with open(self.manager["policyFile"], "w", encoding="utf-8") as handle:
            handle.write("{nope")
        spec = {"manager": self.manager, "users": {"a": {}}}
        self.assertTrue(policy.statuses(spec, [])["a"]["active"])


def listener(tag, kind, users, **extra):
    base = {"tag": tag, "type": kind, "port": 443, "listen": "::", "via": "direct", "users": users,
            "flow": None, "fallbacks": [], "transport": {"type": "raw", "path": "/"},
            "tls": {"enable": False}, "reality": {"enable": False}, "hysteria": {}}
    base.update(extra)
    return base


def user(name, **fields):
    return {"name": name, "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "password": "pw-" + name, **fields}


class MergeWithStatuses(unittest.TestCase):
    def spec(self):
        return {
            "runtime": None,
            "users": {},
            "listeners": [
                listener("vl", "vless", [user("a"), user("b")]),
                listener("sk", "socks", [user("a")]),
                listener("ss", "shadowsocks", [user("b")], method="aes-128-gcm"),
            ],
        }

    def test_inactive_users_leave_xray_but_listeners_that_can_stay_do(self):
        statuses = {"a": {"active": False, "level": 0}, "b": {"active": True, "level": 7}}
        merged, _, warnings = rt.merge_state(self.spec(), {"users": {}, "listeners": {}}, statuses=statuses)
        tags = [l["tag"] for l in merged["listeners"]]
        self.assertEqual(tags, ["vl", "ss"])
        self.assertIn("listener 'sk' has no active users; not started", warnings)
        inbound = render_xray_inbound(merged["listeners"][0])
        self.assertEqual([(c["email"], c.get("level")) for c in inbound["settings"]["clients"]], [("b", 7)])
        ss = render_xray_inbound(merged["listeners"][1])
        self.assertEqual(ss["settings"]["level"], 7)

    def test_a_vless_listener_with_everyone_off_runs_empty(self):
        statuses = {"a": {"active": False}, "b": {"active": False}}
        merged, _, _ = rt.merge_state(self.spec(), {"users": {}, "listeners": {}}, statuses=statuses)
        vl = next(l for l in merged["listeners"] if l["tag"] == "vl")
        self.assertEqual(render_xray_inbound(vl)["settings"]["clients"], [])

    def test_no_statuses_keeps_everyone(self):
        merged, _, warnings = rt.merge_state(self.spec(), {"users": {}, "listeners": {}})
        self.assertEqual(len(merged["listeners"]), 3)
        self.assertEqual(warnings, [])
        self.assertTrue(all(u["active"] for l in merged["listeners"] for u in l["users"]))


if __name__ == "__main__":
    unittest.main()
