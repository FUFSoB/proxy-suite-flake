#!/usr/bin/env python3
"""proxy_gui and proxy_sni without a display: they import, the tray's D-Bus data is well formed,
key names become GTK accelerators, and every icon the tray can ask for is drawn."""

import os
import sys
import tempfile
import types
import unittest
from unittest import mock

import proxy_ctl as ctl
import proxy_gui as gui
import proxy_model as model
import proxy_sni as sni
from gi.repository import Adw, Gio, GLib, Gtk

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons"))
import badges  # noqa: E402


class GuiTest(unittest.TestCase):
    def test_interfaces_parse(self):
        item = Gio.DBusNodeInfo.new_for_xml(sni.ITEM_XML).interfaces[0]
        menu = Gio.DBusNodeInfo.new_for_xml(sni.MENU_XML).interfaces[0]
        self.assertEqual(item.name, "org.kde.StatusNotifierItem")
        self.assertEqual(menu.name, "com.canonical.dbusmenu")
        self.assertIsNotNone(menu.lookup_method("GetLayout"))

    def test_menu_layout(self):
        tree = [
            model.MenuItem("status", "Proxy_only", enabled=False),
            model.MenuItem("proxy", "Proxy", kind="check", checked=True, argv=["proxy", "off"]),
            model.MenuItem(
                "mode", "Routing", kind="submenu",
                children=[model.MenuItem("mode-all", "All", kind="radio", checked=False, argv=["proxy", "mode", "all-proxy"])],
            ),
        ]
        menu = sni.Menu()
        self.assertTrue(menu.update(tree))
        revision = menu.revision
        self.assertFalse(menu.update(tree))  # same shape: hosts keep their copy
        self.assertEqual(menu.revision, revision)

        layout = GLib.Variant("(u(ia{sv}av))", (menu.revision, menu.layout(0, -1, [])))
        _, (root, _, children) = layout.unpack()
        self.assertEqual(root, 0)
        labels = [child[1]["label"] for child in children]
        self.assertEqual(labels, ["Proxy__only", "Proxy", "Routing"])  # "_" would be a mnemonic
        self.assertEqual(children[1][1]["toggle-state"], 1)
        self.assertEqual(children[2][2][0][1]["toggle-type"], "radio")

        # Ids stay put when an item goes away and comes back.
        proxy_id = menu.numbers["proxy"]
        menu.update(tree[:1])
        menu.update(tree)
        self.assertEqual(menu.numbers["proxy"], proxy_id)

    def test_accelerators(self):
        self.assertEqual(gui.accelerator("space"), "space")
        self.assertEqual(gui.accelerator("R"), "<Shift>r")
        self.assertEqual(gui.accelerator("ctrl+r"), "<Control>r")
        self.assertEqual(gui.display_key("ctrl+space"), "Ctrl+Space")
        self.assertEqual([gui.display_key(k) for k in ("N", "ctrl+t", "l")], ["Shift+n", "Ctrl+t", "l"])
        for tab in model.TABS:
            for action in tab.actions:
                if action.key:
                    self.assertTrue(gui.accelerator(action.key))

    def test_a_toggle_is_one_shortcut(self):
        """Two actions on one key are one GTK shortcut, which runs the one that applies to the row."""
        zapret = next(t for t in model.TABS if t.id == "zapret")
        page = types.SimpleNamespace(tab=zapret)
        triggers = gui.Page.triggers(page)
        pin, unpin = triggers["p"]
        self.assertEqual([zapret.actions[i].label for i in (pin, unpin)], ["pin it", "unpin it"])
        ran = []
        page.act = lambda i, from_key: i == unpin and not ran.append(i)
        self.assertTrue(gui.Page.act_any(page, triggers["p"]))
        self.assertEqual(ran, [unpin])
        page.act = lambda i, from_key: False
        self.assertFalse(gui.Page.act_any(page, triggers["p"]))  # nothing applies: the key falls through

    def test_action_looks(self):
        for tab in model.TABS:
            for action in tab.actions:
                self.assertTrue(gui.action_icon(action).endswith("-symbolic"))
        self.assertFalse(gui.is_destructive(model.Action("R", "restart everything running", lambda *_: [], confirm=True)))
        self.assertTrue(gui.is_destructive(model.Action("d", "remove it", lambda *_: [], confirm=True)))
        self.assertTrue(gui.is_destructive(model.Action("F", "forget all learned hosts", lambda *_: [], confirm=True)))
        self.assertTrue(gui.is_badge("state", "active"))
        self.assertTrue(gui.is_badge("status", "ok"))
        self.assertFalse(gui.is_badge("mark", "★"))

    def test_toast_title_is_a_wrapping_label(self):
        """A toast's own title is one ellipsized line; the properties the wrapping one needs are there.
        Widgets cannot be built here: GTK segfaults without a display."""
        self.assertIsNotNone(Adw.Toast.find_property("custom-title"))
        for name in ("wrap", "wrap-mode", "natural-wrap-mode", "lines", "ellipsize", "max-width-chars"):
            self.assertIsNotNone(Gtk.Label.find_property(name), name)
        self.assertGreater(gui.TOAST_LINES, 1)

    def test_ansi(self):
        self.assertEqual(
            gui.ansi_segments("\x1b[1;31mfailed\x1b[0m ok\x1b[K"),
            [("failed", ("bold", "red")), (" ok", ())],
        )

    def test_root_toggle_reads_too(self):
        """A tab only root can read goes through pkexec when the toggle is on, and one refusal stops the asking."""
        tab = model.Tab("x", "X", model.ROW, [], list)
        app = types.SimpleNamespace(root_read_refused=False, root_reads={})
        denied = ([], "✗ Cannot read /x - join the proxy-suite group, or re-run with sudo.")
        asked = []

        def as_root(result):
            return mock.patch.object(model, "load_tab_as_root", lambda tab, via: asked.append(via) or result)

        load = lambda elevated, fresh=False: gui.ProxySuiteGui.load_tab(app, tab, {}, elevated, fresh)
        with mock.patch.object(model, "load_tab", lambda tab, states: denied), mock.patch.object(model.os, "geteuid", lambda: 1000):
            with as_root(([{"key": "a"}], "")):
                self.assertIn("Ctrl+E", load(False)[1])
                self.assertEqual(asked, [])
                self.assertEqual(load(True), ([{"key": "a"}], ""))
                self.assertEqual(asked, ["pkexec"])
                # A refresh shows that read again: pkexec asks for the password every time.
                rows, summary = load(True)
                self.assertEqual(rows, [{"key": "a"}])
                self.assertIn("F5 to read again", summary)
                self.assertEqual(asked, ["pkexec"])
            with as_root((None, "authentication cancelled")):
                self.assertIn("As root: authentication cancelled", load(True, fresh=True)[1])
                self.assertIn("Ctrl+E twice", load(True, fresh=True)[1])
                self.assertEqual(len(asked), 2)
        with mock.patch.object(model, "load_tab", lambda tab, states: ([], "Nothing here yet.")), as_root(None):
            app.root_read_refused = False
            self.assertEqual(load(True), ([], "Nothing here yet."))  # readable: no pkexec
            self.assertEqual(len(asked), 2)

    def test_paste_asks_first(self):
        """A web page can plant a link in the clipboard: Ctrl+V only asks, and runs on yes."""
        ran, asked = [], []
        app = types.SimpleNamespace(
            run_argv=lambda mode, argv, win, stdin=None: ran.append((argv, stdin)),
            confirm=lambda argv, then, parent, stdin=None: asked.append((argv, then, stdin)),
        )
        win = types.SimpleNamespace(app=app, toast=lambda text: None)
        clipboard = types.SimpleNamespace(read_text_finish=lambda result: "https://evil.test/s")
        page = types.SimpleNamespace(tab=types.SimpleNamespace(id="subs"))
        gui.Window.pasted(win, page, clipboard, None)
        self.assertEqual(ran, [])
        [(argv, then, stdin)] = asked
        self.assertEqual((argv, stdin), (["proxy", "subs", "add", "-"], "https://evil.test/s"))
        then()
        self.assertEqual(ran, [(["proxy", "subs", "add", "-"], "https://evil.test/s")])

    def test_selector_runs_only_a_new_choice(self):
        """The Routing page's mode drop-down: picking runs proxy-ctl; filling it from a read does not."""
        routing = next(t for t in model.TABS if t.id == "routing")
        ran = []
        win = types.SimpleNamespace(app=types.SimpleNamespace(run_argv=lambda mode, argv, win: ran.append((mode, argv))))
        page = types.SimpleNamespace(tab=routing, win=win, selector_setting=False, selector_values=["default", *ctl.ROUTE_MODES])
        drop = lambda index: types.SimpleNamespace(get_selected=lambda: index)  # noqa: E731
        with mock.patch.object(ctl, "_route_mode_current", lambda: "default"):
            gui.Page.on_selector_changed(page, drop(2), None)
            self.assertEqual(ran, [("run", ["proxy", "mode", "blacklist"])])
            gui.Page.on_selector_changed(page, drop(0), None)  # the current one
            gui.Page.on_selector_changed(page, drop(Gtk.INVALID_LIST_POSITION), None)
            page.selector_setting = True  # set from a read
            gui.Page.on_selector_changed(page, drop(1), None)
        self.assertEqual(len(ran), 1)
        self.assertTrue(gui.accelerator(routing.selector.key))

    def test_every_tray_icon_is_drawn(self):
        here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
        with tempfile.TemporaryDirectory() as out:
            badges.main(here, out)
            drawn = set(os.listdir(out))
        for base in badges.STATES:
            for badge in ("", *badges.GLYPHS):
                name = model.icon_name({"base": base, "badge": badge, "label": ""})
                self.assertIn(f"{name}.svg", drawn)
                self.assertIn(f"{name}-symbolic.svg", drawn)
        self.assertIn(f"{model.icon_name(ctl._overall_state(None))}.svg", drawn)


if __name__ == "__main__":
    unittest.main()
