"""proxy-suite-gui: a desktop app, with a tray icon, for everything proxy-tui does.

What it shows and does lives in proxy_model, shared with proxy-tui; this is GTK drawing.
Reads run on a worker thread; every change runs proxy-ctl, as in the TUI.
"""

import os
import re
import shlex
import signal
import subprocess
import sys
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, GObject, Gtk, Pango  # noqa: E402

import proxy_model as model  # noqa: E402
from proxy_model import STATE_ICONS, TABS, ctl  # noqa: E402

APP_ID = "io.github.FUFSoB.ProxySuite"
TITLE = "Proxy Suite"
ICON_DIR = os.environ.get("PROXY_GUI_ICON_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")


def refresh_seconds():
    try:
        return max(1, int(os.environ.get("PROXY_GUI_REFRESH", "3")))
    except ValueError:
        return 3


STATE_CLASSES = {"active": ["success"], "inactive": ["dim-label"], "failed": ["error", "heading"], "activating": ["warning"], "deactivating": ["warning"], "reloading": ["warning"]}
CELL_CLASSES = {
    "ok": ["success"],
    "bad": ["error"],
    "★": ["warning", "heading"],
    "▸": ["success", "heading"],
    "●": ["success", "heading"],
    "runtime": ["accent"],
    "pinned": ["accent"],
    "excluded": ["dim-label"],
    "queued": ["warning"],
    "online": ["success"],
}
TAB_ICONS = {
    "services": "system-run-symbolic",
    "routing": "go-jump-symbolic",
    "outbounds": "network-server-symbolic",
    "subs": "folder-download-symbolic",
    "autoproxy": "web-browser-symbolic",
    "zapret": "channel-secure-symbolic",
    "inbounds": "preferences-system-sharing-symbolic",
    "apps": "view-app-grid-symbolic",
}
STATUS_ICONS = {"ok": "emblem-ok-symbolic", "warn": "dialog-warning-symbolic", "bad": "dialog-error-symbolic", "": "network-wired-symbolic"}

GLOBAL_SHORTCUTS = [
    ("<Control>f slash", "Filter the rows (list:learned for one column)"),
    ("Escape", "Clear the filter"),
    ("Menu <Shift>F10", "Actions for the selected row (or right-click it)"),
    ("<Alt>1...<Alt>8", "Jump to a tab"),
    ("w", "How is a domain routed"),
    ("<Shift>l", "Follow all logs"),
    ("o", "Output of the last command"),
    ("<Control>e", "Run actions as root (pkexec)"),
    ("F5 r", "Refresh now"),
    ("<Control>question", "Keyboard shortcuts"),
    ("<Control>w", "Close the window (the tray keeps running)"),
    ("<Control>q", "Quit"),
]

CSS = """
.status-strip { padding: 2px 12px 10px 12px; }
.status-chip {
  padding: 3px 10px;
  border-radius: 999px;
  background-color: alpha(currentColor, 0.07);
  font-feature-settings: "tnum";
}
.status-chip .chip-label { opacity: 0.65; }
.status-chip .chip-value { font-weight: 600; }
.status-chip.ok { background-color: color-mix(in srgb, var(--success-bg-color) 18%, transparent); color: var(--success-color); }
.status-chip.warn { background-color: color-mix(in srgb, var(--warning-bg-color) 22%, transparent); color: var(--warning-color); }
.status-chip.bad { background-color: color-mix(in srgb, var(--error-bg-color) 18%, transparent); color: var(--error-color); }
.status-chip.ok .chip-label, .status-chip.warn .chip-label, .status-chip.bad .chip-label { opacity: 0.8; }

.summary { padding: 8px 14px 0 14px; }
.filter-bar { padding: 8px 12px; }
.row-count { font-feature-settings: "tnum"; }

.table-card {
  margin: 0 12px 12px 12px;
  border-radius: 12px;
  border: 1px solid var(--border-color);
  background-color: var(--view-bg-color);
}
.table-card > scrolledwindow { border-radius: 12px; }
columnview.data-table { background-color: transparent; }
columnview.data-table > header > button {
  padding: 8px 10px;
  font-size: 0.85em;
  font-weight: 600;
  color: alpha(currentColor, 0.6);
  background-color: alpha(currentColor, 0.03);
}
columnview.data-table > listview > row { min-height: 34px; border-color: alpha(currentColor, 0.06); }
columnview.data-table > listview > row > cell { padding: 0 10px; }
columnview.data-table > listview > row:hover { background-color: alpha(currentColor, 0.04); }
columnview.data-table > listview > row:selected { background-color: alpha(var(--accent-bg-color), 0.2); }
columnview.data-table > listview > row:selected:hover { background-color: alpha(var(--accent-bg-color), 0.26); }
columnview.data-table > listview > row:selected > cell:first-child label { color: var(--accent-color); font-weight: 600; }

.badge {
  padding: 1px 8px;
  border-radius: 999px;
  font-size: 0.9em;
  font-weight: 600;
  background-color: alpha(currentColor, 0.08);
}
.badge.success { background-color: color-mix(in srgb, var(--success-bg-color) 18%, transparent); }
.badge.warning { background-color: color-mix(in srgb, var(--warning-bg-color) 22%, transparent); }
.badge.error { background-color: color-mix(in srgb, var(--error-bg-color) 18%, transparent); }
.badge.accent { background-color: alpha(var(--accent-bg-color), 0.16); }
.badge.dim-label { opacity: 0.7; }

.keycap {
  padding: 0 6px;
  min-width: 12px;
  border-radius: 5px;
  border: 1px solid var(--border-color);
  border-bottom-width: 2px;
  font-family: monospace;
  font-size: 0.85em;
  color: alpha(currentColor, 0.7);
  background-color: alpha(currentColor, 0.04);
}

.detail { padding: 18px; }
.detail-title { margin-bottom: 2px; }
.detail .primary-action { margin-top: 4px; }
.detail .no-actions { margin-top: 12px; }
.empty-actions button { min-width: 240px; }
/* Some themes only lift a hovered button with a shadow, which a dark background hides. */
button.pill:hover { background-image: image(alpha(currentColor, 0.08)); }
button.pill:active { background-image: image(alpha(currentColor, 0.16)); }

.output-card {
  margin: 0 12px 12px 12px;
  border-radius: 12px;
  border: 1px solid var(--border-color);
  background-color: var(--view-bg-color);
}
.output-card > textview, .output-view { background-color: transparent; }
.output-view { font-family: monospace; padding: 12px; }
.qr { background: white; padding: 12px; border-radius: 12px; }
"""


