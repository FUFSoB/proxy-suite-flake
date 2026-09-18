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
        for tab in model.TABS:
            for action in tab.actions:
                if action.key:
                    self.assertTrue(gui.accelerator(action.key))

    def test_action_looks(self):
        for tab in model.TABS:
            for action in tab.actions:
                self.assertTrue(gui.action_icon(action).endswith("-symbolic"))
        self.assertFalse(gui.is_destructive(model.Action("R", "restart everything running", lambda *_: [], confirm=True)))
        self.assertTrue(gui.is_destructive(model.Action("d", "remove it", lambda *_: [], confirm=True)))
        self.assertTrue(gui.is_destructive(model.Action("C", "forget all learned hosts", lambda *_: [], confirm=True)))
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
        app = types.SimpleNamespace(root_read_refused=False)
        denied = ([], "✗ Cannot read /x - join the proxy-suite group, or re-run with sudo.")
        asked = []

        def as_root(result):
            return mock.patch.object(model, "load_tab_as_root", lambda tab, via: asked.append(via) or result)

        load = lambda elevated: gui.ProxySuiteGui.load_tab(app, tab, {}, elevated)
        with mock.patch.object(model, "load_tab", lambda tab, states: denied), mock.patch.object(model.os, "geteuid", lambda: 1000):
            with as_root(([{"key": "a"}], "")):
                self.assertIn("Ctrl+E", load(False)[1])
                self.assertEqual(asked, [])
                self.assertEqual(load(True), ([{"key": "a"}], ""))
                self.assertEqual(asked, ["pkexec"])
            with as_root((None, "authentication cancelled")):
                self.assertIn("As root: authentication cancelled", load(True)[1])
                self.assertIn("Ctrl+E twice", load(True)[1])
                self.assertEqual(len(asked), 2)
        with mock.patch.object(model, "load_tab", lambda tab, states: ([], "Nothing here yet.")), as_root(None):
            app.root_read_refused = False
            self.assertEqual(load(True), ([], "Nothing here yet."))  # readable: no pkexec
            self.assertEqual(len(asked), 2)

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
