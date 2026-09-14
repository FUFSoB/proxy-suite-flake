#!/usr/bin/env python3
"""proxy_model without a front end: the status line and the tray menu turn state into the right proxy-ctl argv."""

import unittest
from unittest import mock

import proxy_ctl as ctl
import proxy_model as model


def walk(items):
    for item in items:
        yield item
        yield from walk(item.children)


class ModelTest(unittest.TestCase):
    def setUp(self):
        for name, value in {
            "_awg_profiles": lambda: ["home"],
            "_route_mode_current": lambda: "default",
            "_route_mode_default": lambda: "whitelist",
            "_route_mode_effective": lambda: "whitelist",
            "_status_outbound": lambda: "b (pinned)",
            "_status_autoproxy": lambda: "",
            "_status_zapret": lambda: "3",
            "_outbound_inventory": lambda: {"tags": ["a", "b"], "pinned": "b"},
        }.items():
            patcher = mock.patch.object(ctl, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def menu(self, states):
        snap = model.snapshot(states)
        return {i.id: i for i in walk(model.tray_menu(snap, model.tray_outbounds(snap)))}

    def test_status_items(self):
        states = {"proxy-suite-socks": "active", "proxy-suite-zapret": "failed"}
        items = model.status_items(states)
        self.assertEqual(items[0], ("", "Proxy only", "bad"))
        self.assertIn(("mode ", "whitelist (default)", ""), items)
        self.assertIn(("zapret ", "3 learned", ""), items)
        self.assertEqual(items[-1], ("", "1 failed", "bad"))
        self.assertEqual(model.status_items({})[0], ("", "Status unavailable", "bad"))

    def test_services_skip_the_subscription_update(self):
        rows = model.service_rows({"proxy-suite-socks": "active", ctl.SUBSCRIPTION_UPDATE: "inactive"})
        self.assertEqual([r["unit"] for r in rows], ["proxy-suite-socks"])

    def test_tray_menu(self):
        states = {
            "proxy-suite-socks": "active",
            "proxy-suite-tun": "inactive",
            "proxy-suite-zapret": "inactive",
            ctl.SUBSCRIPTION_UPDATE: "activating",
            ctl._awg_service("home"): "active",
        }
        items = self.menu(states)
        self.assertEqual(items["status"].label, "Proxy + traffic")
        self.assertEqual((items["proxy"].checked, items["proxy"].argv, items["proxy"].confirm), (True, ["proxy", "off"], True))
        self.assertEqual(items["tun"].argv, ["proxy", "tun", "on"])
        self.assertNotIn("tproxy", items)  # not installed
        self.assertTrue(items["mode-default"].checked)
        self.assertEqual(items["mode-blacklist"].argv, ["proxy", "mode", "blacklist"])
        self.assertEqual(items["pin"].label, "Outbound: b")
        self.assertTrue(items["pin-b"].checked)
        self.assertEqual(items["pin-a"].argv, ["proxy", "pin", "a"])
        self.assertEqual(items["pin-auto"].argv, ["proxy", "unpin"])
        self.assertTrue(items["awg-home"].checked)
        self.assertEqual(items["awg-off"].argv, ["awg", "off"])
        self.assertEqual(items["zapret"].argv, ["zapret", "on"])
        self.assertFalse(items["subs"].enabled)  # an update already runs
        self.assertEqual(items["quit"].app, "quit")

    def test_tray_menu_without_proxy(self):
        items = self.menu({"proxy-suite-zapret": "active"})
        self.assertEqual(items["status"].label, "Zapret only")
        for absent in ("proxy", "mode", "pin", "subs"):
            self.assertNotIn(absent, items)
        self.assertEqual(model.icon_name(ctl._overall_state(model.snapshot({"proxy-suite-zapret": "active"}))), "proxy-suite-zapret")

    def test_tray_menu_unreadable(self):
        self.assertEqual([i.id for i in model.tray_menu(None)], ["status", "open", "sep-0", "quit"])
        self.assertEqual(model.icon_name(ctl._overall_state(None)), "proxy-suite-disabled-unknown")

    def test_load_tab(self):
        tab = next(t for t in model.TABS if t.id == "outbounds")
        with mock.patch.object(ctl, "_outbound_current", lambda: "a"), mock.patch.object(ctl, "_reputation_by_tag", lambda: {}), mock.patch.object(ctl, "_runtime_tags", lambda kind: []):
            rows, summary = model.load_tab(tab, {})
        self.assertEqual([(r["tag"], r["mark"]) for r in rows], [("a", "▸"), ("b", "★")])
        self.assertIn("Pinned: b", summary)
        self.assertEqual([a.key for a in model.applicable(tab, rows[1])], ["u", "t", "T", "n"])
        broken = model.Tab("x", "X", model.ROW, [], lambda _: ctl.die("backend gone"))
        self.assertEqual(model.load_tab(broken, {}), ([], "✗ backend gone"))


if __name__ == "__main__":
    unittest.main()