def accelerator(key):
    """A TUI key name as a GTK accelerator: space, ctrl+r, R (shift+r), l."""
    parts = key.split("+")
    mods = "".join({"ctrl": "<Control>", "alt": "<Alt>", "shift": "<Shift>"}[m] for m in parts[:-1])
    name = parts[-1]
    if len(name) == 1 and name.isupper():
        mods, name = mods + "<Shift>", name.lower()
    return mods + name


def display_key(key):
    return key.replace("ctrl+", "Ctrl+").replace("space", "Space")


SGR = re.compile(r"\x1b\[([0-9;]*)m")
ANY_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
SGR_TAGS = {"1": "bold", "2": "dim", "31": "red", "91": "red", "32": "green", "92": "green", "33": "yellow", "93": "yellow", "36": "cyan", "96": "cyan", "35": "magenta", "34": "blue"}


def ansi_segments(line):
    """(text, tags) runs of a line with SGR colors; other escapes dropped."""
    tags, pos, out = set(), 0, []
    for m in SGR.finditer(line):
        if m.start() > pos:
            out.append((ANY_ESCAPE.sub("", line[pos:m.start()]), tuple(sorted(tags))))
        for code in (m.group(1) or "0").split(";"):
            if code in ("0", ""):
                tags.clear()
            elif code in ("22",):
                tags -= {"bold", "dim"}
            elif code == "39":
                tags -= {"red", "green", "yellow", "cyan", "magenta", "blue"}
            elif code in SGR_TAGS:
                tags.add(SGR_TAGS[code])
        pos = m.end()
    if pos < len(line):
        out.append((ANY_ESCAPE.sub("", line[pos:]), tuple(sorted(tags))))
    return out


# (light, dark) foregrounds from the GNOME palette: the dark-theme ones stay readable on a dark view.
ANSI_COLORS = {
    "red": ("#c01c28", "#ff7b63"),
    "green": ("#26a269", "#8ff0a4"),
    "yellow": ("#9c6e03", "#f8e45c"),
    "cyan": ("#1a5fb4", "#99c1f1"),
    "magenta": ("#813d9c", "#dc8add"),
    "blue": ("#1c71d8", "#62a0ea"),
}


def rgba(color):
    value = Gdk.RGBA()
    value.parse(color)
    return value


def plain(line):
    return "".join(t for t, _ in ansi_segments(line))


def last_line(lines):
    return next((plain(line).strip() for line in reversed(lines) if plain(line).strip()), "")


# --- rows -------------------------------------------------------------------------


class RowItem(GObject.Object):
    __gtype_name__ = "ProxySuiteRow"
    version = GObject.Property(type=int, default=0)

    def __init__(self, row):
        super().__init__()
        self.row = row

    def set_row(self, row):
        if row != self.row:
            self.row = row
            self.version += 1
            return True
        return False


def cell_text(name, value):
    value = "" if value is None else str(value)
    if name == "state":
        return f"{STATE_ICONS.get(value, '?')} {value}", STATE_CLASSES.get(value, [])
    return value, CELL_CLASSES.get(value, [])


BADGE_VALUES = {"ok", "bad", "runtime", "pinned", "excluded", "queued", "online"}


def is_badge(name, value):
    """Statuses draw as a tinted pill; markers like ★ stay plain text."""
    return (name == "state" and bool(value)) or str(value) in BADGE_VALUES


def cap(text):
    return text[:1].upper() + text[1:]


def is_destructive(action):
    """Red only for what loses data; stopping or restarting asks first, but stays calm."""
    return action.mode == "run" and action.label.startswith(("remove", "forget"))


def action_icon(action):
    label = action.label.lower()
    if action.prompt:
        return "document-edit-symbolic"
    if "qr" in label:
        return "view-grid-symbolic"
    return {
        "copy": "edit-copy-symbolic",
        "suspend": "format-justify-left-symbolic",
        "pause": "utilities-terminal-symbolic",
        "dialog": "utilities-terminal-symbolic",
    }.get(action.mode, "media-playback-start-symbolic")


def keycap(key):
    return Gtk.Label(label=display_key(key), css_classes=["keycap"], valign=Gtk.Align.CENTER)


