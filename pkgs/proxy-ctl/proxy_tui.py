"""proxy-tui: an interactive front end to proxy-ctl.

What it shows and does lives in proxy_model, shared with proxy-suite-gui; this is the drawing.
"""

import os
import shlex
import shutil
import signal
import subprocess

from rich.text import Text
from textual import events, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Vertical
from textual.content import Content
from textual.markup import escape
from textual.coordinate import Coordinate
from textual.screen import ModalScreen, Screen
from textual.theme import Theme
from textual.widgets import DataTable, Input, Label, OptionList, RichLog, Static, TabbedContent, TabPane
from textual.widgets.option_list import Option

import proxy_model as model
from proxy_model import CTL, STATE_ICONS, TABS, ctl, filter_rows, _natural, _read_states, _safe

REFRESH_SECONDS = 3
STATUS_STYLES = {"ok": "b ansi_green", "warn": "b ansi_yellow", "bad": "b ansi_red", "": "b"}


def status_text(states):
    return ["[b ansi_cyan]proxy-suite[/]", *(
        f"[dim]{escape(label)}[/][{STATUS_STYLES[style]}]{escape(value)}[/]" for label, value, style in model.status_items(states)
    )]


def pack(items, width, gap="   "):
    """Status items joined into lines no wider than width; an item never splits across lines."""
    lines = []
    for item in items:
        if lines and Content.from_markup(lines[-1] + gap + item).cell_length <= width:
            lines[-1] += gap + item
        else:
            lines.append(item)
    return "\n".join(lines)


GLOBAL_KEYS = [
    ("enter", "actions for the selected row (or click it)"),
    ("← → ⇥", "switch tab; 1-8 jump to one"),
    ("/", "filter the rows (list:learned for one column); esc clears"),
    ("click", "a column heading sorts by it, again reverses, a third time unsorts"),
    ("w", "how is a domain routed"),
    ("L", "follow all logs"),
    ("o", "output of the last command"),
    ("!", "retry what just failed as root (sudo)"),
    ("#", "switch to root: proxy-tui again under sudo"),
    ("r", "refresh now"),
    ("?", "keys"),
    ("q", "quit"),
]

KEY_LINE = [("menu", "⏎", "actions"), ("filter", "/", "filter"), ("help", "?", "keys"), ("quit", "q", "quit")]
FEEDBACK_SECONDS = 10

# Terminal colors only, so the terminal's own background and palette show through, light or dark.
# Cyan is what you can press or click; green, yellow and red say how things are, and only where that matters.
THEME = Theme(
    name="proxy-tui",
    ansi=True,
    primary="ansi_cyan",
    secondary="ansi_cyan",
    accent="ansi_cyan",
    warning="ansi_yellow",
    error="ansi_red",
    success="ansi_green",
    foreground="ansi_default",
    background="ansi_default",
    surface="ansi_default",
    panel="ansi_default",
    boost="ansi_default",
    variables={
        # The cursor reverses the row: readable on any background, and the same with or without focus.
        **{f"block-cursor{blur}-{part}": "ansi_default" for blur in ("", "-blurred") for part in ("foreground", "background")},
        "block-cursor-text-style": "reverse",
        "block-cursor-blurred-text-style": "reverse",
        "ansi-background": "ansi_black",
        "ansi-foreground": "ansi_white",
        "block-hover-background": "ansi_bright_black",
        # Links (key hints) read as text, and hovering one lights it up the way hovering a row does.
        "link-color": "ansi_default",
        "link-background": "ansi_default",
        "link-style": "none",
        "link-color-hover": "ansi_default",
        "link-background-hover": "ansi_bright_black",
        "link-style-hover": "bold not dim",
        "border": "ansi_cyan",
        "border-blurred": "ansi_bright_black",
        "input-cursor-background": "ansi_default",
        "input-cursor-foreground": "ansi_default",
        "input-cursor-text-style": "reverse",
        "input-selection-background": "ansi_bright_black",
        "scrollbar": "ansi_bright_black",
        "scrollbar-hover": "ansi_white",
        "scrollbar-active": "ansi_cyan",
        "scrollbar-background": "ansi_default",
        "scrollbar-corner-color": "ansi_default",
    },
)
ACCENT = "bold cyan"

