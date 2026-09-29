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

CLI_AWG_PROFILES = ctl._awg_profiles  # before setUp patches it

import proxy_model as model  # noqa: E402


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
        self.assertEqual(model.restart_argv(row), ["warp", "restart"])
        self.assertIn("ctrl+r", keys())
        self.assertNotIn("ctrl+r", [a.key for a in model.applicable(tab, row)])  # nothing to restart while stopped
        with mock.patch.object(ctl, "_awg_profiles", lambda: ["warp"]):
            self.assertEqual(model.toggle_argv(row), ["awg", "on", "warp"])  # a global profile named warp
            self.assertEqual(model.restart_argv(row), ["awg", "restart", "warp"])

    def test_every_toggle_restarts(self):
        tab = model.TABS[0]
        restart = next(a for a in tab.actions if a.key == "ctrl+r")
        for unit, group in model.TOGGLES.items():
            for state in ("active", "failed"):
                row = {"key": unit, "unit": unit, "name": unit, "state": state}
                self.assertIn(restart, model.applicable(tab, row))
                self.assertEqual(restart.argv(row), [*group, "restart"])

    def test_inbound_amneziawg_actions(self):
        tab = next(t for t in model.TABS if t.id == "inbounds")
        actions = {a.key: a for a in tab.actions}
        awg = {"key": "awg/u", "tag": "awg", "user": "u", "type": "amneziawg", "port": "51820"}
        vless = {"key": "in/u", "tag": "in", "user": "u", "type": "vless", "port": "443"}
        self.assertEqual(actions["k"].argv(awg), ["inbounds", "link", "awg", "u", "--config"])
        self.assertEqual(actions["K"].argv(awg), ["inbounds", "link", "awg", "u", "--config", "--qr"])
        self.assertTrue(actions["k"].when(awg) and actions["K"].when(awg) and actions["J"].when(vless))
        self.assertFalse(actions["k"].when(vless) or actions["K"].when(vless) or actions["J"].when(awg))

    def test_runtime_inbound_users_and_listeners(self):
        users = next(t for t in model.TABS if t.id == "inbound-users")
        inbounds = next(t for t in model.TABS if t.id == "inbounds")
        with mock.patch.dict(os.environ, {"INBOUNDS_ENABLED": "1", "INBOUNDS_RUNTIME_ENABLED": "0"}):
            # Listed from the configuration; nothing to change them with.
            self.assertTrue(users.available({}))
            self.assertEqual([a.key for a in users.actions if model.offered(a)], ["i"])
            self.assertNotIn("n", [a.key for a in inbounds.actions if model.offered(a)])
        with mock.patch.dict(os.environ, {"INBOUNDS_ENABLED": "0"}):
            self.assertFalse(users.available({}))
        with mock.patch.dict(os.environ, {"INBOUNDS_ENABLED": "1", "INBOUNDS_RUNTIME_ENABLED": "1"}):
            self.assertTrue(users.available({}))
            rows = [{"name": "bob", "source": "nix", "order": 1, "address": "10.78.0.1", "listeners": ["in"], "problems": []},
                    {"name": "alice", "source": "runtime", "order": 4, "address": "", "listeners": [], "problems": ["no listeners"]}]
            with mock.patch.object(ctl, "_inbound_runtime_rows", lambda kind: rows):
                bob, alice = model.inbound_user_rows({})
            self.assertEqual((bob["listeners"], alice["problems"]), ("in", "no listeners"))
            actions = {a.key: a for a in users.actions}
            self.assertEqual(actions["n"].argv(None, "carol 7 in ws", {}),
                             ["inbounds", "users", "add", "carol", "--order", "7", "--listener", "in", "--listener", "ws"])
            self.assertEqual(actions["n"].argv(None, "carol", {}), ["inbounds", "users", "add", "carol"])
            self.assertEqual([a.key for a in model.applicable(users, bob)], ["n", "b", "x", "i"])
            self.assertEqual(actions["e"].argv(alice, " 9 ", {}), ["inbounds", "users", "order", "alice", "9"])
            self.assertEqual(actions["b"].argv(alice, "in", {}), ["inbounds", "bind", "alice", "in"])
            actions = {a.key: a for a in inbounds.actions}
            row = {"key": "friends/alice", "tag": "friends", "user": "alice", "type": "vless", "port": "20001", "source": "runtime"}
            self.assertEqual(actions["n"].argv(None, "friends vless --port 20001", {}), ["inbounds", "add", "friends", "vless", "--port", "20001"])
            self.assertEqual(actions["d"].argv(row), ["inbounds", "rm", "friends"])
            self.assertFalse(actions["d"].when({**row, "source": "nix"}))
            self.assertEqual(actions["b"].argv(row, "bob", {}), ["inbounds", "bind", "bob", "friends"])

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

    def test_whitelist_bypass_rows(self):
        """A creator or joiner is a unit on the services tab: toggled, restarted, and its call handled there."""
        tab = model.TABS[0]
        wl = [
            {"name": "vk", "role": "creator", "platform": "vk"},
            {"name": "dion", "role": "creator", "platform": "dion", "fixedLink": True},
            {"name": "home", "role": "joiner", "platform": "vk"},
        ]
        with mock.patch.object(ctl, "_wl", lambda: wl):
            vk, dion, home = (
                {"key": u, "unit": u, "name": u, "state": "active"} for u in ("proxy-suite-wb-creator-vk", "proxy-suite-wb-creator-dion", "proxy-suite-wb-joiner-home")
            )
            keys = lambda row: {a.key: a for a in model.applicable(tab, row)}
            self.assertEqual(model.toggle_argv(vk), ["wl", "off", "vk"])
            self.assertEqual(model.restart_argv(home), ["wl", "restart", "home"])
            self.assertEqual(keys(vk)["s"].argv(vk), ["wl", "link", "vk"])
            self.assertEqual(keys(vk)["Q"].argv(vk), ["wl", "link", "vk", "--qr"])
            self.assertEqual(keys(vk)["N"].argv(vk), ["wl", "new", "vk"])
            self.assertEqual(keys(vk)["a"].argv(vk, "/tmp/c.json", {}), ["wl", "auth", "vk", "/tmp/c.json"])
            self.assertEqual(keys(home)["j"].argv(home, " abc-def ", {}), ["wl", "join", "home", "abc-def"])
            self.assertNotIn("N", keys(dion))  # a fixed link: its linkFile sets the call
            self.assertNotIn("A", keys(vk))  # VK logs in only in a browser
            self.assertEqual(keys(dion)["A"].argv(dion), ["wl", "auth", "dion"])
            self.assertFalse({"s", "N", "a", "A"} & set(keys(home)))
            self.assertNotIn("j", keys(vk))
            with mock.patch.object(model, "TTY", False):
                self.assertNotIn("A", keys(dion))  # it asks on a terminal the GUI does not have

    def test_a_shared_key_is_a_toggle(self):
        """Actions on one key take turns: each needs a row, and no row gets two of them."""
        rows = {
            "outbounds": [{"mark": m, "disabled": d} for m in ("", "★") for d in (False, True)],
            "zapret": [{"kind": k} for k in ("learned", "pinned", "excluded")],
            "autoproxy": [{"kind": k} for k in ("routed", "queued")],
        }
        for tab in model.TABS:
            by_key = {}
            for a in tab.actions:
                by_key.setdefault(a.key, []).append(a)
            for key, actions in by_key.items():
                if len(actions) > 1:
                    self.assertIn(tab.id, rows, f"{tab.id}: {key} is shared; add rows for it here")
                    self.assertTrue(all(a.when is not None for a in actions), (tab.id, key))
                    for row in rows[tab.id]:
                        self.assertLessEqual(sum(bool(a.when(row)) for a in actions), 1, (tab.id, key, row))
        self.assertEqual([model.display_key(k) for k in ("F", "ctrl+r", "space", "f")], ["shift+f", "ctrl+r", "space", "f"])
        zapret = next(t for t in model.TABS if t.id == "zapret")
        labels = dict(model.key_labels(zapret.actions))
        self.assertEqual((labels["p"], labels["x"]), ("pin it / unpin it", "exclude it / include it again"))
        autoproxy = next(t for t in model.TABS if t.id == "autoproxy")
        self.assertEqual([a.argv({"domain": "a.test"}, "", {}) for a in model.applicable(autoproxy, {"kind": "queued", "domain": "a.test"}) if a.key == "u"],
                         [["proxy", "auto", "learn", "a.test"]])

    def test_tor_newnym(self):
        tab = model.TABS[0]
        tor = {"key": "proxy-suite-tor", "unit": "proxy-suite-tor", "name": "tor", "state": "active"}
        newnym = next(a for a in tab.actions if a.key == "n")
        self.assertIn(newnym, model.applicable(tab, tor))
        self.assertEqual(newnym.argv(tor), ["tor", "newnym"])
        self.assertNotIn(newnym, model.applicable(tab, {**tor, "state": "inactive"}))

    def test_actions_this_configuration_has(self):
        """A tab-wide action for a feature the configuration leaves out is not offered."""
        routing = next(t for t in model.TABS if t.id == "routing")
        zapret = next(t for t in model.TABS if t.id == "zapret")
        env = {}
        with mock.patch.object(ctl, "env", lambda name, default="": env.get(name, default)):
            self.assertEqual([a.key for a in model.applicable(routing, None)], [])
            self.assertEqual([a.key for a in model.applicable(zapret, None)], ["space", "ctrl+r"])
            with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
                json.dump([{"name": "ru", "path": "/nonexistent"}], f)
                f.flush()
                env.update(RULE_SETS_FILE=f.name, ZAPRET_AUTO_ENABLED="1", ZAPRET_CUTOFF_ENABLED="1")
                self.assertEqual([a.argv(None, "", {}) for a in model.applicable(routing, None)], [["proxy", "rulesets", "list"], ["proxy", "rulesets", "update"]])
            self.assertEqual([a.key for a in model.applicable(zapret, None)], ["n", "X", "F", "P", "space", "ctrl+r"])
        actions = {a.key: a for a in zapret.actions}
        self.assertEqual(actions["n"].argv(None, "example.com", {}), ["zapret", "auto", "add", "example.com"])
        self.assertEqual(actions["X"].argv(None, "example.com", {}), ["zapret", "auto", "exclude", "example.com"])

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

    def test_paste_argv(self):
        paste = model.paste_argv
        self.assertEqual(paste("outbounds", " vless://u@de.test:443#DE\n")[0], ["proxy", "outbounds", "add", "vless://u@de.test:443#DE"])
        # The tab pasted onto does not matter for an unambiguous link.
        self.assertEqual(paste("services", "ss://x@a.test:8388")[0], ["proxy", "outbounds", "add", "ss://x@a.test:8388"])
        self.assertEqual(paste("services", '{"type": "socks",\n "server": "1.2.3.4"}')[0][:3], ["proxy", "outbounds", "add"])
        # http(s) is both a subscription and an HTTP proxy: the tab decides.
        self.assertEqual(paste("subs", "https://sub.test/s")[0], ["proxy", "subs", "add", "https://sub.test/s"])
        self.assertEqual(paste("services", "https://sub.test/s")[0], ["proxy", "subs", "add", "https://sub.test/s"])
        self.assertEqual(paste("outbounds", "https://u:p@proxy.test:8443")[0], ["proxy", "outbounds", "add", "https://u:p@proxy.test:8443"])
        # A bare host means something only where a tab collects hosts.
        self.assertEqual(paste("zapret", "blocked.example")[0], ["zapret", "auto", "add", "blocked.example"])
        self.assertEqual(paste("autoproxy", "blocked.example")[0], ["proxy", "auto", "learn", "blocked.example"])
        for tab, text, why in [
            ("outbounds", "", "Nothing to paste."),
            ("outbounds", "vless://a\nvless://b", "one link at a time"),
            ("outbounds", "ftp://a.test/x", "ftp:// link"),
            ("outbounds", "blocked.example", "Not a share link"),
            ("zapret", "not a host", "Not a share link"),
        ]:
            with self.subTest(text=text):
                argv, message, stdin = paste(tab, text)
                self.assertIsNone(argv)
                self.assertIsNone(stdin)
                self.assertIn(why, message)

    def test_paste_amneziawg(self):
        conf = "[Interface]\nPrivateKey = secret\nAddress = 10.8.0.2/32\n\n[Peer]\nPublicKey = p\nAllowedIPs = 0.0.0.0/0\n"
        runtime = {"AWG_RUNTIME_GLOBAL": "1", "AWG_RUNTIME_OUTBOUNDS": "1"}
        with mock.patch.dict(os.environ, runtime):
            # A global profile, but an outbound on the outbounds tab. The config itself only on stdin.
            self.assertEqual(model.paste_argv("services", conf), (["awg", "add", "-"], "", conf.strip()))
            self.assertEqual(model.paste_argv("awg", "vpn://AAAA"), (["awg", "add", "-"], "", "vpn://AAAA"))
            self.assertEqual(model.paste_argv("outbounds", "vpn://AAAA"), (["proxy", "outbounds", "add", "-"], "", "vpn://AAAA"))
        with mock.patch.dict(os.environ, {"AWG_RUNTIME_GLOBAL": "0", "AWG_RUNTIME_OUTBOUNDS": "1"}):
            self.assertEqual(model.paste_argv("services", "vpn://AAAA")[0], ["proxy", "outbounds", "add", "-"])
        with mock.patch.dict(os.environ, {"AWG_RUNTIME_GLOBAL": "0", "AWG_RUNTIME_OUTBOUNDS": "0"}):
            argv, why, stdin = model.paste_argv("services", conf)
            self.assertIsNone(argv)
            self.assertIn("amneziaWg.runtime", why)

    def test_awg_tab(self):
        tab = next(t for t in model.TABS if t.id == "awg")
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "added.conf"), "w").close()
            profiles = os.path.join(d, "profiles.json")
            with open(profiles, "w") as f:
                json.dump(["home"], f)
            env = {"AWG_RUNTIME_GLOBAL": "1", "AWG_RUNTIME_DIR": d, "AWG_PROFILES_FILE": profiles}
            with mock.patch.dict(os.environ, env), mock.patch.object(ctl, "_awg_profiles", CLI_AWG_PROFILES):
                self.assertTrue(tab.available({}))
                rows, _ = model.load_tab(tab, {"proxy-suite-awg@added": "active"})
                self.assertEqual(
                    [(r["profile"], r["unit"], r["state"], r["source"]) for r in rows],
                    [("home", "proxy-suite-awg-home", "inactive", "declared"), ("added", "proxy-suite-awg@added", "active", "runtime")],
                )
                self.assertEqual([a.key for a in model.applicable(tab, rows[0])], ["space", "l", "n"])
                self.assertEqual([a.key for a in model.applicable(tab, rows[1])], ["space", "ctrl+r", "l", "n", "d"])
                act = {a.key: a for a in tab.actions}
                self.assertEqual(act["space"].argv(rows[1], "", {}), ["awg", "off", "added"])
                self.assertEqual(act["d"].argv(rows[1], "", {}), ["awg", "rm", "added"])
                # The Services tab's row for the instance toggles it through `awg` too.
                self.assertEqual(model.toggle_argv({"unit": "proxy-suite-awg@added", "state": "active"}), ["awg", "off", "added"])
        add = next(a for a in tab.actions if a.key == "n")
        self.assertEqual((add.argv(None, "work vpn://AAAA", {}), add.stdin(None, "work vpn://AAAA")), (["awg", "add", "work", "-"], "vpn://AAAA"))
        self.assertEqual((add.argv(None, "vpn://AAAA", {}), add.stdin(None, "vpn://AAAA")), (["awg", "add", "-"], "vpn://AAAA"))
        # A path goes as one: proxy-ctl reads it, and it may run as root elsewhere.
        self.assertEqual((add.argv(None, "work /tmp/w.conf", {}), add.stdin(None, "work /tmp/w.conf")), (["awg", "add", "work", "/tmp/w.conf"], None))
        outbound_add = next(a for a in next(t for t in model.TABS if t.id == "outbounds").actions if a.key == "n")
        self.assertEqual(outbound_add.argv(None, "de vpn://AAAA", {}), ["proxy", "outbounds", "add", "de", "-"])
        self.assertEqual(outbound_add.stdin(None, "de vpn://AAAA"), "vpn://AAAA")
        self.assertEqual(outbound_add.argv(None, "de vless://x", {}), ["proxy", "outbounds", "add", "de", "vless://x"])
        self.assertIsNone(outbound_add.stdin(None, "de vless://x"))

    def test_popen_feeds_stdin(self):
        with mock.patch.object(model, "CTL", "cat"):
            for stdin, out in (("secret\n", "secret\n"), (None, "")):
                p = model.popen([], stdin=stdin)
                with p.stdout:
                    self.assertEqual(p.stdout.read(), out)
                p.wait()

    def test_load_tab(self):
        tab = next(t for t in model.TABS if t.id == "outbounds")
        inventory = {"tags": ["a", "b"], "pinned": "b", "detours": {"a": "b"}, "excluded": ["b"]}
        with mock.patch.object(ctl, "_outbound_current", lambda: "a"), mock.patch.object(ctl, "_reputation_by_tag", lambda: {}), mock.patch.object(ctl, "_runtime_tags", lambda kind: []), mock.patch.object(ctl, "_outbound_inventory", lambda: inventory):
            rows, summary = model.load_tab(tab, {})
        self.assertEqual([(r["tag"], r["mark"], r["notes"]) for r in rows], [("a", "▸", "via b"), ("b", "★", "never picked")])
        self.assertIn("Pinned: b", summary)
        with mock.patch.object(ctl, "env", lambda name, default="": ""):
            self.assertEqual([a.key for a in model.applicable(tab, rows[1])], ["p", "t", "ctrl+t", "T", "n", "h", "H", "x", "s", "c", "Q", "J", "k", "K", "V"])
        chain = next(a for a in tab.actions if a.key == "h")
        self.assertEqual(chain.argv(rows[1], 'c {"type": "socks"}', {}), ["proxy", "outbounds", "add", "c", '{"type": "socks"}', "--detour", "b"])
        # Probe exits go by the backend's tag.
        probe = next(a for a in tab.actions if a.key == "P")
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
            labels = {a.key: a.label for a in model.applicable(tab, rows[1])}
            self.assertEqual(labels["x"], "enable it again")  # x toggles: disable, enable
            self.assertNotIn("p", labels)
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
        for key in ("f", "u"):  # u: the last action on it, relearn
            self.assertIn(actions[key], model.applicable(tab, routed))
            self.assertNotIn(actions[key], model.applicable(tab, queued))
        self.assertEqual(actions["f"].argv(routed, "", {}), ["proxy", "auto", "forget", "last.fm"])
        self.assertEqual(actions["u"].argv(routed, "", {}), ["proxy", "auto", "relearn", "last.fm"])
        self.assertEqual(actions["F"].argv(None, "", {}), ["proxy", "auto", "clear"])
        self.assertTrue(actions["f"].confirm and actions["F"].confirm)

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