class Page(Gtk.Box):
    """One tab: summary, filter, table, and the selected row's detail with its actions."""

    def __init__(self, win, tab):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.win, self.tab = win, tab
        self.rows = []  # the last load, unfiltered
        self.summary_text = ""
        self.detail_shape = None

        self.summary = Gtk.Label(xalign=0, wrap=True, selectable=True, visible=False, css_classes=["summary", "dim-label"])

        self.search = Gtk.SearchEntry(placeholder_text="Filter: words in any column, or column:value", hexpand=True)
        self.search.connect("search-changed", lambda _: self.refill())
        self.search.connect("stop-search", self.on_stop_search)
        self.count = Gtk.Label(css_classes=["dim-label", "caption", "row-count"])
        self.filter_bar = Gtk.Box(spacing=12, css_classes=["filter-bar"])
        self.filter_bar.append(self.search)
        self.filter_bar.append(self.count)

        self.store = Gio.ListStore(item_type=RowItem)
        self.view = Gtk.ColumnView(css_classes=["data-table"], show_row_separators=True, reorderable=False)
        self.sorted = Gtk.SortListModel(model=self.store, sorter=self.view.get_sorter())
        self.selection = Gtk.SingleSelection(model=self.sorted, autoselect=True, can_unselect=False)
        self.selection.connect("notify::selected-item", lambda *_: self.selection_changed())
        self.view.set_model(self.selection)
        self.sorters = []
        for i, (name, heading) in enumerate(tab.columns):
            factory = Gtk.SignalListItemFactory()
            factory.connect("setup", self.cell_setup)
            factory.connect("bind", self.cell_bind, name)
            factory.connect("unbind", self.cell_unbind)
            column = Gtk.ColumnViewColumn(title=heading, factory=factory, resizable=True)
            column.set_expand(i == len(tab.columns) - 1)
            sorter = Gtk.CustomSorter.new(lambda a, b, name: self.compare(a, b, name), name)
            self.sorters.append(sorter)
            column.set_sorter(sorter)
            self.view.append_column(column)
        self.view.connect("activate", lambda view, pos: self.open_menu(None))

        click = Gtk.GestureClick(button=Gdk.BUTTON_SECONDARY)
        click.connect("pressed", self.on_right_click)
        self.view.add_controller(click)
        # On the window, so keys work wherever focus is: an empty tab has no table to focus.
        win.add_controller(self.shortcuts())

        scroller = Gtk.ScrolledWindow(child=self.view, vexpand=True, hexpand=True, overflow=Gtk.Overflow.HIDDEN)
        table = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, css_classes=["table-card"], overflow=Gtk.Overflow.HIDDEN)
        table.append(scroller)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content.append(self.summary)
        content.append(self.filter_bar)
        content.append(table)
        self.detail = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18, css_classes=["detail"])
        detail_scroller = Gtk.ScrolledWindow(child=self.detail, hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.split = Adw.OverlaySplitView(
            content=content, sidebar=detail_scroller, sidebar_position=Gtk.PackType.END, show_sidebar=True,
            min_sidebar_width=280, max_sidebar_width=440, sidebar_width_fraction=0.36,
        )
        self.split.set_vexpand(True)
        self.append(self.split)
        self.tab_icon = TAB_ICONS.get(tab.id, "view-list-symbolic")
        self.empty = Adw.StatusPage(title="Nothing here yet", icon_name=self.tab_icon, visible=False, vexpand=True)
        self.empty.set_child(self.tab_actions_box())
        self.append(self.empty)
        self.popover = None

    # --- cells ---------------------------------------------------------------------

    def cell_setup(self, factory, item):
        item.set_child(Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END, valign=Gtk.Align.CENTER))

    def cell_bind(self, factory, item, name):
        label, row = item.get_child(), item.get_item()

        def paint(*_):
            value = row.row.get(name)
            text, classes = cell_text(name, value)
            badge = bool(text) and is_badge(name, value)
            label.set_text(text)
            label.set_tooltip_text(text if len(text) > 30 else None)
            label.set_css_classes(["badge", *classes] if badge else classes)
            label.set_halign(Gtk.Align.START if badge else Gtk.Align.FILL)

        paint()
        label._handler = (row, row.connect("notify::version", paint))

    def cell_unbind(self, factory, item):
        label = item.get_child()
        if getattr(label, "_handler", None):
            row, handler = label._handler
            row.disconnect(handler)
            label._handler = None

    def compare(self, a, b, name):
        # Text and digit runs alternate in the same places, so the lists always compare.
        ka, kb = model._natural(a.row.get(name)), model._natural(b.row.get(name))
        return (ka > kb) - (ka < kb)

    # --- keys -------------------------------------------------------------------------

    def shortcuts(self):
        controller = Gtk.ShortcutController(propagation_phase=Gtk.PropagationPhase.CAPTURE)
        for i, action in enumerate(self.tab.actions):
            trigger = accelerator(action.key)
            controller.add_shortcut(Gtk.Shortcut(
                trigger=Gtk.ShortcutTrigger.parse_string(trigger),
                action=Gtk.CallbackAction.new(self.keyed(trigger, lambda i=i: self.act(i, from_key=True))),
            ))
        for trigger, callback in (
            ("slash", lambda *_: self.focus_search()),
            ("w", lambda *_: self.win.where()),
            ("<Shift>l", lambda *_: self.win.follow_logs()),
            ("o", lambda *_: self.win.show_last_output()),
            ("r", lambda *_: self.win.app.reload()),
            ("Menu|<Shift>F10", lambda *_: self.open_menu(None)),
        ):
            if not any(accelerator(a.key) == trigger for a in self.tab.actions):
                controller.add_shortcut(Gtk.Shortcut(trigger=Gtk.ShortcutTrigger.parse_string(trigger), action=Gtk.CallbackAction.new(self.keyed(trigger, callback))))
        return controller

    def keyed(self, trigger, callback):
        """A key for this tab only while it shows, and never one meant for a text field, a dialog or a focused button."""
        def run(*_):
            if self.win.page() is not self or self.win.get_visible_dialog() is not None:
                return False
            focus = self.win.get_focus()
            if isinstance(focus, Gtk.Editable):
                return False
            if trigger in ("space", "Return") and not (focus is self.view or (focus and focus.is_ancestor(self.view))):
                return False
            return callback() is not False
        return run

    def focus_default(self):
        if self.split.get_visible():
            self.view.grab_focus()
        else:
            self.empty.child_focus(Gtk.DirectionType.TAB_FORWARD)

    def focus_search(self):
        return self.search.get_mapped() and self.search.grab_focus()

    def on_stop_search(self, entry):
        entry.set_text("")
        self.view.grab_focus()

    # --- filling ------------------------------------------------------------------------

    def fill(self, rows, summary):
        self.rows, self.summary_text = rows, summary
        self.refill()

    def refill(self):
        rows, summary = self.rows, self.summary_text
        if text := self.search.get_text().strip():
            rows = model.filter_rows(rows, self.tab.columns, text)
            self.count.set_text(f"{len(rows)} of {len(self.rows)}")
        else:
            self.count.set_text(f"{len(rows)} row{'' if len(rows) == 1 else 's'}")
        self.summary.set_text(summary)
        keys = [r["key"] for r in rows]
        current = [self.store.get_item(i).row["key"] for i in range(self.store.get_n_items())]
        if keys == current:
            # The same rows: cells repaint themselves, so selection and scroll stay put.
            changed = False
            for i, r in enumerate(rows):
                changed |= self.store.get_item(i).set_row(r)
            if changed:
                for sorter in self.sorters:
                    sorter.changed(Gtk.SorterChange.DIFFERENT)
        else:
            selected = self.selected_key()
            self.store.splice(0, self.store.get_n_items(), [RowItem(r) for r in rows])
            if selected in keys:
                for pos in range(self.sorted.get_n_items()):
                    if self.sorted.get_item(pos).row["key"] == selected:
                        self.selection.set_selected(pos)
                        break
        empty = not self.rows and not text
        self.split.set_visible(not empty)
        self.empty.set_visible(empty)
        self.summary.set_visible(bool(summary) and not empty)
        if empty:
            unreadable = summary.startswith("✗")
            self.empty.set_title("Cannot read this" if unreadable else "Nothing here yet")
            self.empty.set_icon_name("dialog-error-symbolic" if unreadable else self.tab_icon)
            self.empty.set_description(GLib.markup_escape_text(summary.removeprefix("Nothing here yet.").strip()))
        if self.win.page() is self:
            self.win.sync_details_toggle()
        self.selection_changed()

    def selected_row(self):
        item = self.selection.get_selected_item()
        return item.row if item else None

    def selected_key(self):
        row = self.selected_row()
        return row["key"] if row else None

    # --- detail and actions -----------------------------------------------------------------

    def tab_actions_box(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, halign=Gtk.Align.CENTER, css_classes=["empty-actions"])
        tab_actions = [(i, a) for i, a in enumerate(self.tab.actions) if a.when is None]
        for n, (i, action) in enumerate(tab_actions):
            box.append(self.action_button(i, action, suggested=n == 0))
        return box

    def action_button(self, i, action, suggested=False):
        content = Adw.ButtonContent(icon_name=action_icon(action), label=cap(action.label))
        button = Gtk.Button(child=content, css_classes=["pill"], tooltip_text=f"Shortcut: {display_key(action.key)}")
        if is_destructive(action):
            button.add_css_class("destructive-action")
        elif suggested:
            button.add_css_class("suggested-action")
        button.connect("clicked", lambda *_: self.act(i))
        return button

    def action_row(self, i, action):
        item = Adw.ActionRow(title=cap(action.label), use_markup=False, activatable=True)
        item.add_prefix(Gtk.Image(icon_name=action_icon(action)))
        if action.key:
            item.add_suffix(keycap(action.key))
        if is_destructive(action):
            item.add_css_class("error")
        item.connect("activated", lambda *_: self.act(i))
        return item

    def selection_changed(self):
        row = self.selected_row()
        actions = model.applicable(self.tab, row)
        shape = (repr(row), [a.label for a in actions])
        if shape == self.detail_shape:
            return
        self.detail_shape = shape
        while child := self.detail.get_first_child():
            self.detail.remove(child)
        row_actions = [a for a in actions if a.when is not None]
        tab_actions = [a for a in actions if a.when is None]
        if row:
            header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            header.append(Gtk.Label(label=row["key"], xalign=0, wrap=True, wrap_mode=Pango.WrapMode.WORD_CHAR, selectable=True, css_classes=["title-3", "detail-title"]))
            if row.get("state"):
                text, classes = cell_text("state", row["state"])
                header.append(Gtk.Label(label=text, halign=Gtk.Align.START, css_classes=["badge", *classes]))
            if row_actions:
                primary = row_actions.pop(0)
                button = self.action_button(self.tab.actions.index(primary), primary, suggested=True)
                button.add_css_class("primary-action")
                header.append(button)
            self.detail.append(header)

            fields, shown = Adw.PreferencesGroup(title="Details"), 0
            for name, heading in self.tab.columns:
                value = row.get(name)
                text, classes = cell_text(name, value)
                if not heading or not text or name == "state":
                    continue
                if is_badge(name, value):
                    item = Adw.ActionRow(title=heading, use_markup=False)
                    item.add_suffix(Gtk.Label(label=text, valign=Gtk.Align.CENTER, css_classes=["badge", *classes]))
                else:
                    item = Adw.ActionRow(title=heading, subtitle=text, use_markup=False, subtitle_selectable=True, css_classes=["property"])
                fields.add(item)
                shown += 1
            if shown:
                self.detail.append(fields)
        for heading, group in (("Actions", row_actions), (self.tab.title, tab_actions)):
            if not group:
                continue
            section = Adw.PreferencesGroup(title=heading)
            for action in group:
                section.add(self.action_row(self.tab.actions.index(action), action))
            self.detail.append(section)
        if not actions:
            self.detail.append(Gtk.Label(label="No actions here.", css_classes=["dim-label", "no-actions"]))

    def act(self, index, from_key=False):
        action, row = self.tab.actions[index], self.selected_row()
        if action not in model.applicable(self.tab, row):
            return from_key is False  # a key that does not apply falls through
        self.win.perform(action, row)
        return True

    def on_right_click(self, gesture, n, x, y):
        # Select the row under the pointer first: its cell labels know their row.
        widget = self.view.pick(x, y, Gtk.PickFlags.DEFAULT)
        while widget is not None and widget is not self.view:
            for candidate in (widget, widget.get_first_child()):
                if handler := getattr(candidate, "_handler", None):
                    self.select_item(handler[0])
                    widget = None
                    break
            else:
                widget = widget.get_parent()
        rect = Gdk.Rectangle()
        rect.x, rect.y, rect.width, rect.height = int(x), int(y), 1, 1
        self.open_menu(rect)

    def select_item(self, item):
        for pos in range(self.sorted.get_n_items()):
            if self.sorted.get_item(pos) is item:
                self.selection.set_selected(pos)
                return

    def open_menu(self, rect):
        row = self.selected_row()
        actions = model.applicable(self.tab, row)
        if not actions:
            self.win.toast(f"No actions for {row['key'] if row else self.tab.title}.")
            return True
        menu = Gio.Menu()
        section = Gio.Menu()
        for action in actions:
            label = cap(action.label)
            item = Gio.MenuItem.new(label, None)
            item.set_action_and_target_value("win.act", GLib.Variant("(si)", (self.tab.id, self.tab.actions.index(action))))
            item.set_attribute_value("accel", GLib.Variant("s", accelerator(action.key)))
            (section if action.when is not None else menu).append_item(item)
        menu.prepend_section(None, section)
        if self.popover:
            self.popover.unparent()
        self.popover = Gtk.PopoverMenu(menu_model=menu, has_arrow=rect is not None)
        self.popover.set_parent(self.view if self.view.get_mapped() else self.empty)
        if rect is None:
            rect = Gdk.Rectangle()
            rect.x, rect.y, rect.width, rect.height = 24, 24, 1, 1
        self.popover.set_pointing_to(rect)
        self.popover.popup()
        return True