STATE_STYLES = {"active": "green", "inactive": "dim", "failed": "bold red", "activating": "yellow", "deactivating": "yellow", "reloading": "yellow"}
CELL_STYLES = {
    "ok": "green",
    "bad": "red",
    "★": "bold yellow",
    "▸": "bold green",
    "●": "bold green",
    "runtime": "cyan",
    "pinned": "cyan",
    "excluded": "dim",
    "queued": "yellow",
}


def cell(name, value):
    value = "" if value is None else str(value)
    if name == "state":
        return Text(f"{STATE_ICONS.get(value, '?')} {value}", style=STATE_STYLES.get(value, ""))
    return Text(value, style=CELL_STYLES.get(value, ""))


def detail(tab, row, actions):
    """The selected row in full, and what can be done with it: beside or below the table when there is room."""
    text = Text()
    if row:
        for name, heading in tab.columns:
            if heading and (value := row.get(name)):
                text.append(f"{heading:<11}", style="dim")
                text.append_text(cell(name, value))
                text.append("\n")
        text.append("\n")
    text.append("Actions\n" if actions else "No actions here.\n", style="bold")
    for a in actions:
        text.append(f"  {a.key:<7}", style=ACCENT)
        text.append(f"{a.label}\n")
    return text


def _update(widget, content):
    # Only a change repaints: the refresh tick rewrites everything every few seconds.
    if widget.content != content:
        widget.update(content)


# --- dialogs ------------------------------------------------------------------


class Dialog(ModalScreen):
    def on_click(self, event):
        if event.widget is self:  # the backdrop around the dialog
            self.dismiss()


def hint(*parts):
    """A dialog's key hint; a (text, action) part is also clickable."""
    return Label(
        " · ".join(p if isinstance(p, str) else f"[@click=screen.{p[1]}]{p[0]}[/]" for p in parts), classes="dialog-hint"
    )


class Prompt(Dialog):
    BINDINGS = [Binding("escape", "dismiss", "cancel")]

    def __init__(self, title, placeholder, value=""):
        super().__init__()
        self.heading, self.placeholder, self.value = title, placeholder, value

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Label(self.heading, classes="dialog-title")
            yield Input(self.value, placeholder=self.placeholder)
            yield hint(("enter run", "submit"), ("esc cancel", "dismiss"))

    def on_input_submitted(self, event):
        self.dismiss(event.value.strip())

    def action_submit(self):
        self.dismiss(self.query_one(Input).value.strip())


class Confirm(Dialog):
    BINDINGS = [Binding("y,enter", "dismiss(True)", "yes"), Binding("n,escape", "dismiss(False)", "no")]

    def __init__(self, command):
        super().__init__()
        self.command = command

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Label("Run this?", classes="dialog-title")
            yield Label(self.command, markup=False)
            yield hint(("y/enter run", "dismiss(True)"), ("n/esc cancel", "dismiss(False)"))


class Choices(OptionList):
    def watch__mouse_hovering_over(self, index):
        # One cursor for mouse and keys: otherwise the highlighted option looks the same hovered or not.
        if index is not None:
            self.highlighted = index


class Menu(Dialog):
    """The selected row's actions, picked with the arrows."""

    BINDINGS = [Binding("escape,q", "dismiss", "close")]

    def __init__(self, title, actions):
        super().__init__()
        self.heading, self.actions = title, actions

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog menu"):
            yield Label(self.heading, classes="dialog-title", markup=False)
            yield Choices(
                *(Option(Text.assemble((f"{a.key:<7}", ACCENT), a.label), id=str(i)) for i, a in enumerate(self.actions))
            )
            yield hint("↑↓ or click to choose", ("esc close", "dismiss"))

    def on_option_list_option_selected(self, event):
        self.dismiss(self.actions[int(event.option.id)])


