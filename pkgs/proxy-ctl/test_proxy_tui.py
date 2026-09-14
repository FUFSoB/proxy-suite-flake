#!/usr/bin/env python3
"""Headless proxy-tui: arrows, the action menu and shortcuts turn into the right proxy-ctl argv."""

import asyncio
import unittest
from unittest import mock

import proxy_ctl as ctl
import proxy_tui as tui


class TuiTest(unittest.TestCase):
    def setUp(self):
        self.units = {"proxy-suite-socks": "active", "proxy-suite-tun": "inactive"}
        self.zapret = {
            "zapret-hosts-auto.txt": ["learned.example"],
            "zapret-hosts-user.txt": [],
            "zapret-hosts-user-exclude.txt": ["kept.example"],
        }
        env = {"ZAPRET_AUTO_ENABLED": "1"}
        for target, name, value in [
            (tui, "unit_states", lambda units: {u: s for u, s in self.units.items() if u in units}),
            (tui, "_capture", lambda argv: ""),
            (tui, "_lines", lambda name: self.zapret[name]),
            (ctl, "env", lambda name, default="": env.get(name, default)),
            (ctl, "_awg_profiles", lambda: []),
            (ctl, "_route_mode_current", lambda: "default"),
            (ctl, "_route_mode_effective", lambda: "whitelist"),
            (ctl, "_outbound_inventory", lambda: {"tags": ["a", "b"], "pinned": "b", "sources": {"a": "config"}}),
            (ctl, "_outbound_current", lambda: ""),
            (ctl, "_reputation_by_tag", lambda: {}),
            (ctl, "_runtime_tags", lambda kind: []),
            (ctl, "_sub_tags", lambda: []),
            (ctl, "_status_outbound", lambda: "b (pinned)"),
            (ctl, "_status_autoproxy", lambda: ""),
            (ctl, "_status_zapret", lambda: ""),
        ]:
            patcher = mock.patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.ran = []
        patcher = mock.patch.object(tui.ProxyTui, "run_argv", lambda app, mode, argv: self.ran.append(argv))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_ui(self):
        # Not IsolatedAsyncioTestCase: its asyncio debug mode makes Textual crawl.
        asyncio.run(self.ui())

    async def settle(self, app, pilot):
        # Loads are exclusive: a newer one cancels the older, so wait until none runs.
        await pilot.pause()
        while any(not w.is_finished for w in app.workers if w.group == "load"):
            await pilot.pause(0.01)
        await pilot.pause()

    def menu_labels(self, app):
        return [a.label for a in app.screen.actions]

    async def ui(self):
        app = tui.ProxyTui()
        async with app.run_test(size=(100, 30)) as pilot:
            await self.settle(app, pilot)
            self.assertEqual(list(app.tabs), ["services", "routing", "outbounds", "subs", "zapret"])
            self.assertEqual(app.focused.id, "services-table")

            # Services: space toggles the selected unit.
            await pilot.press("down", "space")
            self.assertEqual(self.ran.pop(), ["proxy", "tun", "on"])

            # A state change updates the row in place; the cursor stays on tun.
            self.units["proxy-suite-tun"] = "active"
            app.action_reload()
            await self.settle(app, pilot)
            self.assertEqual(app.selected_key("services"), "proxy-suite-tun")
            self.assertEqual(str(app.table().get_cell("proxy-suite-tun", "state")), "● active")

            # Right arrow moves to Routing and its table has focus.
            await pilot.press("right")
            await self.settle(app, pilot)
            self.assertEqual((app.active_tab(), app.focused.id), ("routing", "routing-table"))

            # Enter opens the row's actions; arrows and enter pick one.
            await pilot.press("down", "enter")
            await pilot.pause()
            self.assertIsInstance(app.screen, tui.Menu)
            self.assertEqual(self.menu_labels(app), ["switch to this mode"])
            await pilot.press("enter")
            await pilot.pause()
            self.assertEqual(self.ran.pop(), ["proxy", "mode", "whitelist"])

            # Outbounds: letter shortcuts; the pinned row offers no pin, and nothing removes a declared one.
            await pilot.press("right")
            await self.settle(app, pilot)
            await pilot.press("p", "t", "a")
            self.assertEqual(self.ran, [["proxy", "select", "a"], ["proxy", "outbounds", "test", "a"], ["proxy", "select", "auto"]])
            self.ran.clear()
            await pilot.press("down", "p", "d")
            self.assertEqual(self.ran, [])
            await pilot.press("enter")
            await pilot.pause()
            self.assertNotIn("pin it", self.menu_labels(app))
            self.assertNotIn("remove it", self.menu_labels(app))
            await pilot.press("escape")

            # Prompts: add takes "<tag> <url>".
            await pilot.press("n", *"x vless://h", "enter")
            await pilot.pause()
            self.assertEqual(self.ran.pop(), ["proxy", "outbounds", "add", "x", "vless://h"])

            # zapret: an excluded host can be included again, not forgotten.
            await pilot.press("5")
            await self.settle(app, pilot)
            await pilot.press("down", "enter")
            await pilot.pause()
            labels = self.menu_labels(app)
            self.assertIn("include it (may be learned again)", labels)
            self.assertNotIn("forget it (may be learned again)", labels)
            await pilot.press("escape", "i")
            self.assertEqual(self.ran.pop(), ["zapret", "auto", "include", "kept.example"])

            # Confirmed actions run only on yes.
            await pilot.press("C", "n")
            await pilot.pause()
            self.assertEqual(self.ran, [])
            await pilot.press("C", "y")
            await pilot.pause()
            self.assertEqual(self.ran.pop(), ["zapret", "auto", "clear"])


if __name__ == "__main__":
    unittest.main()