# --- dialogs ----------------------------------------------------------------------------


class OutputDialog(Adw.Dialog):
    """A command's output, streamed while it runs; a link that was asked for as QR shows the code."""

    def __init__(self, win, title, text=None, keep_running=False):
        super().__init__(title=title, content_width=820, content_height=560)
        self.win, self.proc, self.keep_running = win, None, keep_running
        self.lines = []
        view = Adw.ToolbarView()
        header = Adw.HeaderBar(title_widget=Adw.WindowTitle(title="Output", subtitle=title))
        self.copy = Gtk.Button(icon_name="edit-copy-symbolic", tooltip_text="Copy the output")
        self.copy.connect("clicked", lambda *_: self.win.copy_text("\n".join(plain(line) for line in self.lines), "Copied the output."))
        header.pack_start(self.copy)
        self.stop = Gtk.Button(label="Stop", css_classes=["destructive-action"], visible=False, valign=Gtk.Align.CENTER)
        self.stop.connect("clicked", lambda *_: self.terminate())
        header.pack_end(self.stop)
        self.retry_with = None  # () -> run it again as root
        self.retry = Gtk.Button(label="Retry as Root", css_classes=["suggested-action"], visible=False, valign=Gtk.Align.CENTER)
        self.retry.connect("clicked", lambda *_: (self.close(), self.retry_with()))
        header.pack_end(self.retry)
        self.spinner = Adw.Spinner(visible=False)
        header.pack_end(self.spinner)
        self.result = Gtk.Label(visible=False, valign=Gtk.Align.CENTER)
        header.pack_end(self.result)
        view.add_top_bar(header)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.qr = Gtk.Picture(visible=False, can_shrink=True, content_fit=Gtk.ContentFit.CONTAIN, css_classes=["qr"], halign=Gtk.Align.CENTER)
        self.qr.set_size_request(280, 280)
        self.qr.set_margin_top(6)
        self.qr.set_margin_bottom(12)
        box.append(self.qr)
        self.buffer = Gtk.TextBuffer()
        self.tags = {name: self.buffer.create_tag(name) for name in ("bold", "dim", *ANSI_COLORS)}
        self.tags["bold"].set_property("weight", Pango.Weight.BOLD)
        self.text = Gtk.TextView(buffer=self.buffer, editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR, css_classes=["output-view"], cursor_visible=False)
        # Themes can be dark without Adwaita knowing, so the text color decides.
        self.text.connect("map", self.paint_tags)
        style = Adw.StyleManager.get_default()
        dark_handler = style.connect("notify::dark", lambda *_: GLib.idle_add(lambda: self.paint_tags() and False))
        self.connect("closed", lambda *_: style.disconnect(dark_handler))
        self.scroller = Gtk.ScrolledWindow(child=self.text, vexpand=True)
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, css_classes=["output-card"], overflow=Gtk.Overflow.HIDDEN)
        card.append(self.scroller)
        box.append(card)
        view.set_content(box)
        self.set_child(view)
        self.follow = text is None
        if text is not None:
            for line in text.splitlines():
                self.write(line)
        self.connect("closed", lambda *_: None if self.keep_running else self.terminate())

    def paint_tags(self, *_):
        fg = self.text.get_color()
        dark = 0.299 * fg.red + 0.587 * fg.green + 0.114 * fg.blue > 0.5
        for name, (light_color, dark_color) in ANSI_COLORS.items():
            self.tags[name].set_property("foreground_rgba", rgba(dark_color if dark else light_color))
        self.tags["dim"].set_property("foreground_rgba", rgba("#9a9996" if dark else "#77767b"))

    def running(self, proc, stoppable=True):
        self.proc = proc
        self.stop.set_visible(stoppable)  # a run as root is not ours to stop
        self.spinner.set_visible(True)

    def finished(self, status=0, retry=None):
        self.stop.set_visible(False)
        self.spinner.set_visible(False)
        self.retry.set_visible(retry is not None)
        self.retry_with = retry
        if status == -signal.SIGTERM:
            text, classes = "stopped", ["dim-label"]
        elif status:
            text, classes = f"exit {status}", ["error"]
        else:
            text, classes = "done", ["success"]
        self.result.set_text(text)
        self.result.set_css_classes(["badge", *classes])
        self.result.set_visible(True)

    def write(self, line):
        self.lines.append(line)
        end = self.buffer.get_end_iter()
        if self.buffer.get_char_count():
            self.buffer.insert(end, "\n")
        for text, tags in ansi_segments(line):
            end = self.buffer.get_end_iter()
            if tags:
                self.buffer.insert_with_tags_by_name(end, text, *tags)
            else:
                self.buffer.insert(end, text)
        if self.follow:
            adj = self.scroller.get_vadjustment()
            GLib.idle_add(lambda: adj.set_value(adj.get_upper()) and False)

    def show_qr(self, text):
        try:
            png = subprocess.run(["qrencode", "-t", "PNG", "-s", "8", "-m", "2", "-o", "-"], input=text.encode(), capture_output=True, check=True).stdout
        except (OSError, subprocess.CalledProcessError):
            self.write("\x1b[33m(qrencode is missing: no QR code)\x1b[0m")
            return
        self.qr.set_paintable(Gdk.Texture.new_from_bytes(GLib.Bytes.new(png)))
        self.qr.set_visible(True)

    def terminate(self):
        model.stop(self.proc)