class Output(Dialog):
    BINDINGS = [Binding("escape,q", "dismiss", "close"), Binding("c", "copy", "copy"), Binding("exclamation_mark", "retry_root", "retry as root")]

    def __init__(self, title, text=None, wrap=True, retry=False):
        super().__init__()
        self.heading, self.initial, self.wrap, self.retry = title, text, wrap, retry
        self.proc = None  # the streaming command, stopped when the dialog closes
        self.text = []  # plain lines, for copying

    def hints(self):
        retry = [("! retry as root", "retry_root")] if self.retry else []
        return hint(*retry, ("c copy", "copy"), ("esc close", "dismiss"))

    def offer_retry(self):
        """The run failed where root could do it: ! and a click on the hint run it again under sudo."""
        self.retry = True
        if self.is_attached:
            self.query_one(".dialog-hint").remove()
            self.query_one(".dialog").mount(self.hints())

    def check_action(self, action, parameters):
        return self.retry if action == "retry_root" else True

    def action_retry_root(self):
        self.dismiss()
        self.app.action_retry_root()

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog output"):
            yield Label(self.heading, classes="dialog-title", markup=False)
            # Follow a streaming command; show finished text from its top.
            log = RichLog(wrap=self.wrap, min_width=1, markup=False, auto_scroll=self.initial is None)
            if self.initial is not None:
                text = self.initial if isinstance(self.initial, Text) else Text.from_ansi(self.initial)
                self.text.append(text.plain)
                log.write(text)
            yield log
            yield self.hints()

    def write(self, line):
        if self.is_attached:
            text = Text.from_ansi(line)
            self.text.append(text.plain)
            self.query_one(RichLog).write(text)

    def action_copy(self):
        self.app.copy_to_clipboard("\n".join(self.text))
        self.notify("Copied the output.")

    def on_unmount(self):
        model.stop(self.proc)


# --- main screen --------------------------------------------------------------


class Table(DataTable):
    def _on_mouse_move(self, event):
        event.prevent_default()  # Textual would run DataTable's own handler again after this one.
        super()._on_mouse_move(event)
        if self.hover_row < 0:  # the header row: hovering it changes nothing
            self._set_hover_cursor(False)


def _pane(tab):
    """A pane whose bindings are its tab's action keys, live while its table has focus."""
    bindings = [Binding(a.key, f"app.act({i})") for i, a in enumerate(tab.actions)]
    return type(f"{tab.id.title()}Pane", (TabPane,), {"BINDINGS": bindings})


WIDE, TALL = 130, 40  # from here on the detail panel shows beside, or below, the table


class MainScreen(Screen):
    HORIZONTAL_BREAKPOINTS = [(0, "-narrow"), (WIDE, "-wide")]
    VERTICAL_BREAKPOINTS = [(0, "-short"), (TALL, "-tall")]
    BINDINGS = [
        Binding("left,shift+tab", "app.tab(-1)", priority=True),
        Binding("right,tab", "app.tab(1)", priority=True),
        *(Binding(str(n), f"app.jump({n - 1})") for n in range(1, 9)),
        Binding("enter", "app.menu", priority=True),
        Binding("question_mark", "app.help"),
        Binding("slash", "app.filter"),
        Binding("escape", "app.clear_filter"),
        Binding("w", "app.where"),
        Binding("L", "app.logs"),
        Binding("o", "app.last_output"),
        Binding("exclamation_mark", "app.retry_root"),
        Binding("number_sign", "app.switch_root"),
        Binding("r", "app.reload"),
        Binding("q", "app.quit"),
    ]

    def __init__(self, tabs):
        super().__init__()
        self.tabs = tabs

    def compose(self) -> ComposeResult:
        yield Static(id="status")
        with TabbedContent(id="tabs"):
            for tab in self.tabs.values():
                with _pane(tab)(tab.title, id=tab.id):
                    yield Static(id=f"{tab.id}-summary", classes="summary")
                    with Container(classes="body"):
                        table = Table(id=f"{tab.id}-table", cursor_type="row")
                        for name, heading in tab.columns:
                            table.add_column(f"{heading}  ", key=name)  # room for the sort arrow
                        yield table
                        yield Static(id=f"{tab.id}-detail", classes="detail")
        yield Static(id="feedback")
        yield Static(id="keys")

    def on_mount(self):
        self.app.start()

    def on_resize(self, _):
        if self.app.rows:  # the first load has filled the tables
            self.app.selection_changed()
            self.app.show_status()

    def on_screen_resume(self):
        # Refreshes pause under dialogs; catch up once one closes.
        if self.app.rows:
            self.app.action_reload()


