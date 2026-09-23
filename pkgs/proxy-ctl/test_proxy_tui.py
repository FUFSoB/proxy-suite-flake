#!/usr/bin/env python3
"""Headless proxy-tui: arrows, the action menu and shortcuts turn into the right proxy-ctl argv."""

import asyncio
import contextlib
import io
import signal
import tempfile
import unittest
from unittest import mock

from textual import events

import proxy_ctl as ctl
import proxy_model as model
import proxy_tui as tui


class TuiTest(unittest.TestCase):
    def setUp(self):
        self.units = {"proxy-suite-tun": "inactive"}
        self.zapret = {
            "zapret-hosts-auto.txt": ["learned.example"],
            "zapret-hosts-user.txt": [],
            "zapret-hosts-user-exclude.txt": ["kept.example"],
        }
        self.capture, self.awg, self.current = "", [], mock.Mock(return_value="")
        # The host's own /var/lib/proxy-suite is not the test's.
        state = tempfile.TemporaryDirectory()
        self.addCleanup(state.cleanup)
        self.env = env = {"ZAPRET_AUTO_ENABLED": "1", "STATE_DIR": state.name}
        for target, name, value in [
            (model, "unit_states", lambda units: {u: s for u, s in self.units.items() if u in units}),
            (model, "_capture", lambda argv: self.capture),
            (model, "_lines", lambda name: self.zapret[name]),
            (ctl, "env", lambda name, default="": env.get(name, default)),
            (ctl, "_awg_profiles", lambda: self.awg),
            (ctl, "_route_mode_current", lambda: "default"),
            (ctl, "_route_mode_effective", lambda: "whitelist"),
            (ctl, "_outbound_inventory", lambda: {"tags": ["a", "b"], "pinned": "b", "sources": {"a": "config"}}),
            (ctl, "_outbound_current", model._per_load(self.current)),
            (ctl, "_reputation_by_tag", lambda: {}),
            (ctl, "_runtime_tags", lambda kind: []),
            (ctl, "_sub_tags", lambda: []),
            (ctl, "_status_outbound", lambda: "b (pinned)"),
            (ctl, "_status_autoproxy", lambda: ""),
            (ctl, "_status_zapret", lambda: ""),
            (ctl, "svc_state", lambda unit: ""),
            (ctl, "_inbound_links", lambda: [{"tag": "vless", "user": "alice", "type": "vless", "port": 443}]),
            # No refresh ticks: a tick's load landing mid-test would read everything again.
            (tui, "REFRESH_SECONDS", 3600),
        ]:
            patcher = mock.patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.ran = []
        patcher = mock.patch.object(tui.ProxyTui, "run_argv", lambda app, mode, argv: self.ran.append(argv))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_subscription_age(self):
        with tempfile.NamedTemporaryFile() as cache, mock.patch.multiple(
            ctl,
            _sub_tags=lambda: ["s"],
            _subscription_cache=lambda tag: cache.name,
            _subscription_proxy_count_text=lambda path: "3",
        ):
            self.assertEqual(model.subscription_rows({})[0]["updated"], "0m ago")

    def test_retry_root_leaves_sigint_to_sudo(self):
        """Ctrl-C at sudo's password prompt is sudo's: raised here it would take the TUI down with it."""
        app = mock.MagicMock(retry=("run", ["proxy", "on"]))
        app.suspend.return_value = contextlib.nullcontext()
        before, during = signal.getsignal(signal.SIGINT), []
        with mock.patch.object(tui.subprocess, "Popen") as popen, contextlib.redirect_stdout(io.StringIO()):
            popen.return_value.stdout = iter(["done\n"])
            popen.return_value.wait.side_effect = lambda: during.append(signal.getsignal(signal.SIGINT)) or 0
            tui.ProxyTui.action_retry_root(app)
        self.assertEqual(during, [signal.SIG_IGN])
        self.assertEqual(signal.getsignal(signal.SIGINT), before)
        self.assertEqual(app.finish.call_args.args[-2:], (["done"], 0))

    def test_filter_sort_pack(self):
        rows = [{"key": "a", "host": "a.example", "kind": "learned"}, {"key": "b", "host": "learned.org", "kind": "pinned"}]
        columns = [("host", "Host"), ("kind", "List")]
        keys = lambda text: [r["key"] for r in tui.filter_rows(rows, columns, text)]
        self.assertEqual(keys("learned"), ["a", "b"])
        self.assertEqual(keys("list:learned"), ["a"])  # by heading
        self.assertEqual(keys("kind:pinned LEARNED"), ["b"])  # by field, and every word must match
        self.assertEqual(sorted(["port 2053", "port 443"], key=tui._natural), ["port 443", "port 2053"])
        self.assertEqual(sorted(["b2", "a1²", "a10"], key=tui._natural), ["a1²", "a10", "b2"])  # ² is text, not a number
        # Items never split across lines.
        self.assertEqual(tui.pack(["[b]aaa[/]", "bbb", "ccc"], 9), "[b]aaa[/]   bbb\nccc")

    def test_tab_keys_leave_screen_keys_alone(self):
        """A tab's action key hides the screen's key of the same name while that tab has focus."""
        screen = {k for b in tui.MainScreen.BINDINGS for k in b.key.split(",")}
        same_meaning = {("autoproxy", "w")}  # how is this domain routed: the row's own
        for tab in tui.TABS:
            for action in tab.actions:
                if (tab.id, action.key) not in same_meaning:
                    self.assertNotIn(action.key, screen, f"{tab.id}: {action.label}")

    def test_failed_load_keeps_the_tui_going(self, rows=None):
        async def run():
            tui_trace = tempfile.TemporaryDirectory()
            self.addCleanup(tui_trace.cleanup)
            with mock.patch.dict(tui.os.environ, {"XDG_RUNTIME_DIR": tui_trace.name}):
                with mock.patch.object(model, "load_tab", side_effect=RuntimeError("boom")):
                    app = tui.ProxyTui()
                    async with app.run_test(size=(100, 30)) as pilot:
                        await self.settle(app, pilot)
                        self.assertIn("✗ load failed: boom", str(app.main.query_one("#services-summary").content))
                        with open(tui.trace_path()) as trace:
                            self.assertIn("RuntimeError: boom", trace.read())
                        # Reads work again: the next refresh fills the tab.
                        model.load_tab.side_effect = None
                        model.load_tab.return_value = ([{"key": "u", "unit": "u"}, {"key": "u", "unit": "u again"}], "")
                        app.action_reload()
                        await self.settle(app, pilot)
                        self.assertEqual([k.value for k in app.table("services").rows], ["u", "u#2"])
                        self.assertEqual(app.main.query_one("#services-summary").display, False)

        asyncio.run(run())

    def test_paste_lands_on_the_tab_it_was_pasted_onto(self):
        async def run():
            self.units = {"proxy-suite-socks": "active", **self.units}
            app = tui.ProxyTui()
            async with app.run_test(size=(100, 30)) as pilot:
                await self.settle(app, pilot)
                app.main.query_one("#tabs", tui.TabbedContent).active = "outbounds"
                await self.settle(app, pilot)
                app.post_message(events.Paste("vless://u@de.test:443#DE"))
                await pilot.pause()
                self.assertEqual(self.ran.pop(), ["proxy", "outbounds", "add", "vless://u@de.test:443#DE"])
                # Whatever else was in the clipboard runs nothing, and the bar says why.
                app.post_message(events.Paste("ftp://a.test/x"))
                await pilot.pause()
                self.assertEqual(self.ran, [])
                self.assertIn("ftp:// link", str(app.main.query_one("#feedback").content))

        asyncio.run(run())

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
            self.assertEqual(app.shown, ["services", "zapret"])
            self.assertEqual(app.focused.id, "services-table")

            # The terminal losing focus leaves the TUI as it is.
            app.post_message(events.AppBlur())
            await pilot.pause()
            self.assertEqual((app.app_focus, app.focused.id), (True, "services-table"))

            # Hovering the header, even past its last column, does not highlight it.
            await pilot.hover("#services-table", offset=(90, 0))
            self.assertFalse(app.table()._show_hover_cursor)
            await pilot.hover("#services-table", offset=(90, 1))
            self.assertTrue(app.table()._show_hover_cursor)

            # Tabs follow what runs: socks starting brings its tabs in.
            self.units = {"proxy-suite-socks": "active", **self.units}
            app.action_reload()
            await self.settle(app, pilot)
            self.assertEqual(app.shown, ["services", "routing", "outbounds", "subs", "zapret"])

            # Stopping socks asks first: it takes tun and tproxy down too.
            await pilot.press("up", "space")
            await pilot.pause()
            self.assertIsInstance(app.screen, tui.Confirm)
            await pilot.press("n")
            await pilot.pause()
            self.assertEqual(self.ran, [])

            # Services: space toggles the selected unit.
            await pilot.press("down", "space")
            self.assertEqual(self.ran.pop(), ["proxy", "tun", "on"])

            # A state change updates the row in place; the cursor stays on tun.
            self.units["proxy-suite-tun"] = "active"
            app.action_reload()
            await self.settle(app, pilot)
            self.assertEqual(app.selected_key("services"), "proxy-suite-tun")
            self.assertEqual(str(app.table().get_cell("proxy-suite-tun", "state")), "● active")

            # An active AmneziaWG profile restarts on its own; a failed unit shows in the status bar.
            self.awg = ["p"]
            self.units[model.AWG_PREFIX + "p"] = "active"
            self.units["proxy-suite-ssh-proxy"] = "failed"
            app.action_reload()
            await self.settle(app, pilot)
            self.assertIn("1 failed", tui.pack(tui.status_text(app.states), 100))
            app.table().move_cursor(row=list(app.rows["services"]).index(model.AWG_PREFIX + "p"))
            await pilot.press("ctrl+r")
            self.assertEqual(self.ran.pop(), ["awg", "restart", "p"])
            app.table().move_cursor(row=list(app.rows["services"]).index("proxy-suite-tun"))

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
            # One load asks the backend what it dials once, however many readers need it.
            self.current.reset_mock()
            app.action_reload()
            await self.settle(app, pilot)
            self.assertEqual(self.current.call_count, 1)
            # The footer offers only what applies to the selected row.
            self.assertIn("p", app.screen.active_bindings)
            self.assertNotIn("u", app.screen.active_bindings)
            await pilot.press("p", "t", "u")
            self.assertEqual(self.ran, [["proxy", "pin", "a"], ["proxy", "outbounds", "test", "a"]])
            await pilot.press("down")
            self.assertNotIn("p", app.screen.active_bindings)
            await pilot.press("p", "d", "u")
            self.assertEqual(self.ran.pop(), ["proxy", "unpin"])
            self.ran.clear()
            await pilot.press("enter")
            await pilot.pause()
            self.assertNotIn("pin it", self.menu_labels(app))
            self.assertNotIn("remove it", self.menu_labels(app))
            # Hovering an option selects it: one cursor for mouse and keys.
            await pilot.hover(tui.Choices, offset=(3, 1))
            self.assertEqual(app.screen.query_one(tui.Choices).highlighted, 1)
            await pilot.press("escape")

            # Prompts: add takes "<tag> <url>".
            await pilot.press("n", *"x vless://h", "enter")
            await pilot.pause()
            self.assertEqual(self.ran.pop(), ["proxy", "outbounds", "add", "x", "vless://h"])
            # A prompt remembers what was typed into it last.
            await pilot.press("n")
            await pilot.pause()
            self.assertEqual(app.screen.query_one(tui.Input).value, "x vless://h")
            await pilot.press("escape")

            # An empty tab says how to fill it.
            await pilot.press("4")
            await self.settle(app, pilot)
            self.assertIn("Nothing here yet.   n: add a runtime subscription", str(app.main.query_one("#subs-summary").content))

            # A tab that cannot read its state says so instead, and how to get the rights for it.
            with mock.patch.object(ctl, "_runtime_hidden", lambda kind: "/var/lib/proxy-suite/subscriptions.d"), \
                    mock.patch.object(model.os, "geteuid", lambda: 1000):
                app.action_reload()
                await self.settle(app, pilot)
                summary = str(app.main.query_one("#subs-summary").content)
            self.assertIn("✗ Cannot read /var/lib/proxy-suite/subscriptions.d", summary)
            self.assertIn("#: run proxy-tui as root", summary)

            # zapret: an excluded host can be included again, not forgotten.
            # Brackets in a summary are text, not markup.
            self.env["ZAPRET_CUTOFF_ENABLED"] = "1"
            self.capture = "Probed:  [b] from [/x]\nCutoff:  none on this line\n"
            await pilot.press("5")
            await self.settle(app, pilot)
            self.assertIn("[/x]", str(app.main.query_one("#zapret-summary").content))
            await self.settle(app, pilot)
            await pilot.press("down", "enter")
            await pilot.pause()
            labels = self.menu_labels(app)
            self.assertIn("include it (may be learned again)", labels)
            self.assertNotIn("forget it (may be learned again)", labels)
            await pilot.press("escape", "i")
            self.assertEqual(self.ran.pop(), ["zapret", "auto", "include", "kept.example"])

            # Confirmed actions run only on yes; a click beside a dialog closes it.
            await pilot.press("C")
            await pilot.pause()
            await pilot.click(offset=(0, 0))
            await pilot.pause()
            self.assertIs(app.screen, app.main)
            await pilot.press("C", "n")
            await pilot.pause()
            self.assertEqual(self.ran, [])
            await pilot.press("C", "y")
            await pilot.pause()
            self.assertEqual(self.ran.pop(), ["zapret", "auto", "clear"])

            # / filters the rows on any column; esc shows them all again.
            await pilot.press("slash", *"learned", "enter")
            await self.settle(app, pilot)
            self.assertEqual(list(app.rows["zapret"]), ["learned:learned.example"])
            await pilot.press("escape")
            await self.settle(app, pilot)
            self.assertEqual(len(app.rows["zapret"]), 2)

            # A narrow terminal lists the row's actions on the key line; wider ones in the detail panel instead.
            self.assertIn("forget it", str(app.main.query_one("#keys").content))

            # Clicking a heading sorts by it, again reverses, a third time restores the order.
            order = lambda: [str(app.table().get_row_at(i)[0]) for i in range(app.table().row_count)]
            self.assertEqual(order(), ["learned.example", "kept.example"])
            await pilot.click("#zapret-table", offset=(2, 0))
            self.assertEqual(order(), ["kept.example", "learned.example"])
            self.assertEqual(str(app.table().columns["host"].label), "Host ▲")
            await pilot.click("#zapret-table", offset=(2, 0))
            self.assertEqual(order(), ["learned.example", "kept.example"])
            self.assertEqual(str(app.table().columns["host"].label), "Host ▼")
            await pilot.click("#zapret-table", offset=(2, 0))
            self.assertEqual(order(), ["learned.example", "kept.example"])
            self.assertEqual(str(app.table().columns["host"].label), "Host  ")

            # Inbounds appears once enabled; c copies the share link.
            self.env["INBOUNDS_ENABLED"] = "1"
            app.action_reload()
            await self.settle(app, pilot)
            await pilot.press("6")
            await self.settle(app, pilot)
            await pilot.press("c")
            self.assertEqual(self.ran.pop(), ["inbounds", "link", "vless", "alice"])

            # A reader that dies says why in place of the rows.
            with mock.patch.object(ctl, "_inbound_links", lambda: ctl.die("Share links are not readable")):
                app.action_reload()
                await self.settle(app, pilot)
            self.assertEqual(app.rows["inbounds"], {})
            self.assertIn("Share links are not readable", str(app.main.query_one("#inbounds-summary").content))

            # Closing a dialog stops the command still streaming into it, and what it spawned; c copies what it showed.
            dialog = tui.Output("proxy-ctl proxy outbounds test")
            dialog.proc = mock.Mock(pid=4242, **{"poll.return_value": None})
            app.push_screen(dialog)
            await pilot.pause()
            dialog.write("\x1b[32mok\x1b[0m a")
            with mock.patch.object(app, "copy_to_clipboard") as copy:
                await pilot.press("c")
            copy.assert_called_once_with("ok a")
            with mock.patch.object(model.os, "killpg") as killpg:
                await pilot.press("escape")
                await pilot.pause()
            killpg.assert_called_once_with(4242, model.signal.SIGTERM)

            # A copy only root may make offers ! to retry it under sudo, and still copies.
            with mock.patch.object(model.os, "geteuid", lambda: 1000):
                # The bar is one line: a long error is ellipsized, what to press next is not.
                app.finish("proxy-ctl proxy tun on", ["proxy", "tun", "on"], None, False, [f"Cannot read {'x' * 300} - re-run with sudo."], 1)
                content = str(app.main.query_one("#feedback").content)
                self.assertIn("!: retry as root", content)
                self.assertIn("…", content)

                app.finish("proxy-ctl proxy outbounds link b", ["proxy", "outbounds", "link", "b"], None, True, ["Cannot read x - re-run with sudo."], 1)
                self.assertIn("!: retry as root", str(app.main.query_one("#feedback").content))
                sudo = mock.Mock(stdout=iter(["vless://b\n"]), **{"wait.return_value": 0})
                popen = mock.Mock(return_value=sudo)
                # proxy-tui's own subprocess only: reads in the background spawn through proxy_ctl's.
                with mock.patch.object(app, "suspend", contextlib.nullcontext), \
                        mock.patch.object(tui, "subprocess", mock.Mock(Popen=popen)), \
                        mock.patch.object(model.shutil, "which", lambda name: f"/bin/{name}"), \
                        mock.patch.object(app, "copy_to_clipboard") as copy, \
                        mock.patch("builtins.print"):
                    await pilot.press("exclamation_mark")
                    await pilot.pause()
                self.assertEqual(popen.call_args[0][0], ["sudo", "/bin/proxy-ctl", "proxy", "outbounds", "link", "b"])
                copy.assert_called_once_with("vless://b")
                self.assertIsNone(app.retry)

                # A dialog run only root may do offers it in the dialog itself, and ! there retries.
                dialog = tui.Output("proxy-ctl inbounds stats")
                app.push_screen(dialog)
                await pilot.pause()
                self.assertFalse(dialog.check_action("retry_root", ()))
                app.finish("proxy-ctl inbounds stats", ["inbounds", "stats"], dialog, False, ["Cannot read x - enable userControl, or run with sudo."], 1, stream_shown=True)
                await pilot.pause()
                self.assertIn("retry as root", str(dialog.query_one(".dialog-hint").render()))
                with mock.patch.object(app, "action_retry_root") as retry:
                    await pilot.press("exclamation_mark")
                    await pilot.pause()
                retry.assert_called_once_with()
                self.assertIsNot(app.screen, dialog)


if __name__ == "__main__":
    unittest.main()