# --- window -------------------------------------------------------------------------------


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title=TITLE, default_width=1100, default_height=700, icon_name=APP_ID)
        self.app = app
        self.set_size_request(360, 360)
        self.pages = {}
        self.typed = {}  # action label -> what was last typed there
        self.last_output = None  # (title, text)
        self.last_retry = None  # () -> the last run again as root, when only root could do it

        self.toasts = Adw.ToastOverlay()
        view = Adw.ToolbarView(top_bar_style=Adw.ToolbarStyle.RAISED)
        header = Adw.HeaderBar()
        self.stack = Adw.ViewStack(vexpand=True)
        switcher = Adw.ViewSwitcher(stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        header.set_title_widget(switcher)
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Refresh now (F5)")
        refresh.connect("clicked", lambda *_: app.reload())
        # A slow load shows a spinner in the refresh button's place.
        self.refresh_stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.refresh_stack.add_named(refresh, "idle")
        self.refresh_stack.add_named(Adw.Spinner(halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER), "busy")
        self.busy_timer = None
        header.pack_start(self.refresh_stack)
        self.root_badge = Gtk.Image(icon_name="dialog-password-symbolic", tooltip_text="Actions run as root (Ctrl+E)", visible=app.elevated(), css_classes=["warning"])
        header.pack_start(self.root_badge)
        menu = Gio.Menu()
        section = Gio.Menu()
        section.append("How is a domain routed…", "win.where")
        section.append("Follow all logs", "win.logs")
        section.append("Output of the last command", "win.last-output")
        menu.append_section(None, section)
        section = Gio.Menu()
        section.append("Run actions as root", "app.elevated")
        menu.append_section(None, section)
        section = Gio.Menu()
        section.append("Keyboard Shortcuts", "win.shortcuts")
        section.append("About Proxy Suite", "win.about")
        section.append("Quit", "app.quit")
        menu.append_section(None, section)
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu, primary=True, tooltip_text="Main menu"))
        # Narrow windows fold the details and actions away: this brings them over the table.
        self.details_toggle = Gtk.ToggleButton(icon_name="sidebar-show-right-symbolic", tooltip_text="Details and actions", visible=False)
        self.details_toggle.connect("toggled", lambda b: self.page() and self.page().split.set_show_sidebar(b.get_active()))
        header.pack_end(self.details_toggle)
        view.add_top_bar(header)

        self.status = Adw.WrapBox(child_spacing=18, line_spacing=2, css_classes=["status-strip"])
        self.status_items = None
        view.add_top_bar(self.status)
        self.banner = Adw.Banner(title="", revealed=False, button_label="Retry", action_name="app.reload")
        view.add_top_bar(self.banner)

        for tab in TABS:
            page = Page(self, tab)
            self.pages[tab.id] = page
            self.stack.add_titled_with_icon(page, tab.id, tab.title, TAB_ICONS.get(tab.id, "view-list-symbolic"))
        self.stack.connect("notify::visible-child", lambda *_: self.on_tab_changed())
        self.bar = Adw.ViewSwitcherBar(stack=self.stack)
        view.set_content(self.stack)
        view.add_bottom_bar(self.bar)
        breakpoint = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 720sp"))
        breakpoint.add_setter(switcher, "visible", GObject.Value(bool, False))
        breakpoint.add_setter(self.bar, "reveal", GObject.Value(bool, True))
        breakpoint.add_setter(self.details_toggle, "visible", GObject.Value(bool, True))
        for page in self.pages.values():
            breakpoint.add_setter(page.split, "collapsed", GObject.Value(bool, True))
            breakpoint.add_setter(page.split, "show-sidebar", GObject.Value(bool, False))
            page.split.connect("notify::show-sidebar", lambda split, _: self.page() is not None and split is self.page().split and self.sync_details_toggle())
        self.add_breakpoint(breakpoint)

        self.toasts.set_child(view)
        self.set_content(self.toasts)

        for name, callback, param in (
            ("where", lambda *_: self.where(), None),
            ("logs", lambda *_: self.follow_logs(), None),
            ("last-output", lambda *_: self.show_last_output(), None),
            ("shortcuts", lambda *_: self.show_shortcuts(), None),
            ("about", lambda *_: self.show_about(), None),
            ("filter", lambda *_: self.page().focus_search(), None),
            ("act", self.on_act, GLib.VariantType.new("(si)")),
            ("tab", lambda _, p: self.jump(p.get_int32()), GLib.VariantType.new("i")),
        ):
            action = Gio.SimpleAction.new(name, param)
            action.connect("activate", callback)
            self.add_action(action)
        app.set_accels_for_action("win.filter", ["<Control>f"])
        app.set_accels_for_action("app.elevated", ["<Control>e"])
        app.set_accels_for_action("win.shortcuts", ["<Control>question"])
        app.set_accels_for_action("app.reload", ["F5"])
        app.set_accels_for_action("app.quit", ["<Control>q"])
        app.set_accels_for_action("window.close", ["<Control>w"])
        for n in range(1, 9):
            app.set_accels_for_action(f"win.tab({n - 1})", [f"<Alt>{n}"])

        self.connect("close-request", self.on_close)

    # --- tabs ----------------------------------------------------------------------------------

    def page(self):
        return self.stack.get_visible_child()

    def shown(self):
        return [tab.id for tab in TABS if self.stack.get_page(self.pages[tab.id]).get_visible()]

    def show_tabs(self, visible):
        for tab in TABS:
            self.stack.get_page(self.pages[tab.id]).set_visible(tab.id in visible)
        if self.stack.get_visible_child_name() not in visible and visible:
            self.stack.set_visible_child_name(visible[0])
        # The bar counts visible tabs only when told to reveal, so hiding tabs could leave it folded away.
        reveal = self.bar.get_reveal()
        self.bar.set_reveal(not reveal)
        self.bar.set_reveal(reveal)

    def jump(self, index):
        shown = self.shown()
        if 0 <= index < len(shown):
            self.stack.set_visible_child_name(shown[index])

    def sync_details_toggle(self):
        if page := self.page():
            self.details_toggle.set_active(page.split.get_show_sidebar())
            self.details_toggle.set_sensitive(page.split.get_visible())

    def on_tab_changed(self):
        page = self.page()
        if page:
            self.sync_details_toggle()
            page.focus_default()
            self.app.reload()

    def set_busy(self, busy):
        if self.busy_timer:
            GLib.source_remove(self.busy_timer)
            self.busy_timer = None
        if busy:
            self.busy_timer = GLib.timeout_add(400, self.show_busy)
        else:
            self.refresh_stack.set_visible_child_name("idle")

    def show_busy(self):
        self.busy_timer = None
        self.refresh_stack.set_visible_child_name("busy")
        return False

    def show_status(self, items):
        # Only a change rebuilds the chips: the refresh tick sends the same items every few seconds.
        if items == self.status_items:
            return
        self.status_items = items
        while child := self.status.get_first_child():
            self.status.remove(child)
        for n, (label, value, style) in enumerate(items):
            chip = Gtk.Box(spacing=6, css_classes=["status-chip", *([style] if style else [])])
            if n == 0:
                chip.append(Gtk.Image(icon_name=STATUS_ICONS[style], pixel_size=14))
            if label:
                chip.append(Gtk.Label(label=label.strip(), css_classes=["chip-label"]))
            chip.append(Gtk.Label(label=value, css_classes=["chip-value"], ellipsize=Pango.EllipsizeMode.END))
            self.status.append(chip)

    def fill(self, states, visible, status, tab_id, rows, summary):
        self.show_status(status)
        unreadable = not states
        self.banner.set_title("Cannot read service states: is systemd reachable?" if unreadable else "")
        self.banner.set_revealed(unreadable)
        if visible != self.shown():
            self.show_tabs(visible)
        if tab_id in self.pages and tab_id in visible:
            self.pages[tab_id].fill(rows, summary)

    # --- acting ----------------------------------------------------------------------------------

    def on_act(self, _, param):
        tab_id, index = param.unpack()
        page = self.pages[tab_id]
        action, row = page.tab.actions[index], page.selected_row()
        if action in model.applicable(page.tab, row):
            self.perform(action, row)

    def where(self):
        self.perform(model.WHERE, None)
        return True

    def follow_logs(self):
        self.app.run_argv("suspend", ["logs"], self)
        return True

    def show_last_output(self):
        if self.last_output:
            dialog = OutputDialog(self, *self.last_output)
            dialog.retry.set_visible(self.last_retry is not None)
            dialog.retry_with = self.last_retry
            dialog.present(self)
        else:
            self.toast("Nothing has run yet.")
        return True

    def perform(self, action, row):
        def with_text(text=""):
            try:
                argv = action.argv(row, text, self.app.states)
            except (ValueError, IndexError) as e:
                self.toast(f"Cannot run that: {e}")
                return
            if model.needs_confirm(action, row):
                self.app.confirm(argv, lambda: self.app.run_argv(action.mode, argv, self), self)
            else:
                self.app.run_argv(action.mode, argv, self)

        if not action.prompt:
            with_text()
            return
        title = action.label.removesuffix("…")
        dialog = Adw.AlertDialog(heading=cap(title), close_response="cancel", default_response="run")
        entry = Gtk.Entry(placeholder_text=action.prompt, text=self.typed.get(action.label, ""), activates_default=True, width_chars=40)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("run", "Run")
        dialog.set_response_appearance("run", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_response_enabled("run", bool(entry.get_text().strip()))
        entry.connect("changed", lambda e: dialog.set_response_enabled("run", bool(e.get_text().strip())))

        def responded(_, response):
            text = entry.get_text().strip()
            if response == "run" and text:
                self.typed[action.label] = text
                with_text(text)

        dialog.connect("response", responded)
        dialog.present(self)
        entry.grab_focus()

    def toast(self, message, output=None, retry=None):
        toast = Adw.Toast(title=GLib.markup_escape_text(message), timeout=6)
        if retry:  # one button: the output stays a keypress away (o)
            toast.set_button_label("Retry as Root")
            toast.connect("button-clicked", lambda *_: retry())
        elif output:
            toast.set_button_label("Output")
            toast.connect("button-clicked", lambda *_: OutputDialog(self, *output).present(self))
        self.toasts.add_toast(toast)

    def copy_text(self, text, message):
        self.get_clipboard().set(text)
        self.toast(message)

    def show_shortcuts(self):
        dialog = Adw.ShortcutsDialog()
        page = self.page()
        if page and page.tab.actions:
            section = Adw.ShortcutsSection(title=page.tab.title)
            for action in page.tab.actions:
                section.add(Adw.ShortcutsItem(title=cap(action.label), accelerator=accelerator(action.key)))
            dialog.add(section)
        section = Adw.ShortcutsSection(title="Everywhere")
        for accel, title in GLOBAL_SHORTCUTS:
            section.add(Adw.ShortcutsItem(title=title, accelerator=accel))
        dialog.add(section)
        dialog.present(self)
        return True

    def show_about(self):
        Adw.AboutDialog(
            application_name=TITLE, application_icon=APP_ID, developer_name="proxy-suite-flake",
            comments="Everything proxy-ctl controls, in a window and the tray.",
            website="https://github.com/FUFSoB/proxy-suite-flake", license_type=Gtk.License.CUSTOM,
        ).present(self)

    def on_close(self, _):
        if self.app.tray and self.app.tray.available:
            self.set_visible(False)
            return True  # the tray icon brings it back
        self.app.quit()
        return False


# --- application --------------------------------------------------------------------------------


class ProxySuiteGui(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.add_main_option("hidden", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Start in the tray, without a window", None)
        self.add_main_option("tab", 0, GLib.OptionFlags.NONE, GLib.OptionArg.STRING, "Open this tab: " + ", ".join(t.id for t in TABS), "ID")
        self.add_main_option("refresh", 0, GLib.OptionFlags.NONE, GLib.OptionArg.INT, "Seconds between refreshes", "SECONDS")
        self.window = None
        self.tray = None
        self.states = {}
        self.refresh = refresh_seconds()
        self.loading = False
        self.pending = False
        self.generation = 0
        self.failed = None  # units in failed state at the last load; None before the first
        self.timer = None

    def do_startup(self):
        Adw.Application.do_startup(self)
        display = Gdk.Display.get_default()
        if display:
            Gtk.IconTheme.get_for_display(display).add_search_path(ICON_DIR)
            css = Gtk.CssProvider()
            css.load_from_string(CSS)
            # Above a user gtk.css theme: these rules are only for this window's own classes.
            Gtk.StyleContext.add_provider_for_display(display, css, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
        for name, callback in (("quit", lambda *_: self.quit()), ("reload", lambda *_: self.reload()), ("present", lambda *_: self.present())):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", callback)
            self.add_action(action)
        elevated = Gio.SimpleAction.new_stateful("elevated", None, GLib.Variant.new_boolean(False))
        elevated.connect("change-state", self.on_elevated)
        self.add_action(elevated)
        retry = Gio.SimpleAction.new("retry-root", GLib.VariantType.new("as"))
        retry.connect("activate", lambda _, argv: self.run_argv("run", argv.unpack(), None, root=True))
        self.add_action(retry)
        self.hold()  # the tray and notifications outlive the window
        try:
            from proxy_sni import StatusNotifierItem

            self.tray = StatusNotifierItem(
                self.get_dbus_connection(), APP_ID, TITLE, ICON_DIR,
                on_activate=self.toggle_window, on_menu=self.on_tray_menu, on_available=self.on_tray_available,
            )
        except (GLib.Error, ImportError) as e:
            print(f"proxy-suite-gui: no tray icon: {e}", file=sys.stderr)

    def do_command_line(self, command_line):
        options = command_line.get_options_dict().end().unpack()
        if "refresh" in options and options["refresh"] > 0:
            self.refresh = options["refresh"]
            if self.timer:
                GLib.source_remove(self.timer)
                self.timer = None
        if self.timer is None:
            self.timer = GLib.timeout_add_seconds(self.refresh, self.tick)
            self.reload()
        if not options.get("hidden"):
            self.present(options.get("tab"))
        return 0

    def do_activate(self):
        self.present()

    def do_shutdown(self):
        if self.tray:
            self.tray.close()
        Adw.Application.do_shutdown(self)

    # --- window ------------------------------------------------------------------------------

    def elevated(self):
        return self.lookup_action("elevated").get_state().get_boolean()

    def on_elevated(self, action, value):
        action.set_state(value)
        if self.window:
            self.window.root_badge.set_visible(value.get_boolean())

    def present(self, tab=None):
        if self.window is None:
            self.window = Window(self)
            self.window.show_tabs(model.available_tabs(self.states) if self.states else ["services"])
        if tab and tab in self.window.pages:
            self.window.stack.set_visible_child_name(tab)
        self.window.present()
        if page := self.window.page():
            page.focus_default()
        self.reload()

    def toggle_window(self):
        if self.window and self.window.get_visible() and self.window.is_active():
            self.window.set_visible(False)
        else:
            self.present()

    def on_tray_available(self, available):
        if not available and self.window is None:
            # Started hidden, and nothing shows the tray: no way back to the window but this.
            GLib.timeout_add_seconds(5, lambda: (self.present() if not self.tray.available and self.window is None else None) and False)

    # --- loads ----------------------------------------------------------------------------------

    def tick(self):
        self.reload()
        return True

    def reload(self):
        if self.loading:
            self.pending = True  # one more once this load lands
            return
        self.loading = True
        self.generation += 1
        window = self.window if self.window and self.window.get_visible() else None
        if window:
            window.set_busy(True)
        tab = window.pages[window.stack.get_visible_child_name()].tab if window and window.stack.get_visible_child_name() else None
        threading.Thread(target=self.load, args=(self.generation, tab), daemon=True).start()

    def load(self, generation, tab):
        model.new_load()
        states = model._read_states()
        snap = model.snapshot(states) if states else None
        outbound = model._safe(ctl._status_outbound, fallback="") if snap and snap["proxy"]["active"] else ""
        tray = (model.tray_menu(snap, model.tray_outbounds(snap)), ctl._overall_state(snap), outbound)
        result = {"states": states, "snap": snap, "tray": tray}
        if tab is not None:
            result["visible"] = model.available_tabs(states)
            result["status"] = model._safe(model.status_items, states, fallback=[("", "Status unavailable", "bad")])
            result["tab"] = (tab.id, *model.load_tab(tab, states))
        GLib.idle_add(self.landed, generation, result)

    def landed(self, generation, result):
        self.loading = False
        if self.window:
            self.window.set_busy(False)
        if generation == self.generation:
            self.states = result["states"]
            snap = result["snap"]
            tree, overall, outbound = result["tray"]
            if self.tray:
                failed = snap["failed"] if snap else []
                tooltip = overall["label"] + (f"\nOutbound: {outbound}" if outbound else "") + (f"\nFailed: {', '.join(failed)}" if failed else "")
                self.tray.update(model.icon_name(overall), tooltip, tree, attention=bool(failed))
            self.notify_failures(snap)
            if "tab" in result and self.window:
                self.window.fill(self.states, result["visible"], result["status"], *result["tab"])
        if self.pending:
            self.pending = False
            self.reload()
        return False

    def notify_failures(self, snap):
        if snap is None:
            return
        failed = set(snap["failed"])
        if self.failed is not None:
            for unit in sorted(failed - self.failed):
                note = Gio.Notification.new(f"{unit} failed")
                note.set_body(f"See its logs: proxy-ctl logs {unit}")
                note.set_priority(Gio.NotificationPriority.HIGH)
                note.set_default_action("app.present")
                self.send_notification(f"failed-{unit}", note)
            for unit in self.failed - failed:
                self.withdraw_notification(f"failed-{unit}")
        self.failed = failed

    # --- running proxy-ctl ---------------------------------------------------------------------------

    def on_tray_menu(self, item):
        if item.app == "open":
            self.present()
        elif item.app == "quit":
            self.quit()
        elif item.argv:
            run = lambda: self.run_argv("run", item.argv, None)
            if item.confirm:
                self.confirm(item.argv, run, self.window if self.window and self.window.get_visible() else None)
            else:
                run()

    def confirm(self, argv, then, parent):
        body = f"<tt>{GLib.markup_escape_text(f'proxy-ctl {shlex.join(argv)}')}</tt>"
        dialog = Adw.AlertDialog(heading="Run this?", body=body, body_use_markup=True, close_response="cancel", default_response="run")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("run", "Run")
        dialog.set_response_appearance("run", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.connect("response", lambda _, r: r == "run" and then())
        dialog.present(parent)

    def run_argv(self, mode, argv, win, root=False):
        """run: a toast; dialog, suspend, pause: output streamed into a dialog; copy: the last line to the clipboard.
        root, or the elevated toggle: through pkexec. Never `apps run`, which is per user."""
        root = (root or self.elevated()) and argv[:1] != ["apps"]
        command = f"{'pkexec ' if root else ''}proxy-ctl {shlex.join(argv)}"
        retry_argv = argv
        qr = "--qr" in argv
        if qr:
            argv = [a for a in argv if a != "--qr"]
        dialog = None
        if win is not None and mode in ("dialog", "suspend", "pause"):
            dialog = OutputDialog(win, command, keep_running=mode == "pause")
            dialog.present(win)
        elif win is not None:
            win.toast(f"… {command}")
        threading.Thread(target=self.stream, args=(command, argv, mode, win, dialog, qr, root, retry_argv), daemon=True).start()

    def stream(self, command, argv, mode, win, dialog, qr, root, retry_argv):
        out = []
        try:
            p = model.popen(argv, "pkexec" if root else None)
            if dialog:
                GLib.idle_add(lambda: dialog.running(p, stoppable=not root) and False)
            for line in p.stdout:
                out.append(line.rstrip("\n"))
                if dialog:
                    GLib.idle_add(lambda line=out[-1]: dialog.write(line) and False)
            status = p.wait()
        except OSError as e:
            out.append(f"cannot run proxy-ctl: {e}")
            status = 127
        if root and status == 126 and not out:
            out.append("authentication cancelled")  # pkexec: the password dialog was dismissed
        GLib.idle_add(lambda: self.ran(command, mode, win, dialog, qr, out, status, retry_argv) and False)

    def ran(self, command, mode, win, dialog, qr, out, status, retry_argv):
        last = last_line(out)
        text = "\n".join(out)
        output = (command, text)
        retry = (lambda: self.run_argv(mode, retry_argv, win, root=True)) if model.needs_root(out, status) else None
        if win is not None:
            win.last_output = output
            win.last_retry = retry
        if dialog:
            dialog.finished(status, retry)
            if status == -signal.SIGTERM:
                dialog.write("\x1b[2m(stopped)\x1b[0m")
            elif status:
                dialog.write(f"\x1b[31m(exit status {status})\x1b[0m")
            elif qr and last:
                dialog.show_qr(last)
        elif win is not None:
            if mode == "copy" and not status and last:
                win.copy_text(last, f"Copied: {last}")
            else:
                message = f"{last}  ({command})" if last else command
                win.toast(f"exit {status}: {message}" if status else message, output if len(out) > 1 or status else None, retry)
        elif status:
            # From the tray: nothing else would say it failed.
            note = Gio.Notification.new(f"{command} failed")
            note.set_body(last or f"exit status {status}")
            note.set_default_action("app.present")
            if retry:
                note.add_button_with_target("Retry as Root", "app.retry-root", GLib.Variant("as", retry_argv))
            self.send_notification(None, note)
        self.reload()


def main(argv=None):
    return ProxySuiteGui().run(argv if argv is not None else sys.argv)


if __name__ == "__main__":
    sys.exit(main())