class ProxyTui(App):
    TITLE = "proxy-tui"
    CSS = """
    #status { height: auto; padding: 0 1; }
    Underline > .underline--bar { color: $accent; background: $border-blurred; }
    #tabs { height: 1fr; }
    #tabs ContentSwitcher { height: 1fr; }
    #tabs TabPane { height: 1fr; padding: 0; }
    .summary { display: none; height: auto; padding: 0 1; text-style: dim; }
    DataTable { background: $background; }
    #tabs DataTable { height: 1fr; }
    DataTable > .datatable--header { background: $background; color: $accent; text-style: bold; }
    .body { height: 1fr; }
    .detail { display: none; padding: 0 1; }
    .-tall #tabs DataTable { height: auto; max-height: 70%; }
    .-tall .detail { display: block; height: 1fr; border-top: solid $border-blurred; }
    .-wide .body { layout: horizontal; }
    .-wide #tabs DataTable { width: auto; max-width: 70%; height: 1fr; max-height: 100%; }
    .-wide .detail { display: block; width: 1fr; min-width: 40; border-top: none; border-left: solid $border-blurred; }
    #feedback { display: none; height: 1; padding: 0 1; }
    #keys { dock: bottom; height: auto; padding: 0 1; }
    ModalScreen { align: center middle; }
    .dialog { width: 76; max-width: 95%; height: auto; max-height: 90%; border: round $border; background: $background; padding: 0 1; }
    .dialog-title { text-style: bold; color: $accent; margin-bottom: 1; }
    .dialog-hint { text-style: dim; margin-top: 1; }
    .dialog Input { width: 1fr; border: tall $border-blurred; }
    .dialog Input:focus { border: tall $border; }
    .menu OptionList { height: auto; max-height: 20; border: none; padding: 0; background: $background; }
    /* An option list drops reverse video: the selected option gets the hover gray instead. */
    .menu OptionList > .option-list--option-highlighted { color: $foreground; background: $block-hover-background; text-style: bold; }
    .output { width: 95%; height: 90%; }
    .output RichLog { height: 1fr; background: $background; }
    """

    def __init__(self):
        super().__init__()
        self.states = _read_states()
        self.tabs = {t.id: t for t in TABS}
        self.shown = model.available_tabs(self.states)
        self.rows = {}  # tab id -> {row key: row}
        self.filters = {}  # tab id -> text
        self.sorts = {}  # tab id -> (column, descending)
        self.loaded = {}  # tab id -> the last load, refilled at once when sorting or filtering changes
        self.status = []
        self.typed = {}  # prompt title -> what was last typed there
        self.feedback_timer = None
        self.last_output = None  # (title, text)
        self.retry = None  # (mode, argv) of the last run that only root could do
        self.animation_level = "none"  # tab switches land at once
        self.register_theme(THEME)
        self.theme = THEME.name

    def on_app_blur(self, event):
        # Textual drops focus when the terminal loses it, and the table's cursor and footer change with it.
        event.prevent_default()

    def get_default_screen(self):
        return MainScreen(self.tabs)

    def start(self):
        """Once the main screen is up: it owns every widget read here."""
        self.focus_table()
        self.show_tabs(self.shown)
        self.action_reload()
        self.set_interval(REFRESH_SECONDS, self.tick)

    def tick(self):
        if self.screen is self.main:
            self.action_reload()

    @property
    def main(self):
        return self.screen_stack[0]

    # --- navigation -----------------------------------------------------------

    def active_tab(self):
        return self.main.query_one("#tabs", TabbedContent).active

    def table(self, tab_id=None):
        return self.main.query_one(f"#{tab_id or self.active_tab()}-table", DataTable)

    def focus_table(self):
        self.table().focus()

    def action_tab(self, step):
        ids = self.shown
        current = ids.index(self.active_tab()) if self.active_tab() in ids else -1
        self.action_jump((current + step) % len(ids))

    def action_jump(self, index):
        if 0 <= index < len(self.shown):
            self.main.query_one("#tabs", TabbedContent).active = self.shown[index]

    def on_tabbed_content_tab_activated(self, _):
        self.focus_table()
        self.selection_changed()
        self.action_reload()

    def on_data_table_row_highlighted(self, _):
        self.selection_changed()

    def selection_changed(self):
        tab_id, row = self.active_tab(), self.selected_row()
        tab, actions = self.tabs[tab_id], self.applicable(row)
        _update(self.main.query_one(f"#{tab_id}-detail", Static), detail(tab, row, actions))
        width, height = self.size
        # The detail panel lists the row's actions when it shows; the key line need not repeat them.
        shown = [] if width >= WIDE or height >= TALL else [(f"act({tab.actions.index(a)})", a.key, model.short(a.label)) for a in actions]
        # The key keeps its color outside the link: a link's own color would cover it.
        items = [f"[b ansi_cyan]{escape(k)}[/] [@click=app.{action}]{escape(label)}[/]" for action, k, label in shown + KEY_LINE]
        _update(self.main.query_one("#keys", Static), pack(items, width - 2))

    # --- reading --------------------------------------------------------------

    def action_reload(self):
        self.load(self.active_tab())

    @work(thread=True, exclusive=True, group="load")
    def load(self, tab_id):
        model.new_load()
        states = _read_states()
        visible = model.available_tabs(states)
        status = _safe(status_text, states, fallback=["status unavailable"])
        rows, summary = model.load_tab(self.tabs[tab_id], states)
        self.call_from_thread(self.fill, tab_id, states, visible, status, rows, summary)

    def show_status(self):
        _update(self.main.query_one("#status", Static), pack(self.status, self.size.width - 2))

    def refill(self, tab_id):
        if tab_id in self.loaded:
            self.fill(tab_id, *self.loaded[tab_id])

    def fill(self, tab_id, states, visible, status, rows, summary):
        self.loaded[tab_id] = (states, visible, status, rows, summary)
        self.states, self.status = states, status
        # A read root could do: ! retries runs, not reads, so the way out is the whole TUI under sudo.
        if summary.startswith("✗") and model.needs_root(summary.splitlines(), 1):
            summary += "\n#: run proxy-tui as root (sudo)"
        self.show_status()
        if visible != self.shown:
            self.show_tabs(visible)
            if tab_id not in visible:
                return  # show_tabs moved to another tab, which loads itself
        if text := self.filters.get(tab_id):
            rows = filter_rows(rows, self.tabs[tab_id].columns, text)
            summary = f"filter: {text} ({len(rows)} rows) · esc clears" + (f"\n{summary}" if summary else "")
        if sort := self.sorts.get(tab_id):
            rows = sorted(rows, key=lambda r: _natural(r.get(sort[0])), reverse=sort[1])
        widget = self.main.query_one(f"#{tab_id}-summary", Static)
        _update(widget, Text(summary))
        widget.display = bool(summary)
        self.rows[tab_id] = {r["key"]: r for r in rows}
        tab, table = self.tabs[tab_id], self.table(tab_id)
        keys = [r["key"] for r in rows]
        if keys == [k.value for k in table.rows]:
            # The same rows: change only the cells that changed, so cursor and scroll stay put.
            for r in rows:
                for name, _ in tab.columns:
                    value = cell(name, r.get(name))
                    if table.get_cell(r["key"], name) != value:
                        table.update_cell(r["key"], name, value)
            self.selection_changed()
            return
        selected = self.selected_key(tab_id)
        table.clear()
        for r in rows:
            table.add_row(*(cell(name, r.get(name)) for name, _ in tab.columns), key=r["key"])
        if selected in keys:
            table.move_cursor(row=keys.index(selected), animate=False)
        self.selection_changed()

    def show_tabs(self, visible):
        tabs = self.main.query_one("#tabs", TabbedContent)
        for tab_id in self.tabs:
            (tabs.show_tab if tab_id in visible else tabs.hide_tab)(tab_id)
        for n, tab_id in enumerate(visible, 1):
            tabs.get_tab(tab_id).label = f"{n} {self.tabs[tab_id].title}"
        self.shown = visible
        if tabs.active not in visible and visible:
            tabs.active = visible[0]

    def selected_key(self, tab_id):
        table = self.table(tab_id)
        if not table.row_count:
            return None
        return table.coordinate_to_cell_key(Coordinate(table.cursor_row, 0)).row_key.value

    def selected_row(self):
        tab_id = self.active_tab()
        return (self.rows.get(tab_id) or {}).get(self.selected_key(tab_id))

    # --- acting ---------------------------------------------------------------

    def applicable(self, row):
        return model.applicable(self.tabs[self.active_tab()], row)

    def check_action(self, action, parameters):
        if action in ("retry_root", "switch_root"):
            return not model.is_root()
        # A row action that does not apply: its key does nothing.
        if action != "act" or self.screen is not self.main:
            return True
        return self.tabs[self.active_tab()].actions[parameters[0]] in self.applicable(self.selected_row())

    def action_menu(self):
        row = self.selected_row()
        title = row["key"] if row else self.tabs[self.active_tab()].title
        actions = self.applicable(row)
        if not actions:
            self.feedback(f"No actions for {title}.")
            return
        self.push_screen(Menu(title, actions), lambda a: a and self.perform(a, row))

    def on_data_table_row_selected(self, _):
        # Only a click on the highlighted row: enter is bound above the table.
        self.action_menu()

    def action_act(self, index):
        self.perform(self.tabs[self.active_tab()].actions[index], self.selected_row())

    def action_where(self):
        self.perform(model.WHERE, None)

    def on_data_table_header_selected(self, event):
        tab_id, name = self.active_tab(), event.column_key.value
        sort = self.sorts.pop(tab_id, None)
        if not sort or sort[0] != name:
            self.sorts[tab_id] = (name, False)
        elif not sort[1]:
            self.sorts[tab_id] = (name, True)
        table = self.table(tab_id)
        for column, heading in self.tabs[tab_id].columns:
            arrow = ("▼" if self.sorts[tab_id][1] else "▲") if self.sorts.get(tab_id, ("",))[0] == column else " "
            table.columns[column].label = Text(f"{heading} {arrow}")
        table._clear_caches()  # the header is cached with its old labels
        table.refresh()
        self.refill(tab_id)

    def action_filter(self):
        tab_id = self.active_tab()

        def apply(text):
            if text is None:
                return
            self.filters[tab_id] = text
            self.refill(tab_id)

        self.push_screen(Prompt("Filter rows", "words in any column, or column:value (list:learned); empty clears", self.filters.get(tab_id, "")), apply)

    def action_clear_filter(self):
        if self.filters.pop(self.active_tab(), ""):
            self.refill(self.active_tab())

    def action_logs(self):
        self.run_argv("suspend", ["logs"])

    def action_last_output(self):
        if self.last_output:
            self.push_screen(Output(*self.last_output, retry=self.retry is not None))
        else:
            self.feedback("Nothing has run yet.")

    def action_help(self):
        tab = self.tabs[self.active_tab()]
        text = Text()
        for heading, keys in ((tab.title, [(a.key, a.label) for a in tab.actions]), ("Everywhere", GLOBAL_KEYS)):
            text.append(f"{heading}\n", style="bold")
            for key, label in keys:
                text.append(f"  {key:<9}", style=ACCENT)
                text.append(f"{label}\n")
            text.append("\n")
        self.push_screen(Output("Keys", text))

    def perform(self, action, row):
        def with_text(text=""):
            try:
                argv = action.argv(row, text, self.states)
            except (ValueError, IndexError) as e:  # an unbalanced quote in a typed command
                self.feedback(f"Cannot run that: {e}", False)
                return
            if model.needs_confirm(action, row):
                self.push_screen(Confirm(f"proxy-ctl {shlex.join(argv)}"), lambda ok: ok and self.run_argv(action.mode, argv))
            else:
                self.run_argv(action.mode, argv)

        def typed(text):
            if text:
                self.typed[action.label] = text
                with_text(text)

        if action.prompt:
            title = action.label.removesuffix("…")
            self.push_screen(Prompt(title[:1].upper() + title[1:], action.prompt, self.typed.get(action.label, "")), typed)
        else:
            with_text()

    def run_argv(self, mode, argv):
        command = f"proxy-ctl {shlex.join(argv)}"
        if mode in ("suspend", "pause"):
            self.foreground(mode, [CTL, *argv])
            return
        # A wrapped QR code no longer scans: it scrolls sideways instead.
        dialog = Output(command, wrap="--qr" not in argv) if mode == "dialog" else None
        if dialog:
            self.push_screen(dialog)
        self.feedback(f"… {command}")
        self.stream(command, argv, dialog, mode == "copy")

    def foreground(self, mode, argv):
        with self.suspend():
            ctl._run_foreground(argv)
            if mode == "pause":
                try:
                    input("\n[enter] back to proxy-tui")
                except (EOFError, KeyboardInterrupt):
                    pass
        self.action_reload()

    @work(thread=True)
    def stream(self, command, argv, dialog, copy=False):
        out = []
        try:
            p = model.popen(argv)
            if dialog:
                dialog.proc = p
            for line in p.stdout:
                out.append(line.rstrip("\n"))
                if dialog:
                    self.call_from_thread(dialog.write, out[-1])
            status = p.wait()
        except OSError as e:
            out.append(f"cannot run proxy-ctl: {e}")
            status = 127
        self.call_from_thread(self.finish, command, argv, dialog, copy, out, status, stream_shown=True)

    def finish(self, command, argv, dialog, copy, out, status, stream_shown=False):
        """A run's end: the feedback line, the clipboard, and the dialog's tail."""
        if dialog and not stream_shown:
            for line in out:
                dialog.write(line)
        last = Text.from_ansi(next((line for line in reversed(out) if line.strip()), "")).plain.strip()
        message = f"{last}  ({command})" if last else command
        self.last_output = (command, "\n".join(out))
        if status == -signal.SIGTERM and dialog:
            self.feedback(f"stopped: {command}", False)
            return
        if copy and not status and last:
            self.copy_to_clipboard(last)
            message = f"copied: {last}"
        if status:
            message = f"exit {status}: {message}"
            if dialog:
                dialog.write(f"\x1b[31m(exit status {status})\x1b[0m")
        hints = ["o: full output"] if len(out) > 1 and not dialog else []
        self.retry = None
        if model.needs_root(out, status):
            self.retry = ("dialog" if dialog else "copy" if copy else "run", argv)
            hints.append("!: retry as root")
            if dialog:
                dialog.offer_retry()
        self.feedback(message, status == 0, hints)
        self.action_reload()

    def action_retry_root(self):
        if not self.retry:
            self.feedback("Nothing to retry as root.")
            return
        (mode, argv), self.retry = self.retry, None
        command = f"sudo proxy-ctl {shlex.join(argv)}"
        root_argv = model.elevated(argv, "sudo")
        # sudo asks on the terminal, so the run happens there; the output comes back as usual.
        out = []
        with self.suspend():
            print(f"$ {command}", flush=True)
            try:
                p = subprocess.Popen(root_argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
            except OSError as e:
                p, status, out = None, 127, [f"cannot run sudo: {e}"]
            if p:
                # Ctrl-C at sudo's password prompt is sudo's to handle: raised here it would
                # escape the app and take the TUI down. Set after the fork, so sudo inherits
                # the handler it needs, as ctl._run_foreground does.
                old = signal.signal(signal.SIGINT, signal.SIG_IGN)
                try:
                    for line in p.stdout:
                        print(line, end="", flush=True)
                        out.append(line.rstrip("\n"))
                    status = p.wait()
                finally:
                    signal.signal(signal.SIGINT, old)
        dialog = Output(command, wrap="--qr" not in argv) if mode == "dialog" else None
        if dialog:
            self.push_screen(dialog)
        self.finish(command, argv, dialog, mode == "copy", out, status)

    def action_switch_root(self):
        def switch(ok):
            if not ok:
                return
            with self.suspend():
                # Asks here, once: the TUI under sudo then starts without asking again.
                status = ctl._run_foreground(["sudo", "-v"])
            if status:
                self.feedback("sudo: not authenticated", False)
            else:
                self.exit("root")

        self.push_screen(Confirm("sudo proxy-tui"), switch)

    def feedback(self, message, ok=None, hints=()):
        """The bar is one line: what to press next is pinned, so only the message is ellipsized."""
        icon, style = {True: ("✓ ", "green"), False: ("✗ ", "red"), None: ("", "")}[ok]
        text = Text(icon + message, style=style, no_wrap=True, overflow="ellipsis")
        if tail := "".join(f"  · {h}" for h in hints):
            text.truncate(max(len(icon) + 1, self.size.width - 2 - len(tail)), overflow="ellipsis")
            text.append(tail, ACCENT)  # a rich style: the theme's ansi_* names are markup, not rich colors
        bar = self.main.query_one("#feedback", Static)
        bar.update(text)
        bar.display = True
        if self.feedback_timer:
            self.feedback_timer.stop()
        if ok is not None:
            self.feedback_timer = self.set_timer(FEEDBACK_SECONDS, lambda: setattr(bar, "display", False))


if __name__ == "__main__":
    if ProxyTui().run() == "root":
        # The wrapper by name: sudo resets the environment, and the wrapper sets it again.
        os.execvp("sudo", ["sudo", shutil.which("proxy-tui") or "proxy-tui"])
