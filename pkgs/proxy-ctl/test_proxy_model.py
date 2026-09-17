#!/usr/bin/env python3
"""proxy_model without a front end: the status line and the tray menu turn state into the right proxy-ctl argv."""

import contextlib
import io
import json
import os
import subprocess
import tempfile
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

    def test_root(self):
        with mock.patch.object(model.os, "geteuid", lambda: 1000):
            self.assertTrue(model.needs_root(["Cannot read /run/x - re-run with sudo."], 1))
            self.assertTrue(model.needs_root(["Failed to start proxy-suite-tun.service: Access denied"], 1))
            self.assertFalse(model.needs_root(["re-run with sudo"], 0))
            self.assertFalse(model.needs_root(["Unknown outbound: x"], 1))
            self.assertFalse(model.needs_root(["re-run with sudo"], -15))  # stopped, not refused
        with mock.patch.object(model.os, "geteuid", lambda: 0):
            self.assertFalse(model.needs_root(["re-run with sudo"], 1))
            self.assertEqual(model.status_items({})[0], ("", "root", "warn"))
            apps = next(t for t in model.TABS if t.id == "apps")
            with mock.patch.object(ctl, "env", lambda name, default="": "1"):
                self.assertFalse(apps.available({}))
        with mock.patch.object(model.shutil, "which", lambda name: f"/nix/store/x/bin/{name}"):
            self.assertEqual(model.elevated(["proxy", "config"], "pkexec"), ["pkexec", "/nix/store/x/bin/proxy-ctl", "proxy", "config"])

    def test_services_skip_the_subscription_update(self):
        rows = model.service_rows({"proxy-suite-socks": "active", ctl.SUBSCRIPTION_UPDATE: "inactive"})
        self.assertEqual([r["unit"] for r in rows], ["proxy-suite-socks"])

    def test_warp_over_amneziawg_toggles_with_warp(self):
        tab = model.TABS[0]
        row = model.service_rows({"proxy-suite-awg-warp": "inactive"})[0]
        keys = lambda: [a.key for a in model.applicable(tab, {**row, "state": "active"})]
        self.assertEqual(model.toggle_argv(row), ["warp", "on"])  # an outbound profile: `awg` does not know it
        self.assertNotIn("ctrl+r", keys())
        with mock.patch.object(ctl, "_awg_profiles", lambda: ["warp"]):
            self.assertEqual(model.toggle_argv(row), ["awg", "on", "warp"])  # a global profile named warp
            self.assertIn("ctrl+r", keys())

    def test_inbound_amneziawg_actions(self):
        tab = next(t for t in model.TABS if t.id == "inbounds")
        actions = {a.key: a for a in tab.actions}
        awg = {"key": "awg/u", "tag": "awg", "user": "u", "type": "amneziawg", "port": "51820"}
        vless = {"key": "in/u", "tag": "in", "user": "u", "type": "vless", "port": "443"}
        self.assertEqual(actions["k"].argv(awg), ["inbounds", "link", "awg", "u", "--config"])
        self.assertEqual(actions["K"].argv(awg), ["inbounds", "link", "awg", "u", "--config", "--qr"])
        self.assertTrue(actions["k"].when(awg) and actions["K"].when(awg) and actions["J"].when(vless))
        self.assertFalse(actions["k"].when(vless) or actions["K"].when(vless) or actions["J"].when(awg))

    def test_inbound_rows_carry_no_presence(self):
        """XRay keys the online map by user, not by inbound, so a per-listener row
        could only repeat one verdict per listener; it must not claim to have one."""
        links = [
            {"tag": "ws", "user": "alice", "type": "vless", "port": 443},
            {"tag": "reality", "user": "alice", "type": "vless", "port": 2053},
        ]
        called = []
        with mock.patch.object(ctl, "_inbound_links", lambda: links), mock.patch.object(
            ctl, "_inbound_presence", lambda: called.append(1) or {}
        ):
            rows = model.inbound_rows({})
        self.assertEqual([r["tag"] for r in rows], ["ws", "reality"])
        self.assertNotIn("online", rows[0])
        # And the tab no longer pays for the API call on every load.
        self.assertEqual(called, [])
        self.assertNotIn("online", [c for c, _ in next(t for t in model.TABS if t.id == "inbounds").columns])

    def test_onion_rows_link_through_the_onion(self):
        links = [
            {"tag": "ws", "user": "alice", "type": "vless", "port": 443},
            {"tag": "ws", "user": "alice", "type": "vless", "port": 443, "variant": "onion"},
        ]
        with mock.patch.object(ctl, "_inbound_links", lambda: links):
            plain, onion = model.inbound_rows({})
        self.assertEqual((plain["key"], onion["key"]), ("ws/alice", "ws/alice/onion"))
        self.assertEqual((plain["type"], onion["type"]), ("vless", "vless (onion)"))
        self.assertEqual(model._link(plain, "--qr"), ["inbounds", "link", "ws", "alice", "--qr"])
        self.assertEqual(model._link(onion, "--qr"), ["inbounds", "link", "ws", "alice", "--onion", "--qr"])
        self.assertFalse(model._amneziawg(onion))
        self.assertEqual(model.TOGGLES["proxy-suite-tor"], ["tor"])

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
        self.assertTrue(items["restart"].confirm)  # as R in the TUI and GUI
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
        inventory = {"tags": ["a", "b"], "pinned": "b", "detours": {"a": "b"}, "excluded": ["b"]}
        with mock.patch.object(ctl, "_outbound_current", lambda: "a"), mock.patch.object(ctl, "_reputation_by_tag", lambda: {}), mock.patch.object(ctl, "_runtime_tags", lambda kind: []), mock.patch.object(ctl, "_outbound_inventory", lambda: inventory):
            rows, summary = model.load_tab(tab, {})
        self.assertEqual([(r["tag"], r["mark"], r["notes"]) for r in rows], [("a", "▸", "via b"), ("b", "★", "never picked")])
        self.assertIn("Pinned: b", summary)
        with mock.patch.object(ctl, "env", lambda name, default="": ""):
            self.assertEqual([a.key for a in model.applicable(tab, rows[1])], ["u", "t", "D", "T", "n", "h", "x", "l", "c", "Q", "J", "F", "X"])
        chain = next(a for a in tab.actions if a.key == "h")
        self.assertEqual(chain.argv(rows[1], 'c {"type": "socks"}', {}), ["proxy", "outbounds", "add", "c", '{"type": "socks"}', "--detour", "b"])
        # Probe exits go by the backend's tag.
        probe = next(a for a in tab.actions if a.key == "v")
        with mock.patch.object(ctl, "env", lambda name, default="": "1" if name == "AUTOPROXY_ENABLED" else ""), mock.patch.object(ctl, "_backend_tags", lambda: {"b": "b-backend"}):
            self.assertIn(probe, model.applicable(tab, rows[1]))
            self.assertEqual(probe.argv(rows[1], "example.com", {}), ["proxy", "auto", "probe", "example.com", "--via", "b-backend"])
        broken = model.Tab("x", "X", model.ROW, [], lambda _: ctl.die("backend gone"))
        self.assertEqual(model.load_tab(broken, {}), ([], "✗ backend gone"))
        # outbounds.d is root-only: the inventory still says which are runtime, so they can be removed.
        inventory["sources"] = {"a": "runtime"}
        with mock.patch.object(ctl, "_outbound_current", lambda: ""), mock.patch.object(ctl, "_reputation_by_tag", lambda: {}), mock.patch.object(ctl, "_runtime_tags", lambda kind: []), mock.patch.object(ctl, "_outbound_inventory", lambda: inventory):
            rows, _ = model.load_tab(tab, {})
        self.assertEqual([(r["source"], r["runtime"]) for r in rows], [("runtime", True), ("-", False)])

    def test_disabled_outbound(self):
        """Disabled: marked, never offered a pin, and enabled again rather than disabled twice."""
        tab = next(t for t in model.TABS if t.id == "outbounds")
        inventory = {"tags": ["a", "b"], "pinned": "", "excluded": ["b"], "disabled": ["b"]}
        with mock.patch.object(ctl, "_outbound_current", lambda: "a"), mock.patch.object(ctl, "_reputation_by_tag", lambda: {}), mock.patch.object(ctl, "_runtime_tags", lambda kind: []), mock.patch.object(ctl, "_outbound_inventory", lambda: inventory), mock.patch.object(ctl, "env", lambda name, default="": ""):
            rows, _ = model.load_tab(tab, {})
            self.assertEqual([(r["mark"], r["notes"], r["disabled"]) for r in rows], [("▸", "", False), ("✕", "disabled", True)])
            keys = [a.key for a in model.applicable(tab, rows[1])]
            self.assertIn("e", keys)
            self.assertNotIn("p", keys)
            self.assertNotIn("x", keys)
            self.assertEqual(next(a for a in tab.actions if a.key == "x").argv(rows[0], "", {}), ["proxy", "outbounds", "disable", "a"])
        with mock.patch.object(ctl, "_outbound_inventory", lambda: inventory):
            self.assertEqual(model.tray_outbounds({"proxy": {"active": True}}), (["a"], ""))

    def test_add_prompt_takes_an_optional_tag(self):
        subs = next(t for t in model.TABS if t.id == "subs")
        add = next(a for a in subs.actions if a.key == "n")
        self.assertIn("[tag]", add.prompt)
        self.assertEqual(add.argv(None, "https://x.test/s", {}), ["proxy", "subs", "add", "https://x.test/s"])
        self.assertEqual(add.argv(None, " work  https://x.test/s ", {}), ["proxy", "subs", "add", "work", "https://x.test/s"])
        outbounds = next(t for t in model.TABS if t.id == "outbounds")
        add = next(a for a in outbounds.actions if a.key == "n")
        # JSON has spaces in it: all one argument.
        self.assertEqual(add.argv(None, '{"type": "socks"}', {}), ["proxy", "outbounds", "add", '{"type": "socks"}'])

    def test_autoproxy_forget_relearn_clear(self):
        tab = next(t for t in model.TABS if t.id == "autoproxy")
        state = {"domains": {"last.fm": {"exit": "de", "host": "www.last.fm"}}, "backlog": {"a.test": {"domain": "a.test", "hits": 2}}}
        with mock.patch.object(ctl, "_autoproxy_unreadable", lambda path: ""), mock.patch.object(ctl, "_autoproxy_state", lambda path: state):
            routed, queued = model.autoproxy_rows({})
        self.assertEqual(routed["detail"], "via de, learned from www.last.fm")
        actions = {a.key: a for a in tab.actions}
        for key in ("f", "R"):
            self.assertIn(actions[key], model.applicable(tab, routed))
            self.assertNotIn(actions[key], model.applicable(tab, queued))
        self.assertEqual(actions["f"].argv(routed, "", {}), ["proxy", "auto", "forget", "last.fm"])
        self.assertEqual(actions["R"].argv(routed, "", {}), ["proxy", "auto", "relearn", "last.fm"])
        self.assertEqual(actions["C"].argv(None, "", {}), ["proxy", "auto", "clear"])
        self.assertTrue(actions["f"].confirm and actions["C"].confirm)

    def test_load_tab_as_root(self):
        """The GUI's root read: proxy-ctl status --tab through pkexec, and what a refusal says."""
        tab = next(t for t in model.TABS if t.id == "routing")
        with mock.patch.object(ctl, "_route_mode_current", lambda: "default"), mock.patch.object(ctl, "_route_mode_default", lambda: "rules"):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                ctl._status_tab("routing")
            self.assertEqual(json.loads(out.getvalue()), list(model.load_tab(tab, {})))
        with self.assertRaises(SystemExit) as e:
            ctl._status_tab("nope")
        self.assertIn("status --tab <services|", str(e.exception))

        def ran(returncode, stdout="", stderr=""):
            return mock.patch.object(model.subprocess, "run", lambda argv, **_: subprocess.CompletedProcess(argv, returncode, stdout, stderr))

        with ran(0, '[[{"key": "a"}], "ok"]'):
            self.assertEqual(model.load_tab_as_root(tab, "pkexec"), ([{"key": "a"}], "ok"))
        with ran(126):
            self.assertEqual(model.load_tab_as_root(tab, "pkexec"), (None, "authentication cancelled"))
        with ran(127, stderr="pkexec must be setuid root\n"):  # not a refusal: asked again next refresh
            self.assertEqual(model.load_tab_as_root(tab, "pkexec"), (None, "pkexec must be setuid root"))
        with ran(1, stderr="boom\nUsage: proxy-ctl status\n"):
            self.assertEqual(model.load_tab_as_root(tab, "pkexec"), (None, "Usage: proxy-ctl status"))

    @unittest.skipIf(os.geteuid() == 0, "root reads anything")
    def test_unreadable_is_not_empty(self):
        """A tab that cannot read its state says so; "Nothing here yet." would be a lie."""
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state.json")
            with open(state, "w") as f:
                f.write("{}")
            tab = next(t for t in model.TABS if t.id == "autoproxy")
            with mock.patch.object(ctl, "_autoproxy_dir", lambda: tmp), mock.patch.object(ctl, "_status_autoproxy", lambda: ""):
                self.assertIn("Nothing here yet.", model.load_tab(tab, {})[1])  # readable and empty: really empty
                os.chmod(state, 0)
                model.new_load()
                self.assertIn(f"✗ Cannot read {state}", model.load_tab(tab, {})[1])
                os.chmod(tmp, 0o751)  # a stranger to the group: past the dir, stopped at the state
                model.new_load()
                self.assertIn(f"✗ Cannot read {state}", model.load_tab(tab, {})[1])
                os.chmod(tmp, 0)
                model.new_load()
                self.assertIn(f"✗ Cannot read {tmp}", model.load_tab(tab, {})[1])
            os.chmod(tmp, 0o700)

            subs = next(t for t in model.TABS if t.id == "subs")
            runtime = os.path.join(tmp, "subscriptions.d")
            os.mkdir(runtime, 0o700)
            env = {"RUNTIME_SUBS_DIR": runtime, "SUB_CACHE_DIR": tmp}
            with mock.patch.object(ctl, "env", lambda name, default="": env.get(name, default)), mock.patch.object(ctl, "_sub_tags", list):
                model.new_load()
                self.assertIn("Nothing here yet.", model.load_tab(subs, {})[1])
                os.chmod(runtime, 0)
                model.new_load()
                self.assertIn(f"✗ Cannot read {runtime}", model.load_tab(subs, {})[1])
            os.chmod(runtime, 0o700)


if __name__ == "__main__":
    unittest.main()
