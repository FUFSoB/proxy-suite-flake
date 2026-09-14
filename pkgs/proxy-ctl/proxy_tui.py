"""proxy-tui: an interactive front end to proxy-ctl.

Reads come from proxy_ctl in-process. Every change runs proxy-ctl itself, so
validation, permission errors and systemd triggers stay in one place, and its
die() cannot take the TUI down.
"""

import os
import re
import shlex
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable

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

import proxy_ctl as ctl

CTL = "proxy-ctl"
REFRESH_SECONDS = 3


def _die(message, status=1):
    # Readers run in-process: the message rides the SystemExit, so an empty tab can say why.
    sys.exit(message)


ctl.die = _die

_memo = {}  # (reader, args) -> result, cleared at the start of every load


def _per_load(fn):
    def wrapped(*args):
        key = (fn, args)
        if key not in _memo:
            _memo[key] = fn(*args)
        return _memo[key]

    return wrapped


# Clash API calls and systemctl spawns that several readers repeat within one load.
for _name in ("_outbound_current", "_outbound_inventory", "_autoproxy_state", "_autoproxy_next_run", "svc_state"):
    setattr(ctl, _name, _per_load(getattr(ctl, _name)))


@dataclass
class Action:
    key: str
    label: str
    argv: Callable  # (selected row or None, prompt text, unit states) -> proxy-ctl argv
    when: Callable = None  # row -> applies; None: a tab-wide action that needs no row
    prompt: str = ""  # ask for text first
    confirm: bool | Callable = False  # or row -> ask first
    mode: str = "run"  # run: result in the feedback line; dialog: output streamed into a dialog; suspend: hand over the terminal; pause: suspend, then wait for enter; copy: last line to the clipboard


@dataclass
class Tab:
    id: str
    title: str
    available: Callable  # unit states -> bool
    columns: list  # (row field, heading)
    rows: Callable  # unit states -> [row dict with a unique "key"]
    summary: Callable = None  # () -> text above the table, read with every load
    actions: list = field(default_factory=list)


def ROW(_):
    return True


# --- readers ------------------------------------------------------------------


def unit_states(units):
    """unit -> ActiveState for the units that exist, in one systemctl call."""
    if not units:
        return {}
    _, out = ctl._run(["systemctl", "show", "--property=Id,LoadState,ActiveState", "--", *units], capture=True, quiet=True)
    states = {}
    for unit, block in zip(units, out.strip().split("\n\n")):
        props = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if props.get("LoadState") not in (None, "not-found"):
            states[unit] = props.get("ActiveState", "unknown")
    return states


def all_units():
    return [*ctl.ALL_SERVICES, *map(ctl._awg_service, ctl._awg_profiles())]


def _lines(name):
    try:
        return [line for line in ctl.lines(ctl.read_text(ctl._zapret_auto_file(name))) if line]
    except OSError:
        return []


TOGGLES = {
    "proxy-suite-socks": ["proxy"],
    "proxy-suite-tun": ["proxy", "tun"],
    "proxy-suite-tproxy": ["proxy", "tproxy"],
    "proxy-suite-ssh-proxy": ["ssh"],
    "proxy-suite-warp-tunnel": ["warp"],
    "proxy-suite-tg-ws-proxy": ["tg"],
    "proxy-suite-zapret": ["zapret"],
}
AWG_PREFIX = ctl._awg_service("")
ZAPRET_LISTS = (
    ("learned", "zapret-hosts-auto.txt"),
    ("pinned", "zapret-hosts-user.txt"),
    ("excluded", "zapret-hosts-user-exclude.txt"),
)


def toggle_argv(row, *_):
    verb = "off" if row["state"] == "active" else "on"
    if row["unit"].startswith(AWG_PREFIX):
        return ["awg", verb, row["unit"].removeprefix(AWG_PREFIX)]
    return [*TOGGLES[row["unit"]], verb]


def service_rows(states):
    return [{"key": u, "unit": u, "name": u.removeprefix("proxy-suite-"), "state": s} for u, s in states.items()]


def route_rows(_):
    current = ctl._route_mode_current()
    return [
        {"key": m, "active": "●" if m == current else "", "mode": ctl._route_mode_label(m)}
        for m in ("default", *ctl.ROUTE_MODES)
    ]


def outbound_rows(_):
    inventory = ctl._outbound_inventory()
    pinned = ctl._s(inventory.get("pinned") or "")
    sources = inventory.get("sources") or {}
    current = ctl._outbound_current()
    reputation = ctl._reputation_by_tag()
    runtime = set(ctl._runtime_tags("outbound"))
    return [
        {
            "key": t,
            "mark": "★" if t == pinned else "▸" if t == current else "",
            "tag": t,
            "reputation": reputation.get(t, "-"),
            "source": "runtime" if t in runtime else ctl._s(sources.get(t) or "-"),
            "runtime": t in runtime,
        }
        for t in ctl._outbound_tags()
    ]


def outbound_summary():
    inventory = ctl._outbound_inventory()
    if not inventory:
        return "No outbounds yet - is proxy-suite-socks running?"
    return (
        f"Selection: {ctl._s(inventory.get('selection') or 'first')}   "
        f"Pinned: {ctl._s(inventory.get('pinned') or '(none)')}   "
        f"Current: {ctl._outbound_current() or '-'}"
    )


def subscription_rows(_):
    rows = []
    for source, tags in (("static", ctl._sub_tags()), ("runtime", ctl._runtime_tags("subscription"))):
        for t in tags:
            cache = ctl._subscription_cache(t)
            cached = os.path.isfile(cache)
            count = ctl._subscription_proxy_count_text(cache) if cached else "-"
            updated = ctl._ago(int(os.path.getmtime(cache)), int(time.time())) + " ago" if cached else "-"
            rows.append({"key": t, "tag": t, "proxies": count, "updated": updated, "source": source})
    return rows


def autoproxy_rows(_):
    state = ctl._autoproxy_state(ctl._autoproxy_dir())
    domains = state.get("domains") or {}
    rows = [
        {"key": d, "domain": d, "kind": "routed", "detail": f"via {ctl._s((v or {}).get('exit'))}"}
        for d, v in sorted(domains.items())
    ]
    backlog = sorted((state.get("backlog") or {}).items(), key=lambda kv: -((kv[1] or {}).get("hits") or 0))
    rows += [
        {"key": h, "domain": h, "kind": "queued", "detail": f"{ctl._s((v or {}).get('hits'))} hits"}
        for h, v in backlog
        if h not in domains
    ]
    return rows


def zapret_rows(_):
    if ctl.env("ZAPRET_AUTO_ENABLED") != "1":
        return []
    rows = {}
    for kind, name in ZAPRET_LISTS:
        for host in _lines(name):
            rows.setdefault(f"{kind}:{host}", {"key": f"{kind}:{host}", "host": host, "kind": kind})
    return list(rows.values())


def zapret_summary():
    if ctl.env("ZAPRET_AUTO_ENABLED") != "1":
        return 'Learned hostlists need zapret.engine = "zapret2".'
    text = "   ".join(f"{len(_lines(name))} {kind}" for kind, name in ZAPRET_LISTS)
    if ctl.env("ZAPRET_CUTOFF_ENABLED") == "1":
        text += "\n" + "   ".join(line.strip() for line in _cutoff_status().splitlines()[:2])
    return text


_cutoff = {}  # ts mtime -> status text: a probe rewrites ts


def _cutoff_status():
    try:
        mtime = os.path.getmtime(os.path.join(ctl._zapret_state_dir(), "cutoff", "ts"))
    except OSError:
        mtime = None
    if mtime not in _cutoff:
        _cutoff.clear()
        _cutoff[mtime] = _capture(["zapret", "cutoff", "status"])
    return _cutoff[mtime]


def inbound_rows(_):
    return [
        {"key": f"{x.get('tag')}/{x.get('user')}", **{k: ctl._s(x.get(k) or "") for k in ("tag", "user", "type", "port")}}
        for x in ctl._inbound_links()
    ]


def app_rows(_):
    return [
        {"key": ctl._s(p.get("name")), "profile": ctl._s(p.get("name")), "route": ctl._s(p.get("route"))}
        for p in ctl._per_app_profiles()
    ]


def status_text(states):
    parts = []
    if "proxy-suite-socks" in states:
        default = " (default)" if ctl._route_mode_current() == "default" else ""
        parts.append(("mode ", ctl._route_mode_effective() + default))
        parts.append(("outbound ", ctl._status_outbound() or "-"))
    if autoproxy := ctl._status_autoproxy():
        parts.append(("autoProxy ", autoproxy))
    if zapret := ctl._status_zapret():
        parts.append(("zapret ", f"{zapret} learned"))
    failed = sum(1 for s in states.values() if s == "failed")
    return [
        "[b ansi_cyan]proxy-suite[/]",
        *(f"[dim]{label}[/][b]{escape(value)}[/]" for label, value in parts),
        *([f"[b ansi_red]{failed} failed[/]"] if failed else []),
    ]


def pack(items, width, gap="   "):
    """Status items joined into lines no wider than width; an item never splits across lines."""
    lines = []
    for item in items:
        if lines and Content.from_markup(lines[-1] + gap + item).cell_length <= width:
            lines[-1] += gap + item
        else:
            lines.append(item)
    return "\n".join(lines)


def filter_rows(rows, columns, text):
    """Every word must match: column:value in that column (by heading or field), anything else in any column."""
    names = {k.lower(): name for name, heading in columns for k in (name, heading) if k}

    def matches(row, term):
        column, sep, value = term.lower().partition(":")
        if sep and column in names:
            return value in str(row.get(names[column], "")).lower()
        return any(term.lower() in str(row.get(name, "")).lower() for name, _ in columns)

    return [r for r in rows if all(matches(r, t) for t in text.split())]


def _natural(value):
    # "port 443" before "port 2053": digit runs compare as numbers.
    return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", str(value or "").lower())]


def _link(row, *extra):
    return ["inbounds", "link", row["tag"], *([row["user"]] if row["user"] else []), *extra]


def _kind(*kinds):
    return lambda row: row["kind"] in kinds


def _socks(states):
    return "proxy-suite-socks" in states


def _enabled(name):
    return lambda _: ctl.env(name) == "1"


def _zapret_toggle(row, _, states):
    return ["zapret", "off" if states.get("proxy-suite-zapret") == "active" else "on"]


TABS = [
    Tab(
        "services",
        "Services",
        lambda _: True,
        [("name", "Unit"), ("state", "State")],
        service_rows,
        actions=[
            Action(
                "space",
                "start / stop",
                toggle_argv,
                when=lambda r: r["unit"] in TOGGLES or r["unit"].startswith(AWG_PREFIX),
                # proxy off takes tun and tproxy down with it.
                confirm=lambda r: r["unit"] == "proxy-suite-socks" and r["state"] == "active",
            ),
            Action("l", "follow its logs", lambda r, *_: ["logs", r["unit"]], when=ROW, mode="suspend"),
            Action(
                "ctrl+r",
                "restart it",
                lambda r, *_: ["awg", "restart", r["unit"].removeprefix(AWG_PREFIX)],
                when=lambda r: r["unit"].startswith(AWG_PREFIX) and r["state"] == "active",
            ),
            Action("R", "restart everything running", lambda r, *_: ["restart"], confirm=True),
        ],
    ),
    Tab(
        "routing",
        "Routing",
        _socks,
        [("active", ""), ("key", "Mode"), ("mode", "Meaning")],
        route_rows,
        summary=lambda: f"Configured default: {ctl._route_mode_default()}. An override lasts until you switch back to default.",
        actions=[Action("s", "switch to this mode", lambda r, *_: ["proxy", "mode", r["key"]], when=lambda r: not r["active"])],
    ),
    Tab(
        "outbounds",
        "Outbounds",
        _socks,
        [("mark", ""), ("tag", "Tag"), ("reputation", "Reputation"), ("source", "Source")],
        outbound_rows,
        summary=outbound_summary,
        actions=[
            Action("p", "pin it", lambda r, *_: ["proxy", "pin", r["tag"]], when=lambda r: r["mark"] != "★"),
            Action("u", "unpin: let the selection pick", lambda r, *_: ["proxy", "unpin"], when=lambda r: r["mark"] == "★"),
            Action("t", "test it", lambda r, *_: ["proxy", "outbounds", "test", r["tag"]], when=ROW, mode="dialog"),
            Action("T", "test all", lambda r, *_: ["proxy", "outbounds", "test"], mode="dialog"),
            Action("n", "add a runtime outbound…", lambda r, t, _: ["proxy", "outbounds", "add", *t.split(None, 1)], prompt="<tag> <url>"),
            Action("d", "remove it", lambda r, *_: ["proxy", "outbounds", "rm", r["tag"]], when=lambda r: r["runtime"], confirm=True),
        ],
    ),
    Tab(
        "subs",
        "Subs",
        _socks,
        [("tag", "Tag"), ("proxies", "Proxies"), ("updated", "Updated"), ("source", "Source")],
        subscription_rows,
        summary=lambda: f"proxy-suite-subscription-update: {ctl.svc_state('proxy-suite-subscription-update') or 'unknown'}",
        actions=[
            Action("u", "refetch all", lambda r, *_: ["proxy", "subs", "update"], mode="dialog"),
            Action("l", "follow the update's logs", lambda r, *_: ["logs", "proxy-suite-subscription-update"], mode="suspend"),
            Action("n", "add a runtime subscription…", lambda r, t, _: ["proxy", "subs", "add", *t.split(None, 1)], prompt="<tag> <url>"),
            Action("d", "remove it", lambda r, *_: ["proxy", "subs", "rm", r["tag"]], when=lambda r: r["source"] == "runtime", confirm=True),
        ],
    ),
    Tab(
        "autoproxy",
        "autoProxy",
        _enabled("AUTOPROXY_ENABLED"),
        [("domain", "Domain"), ("kind", "State"), ("detail", "")],
        autoproxy_rows,
        summary=ctl._status_autoproxy,
        actions=[
            Action("w", "how is it routed", lambda r, *_: ["where", r["domain"]], when=ROW, mode="dialog"),
            Action("e", "learn it now", lambda r, *_: ["proxy", "auto", "learn", r["domain"]], when=_kind("queued"), mode="dialog"),
            Action("p", "probe it through every exit", lambda r, *_: ["proxy", "auto", "probe", r["domain"], "--keep-going"], when=ROW, mode="dialog"),
            Action("P", "probe a domain…", lambda r, t, _: ["proxy", "auto", "probe", t], prompt="<domain>[/path]", mode="dialog"),
            Action("E", "learn a domain…", lambda r, t, _: ["proxy", "auto", "learn", t], prompt="<domain>", mode="dialog"),
            Action("i", "routed, judged and bad exits", lambda r, *_: ["proxy", "auto", "list"], mode="dialog"),
        ],
    ),
    Tab(
        "zapret",
        "zapret",
        lambda s: "proxy-suite-zapret" in s or ctl.env("ZAPRET_AUTO_ENABLED") == "1",
        [("host", "Host"), ("kind", "List")],
        zapret_rows,
        summary=zapret_summary,
        actions=[
            Action("f", "forget it (may be learned again)", lambda r, *_: ["zapret", "auto", "forget", r["host"]], when=_kind("learned")),
            Action("x", "exclude it (never learn)", lambda r, *_: ["zapret", "auto", "exclude", r["host"]], when=_kind("learned", "pinned")),
            Action("u", "unpin it", lambda r, *_: ["zapret", "auto", "unpin", r["host"]], when=_kind("pinned")),
            Action("i", "include it (may be learned again)", lambda r, *_: ["zapret", "auto", "include", r["host"]], when=_kind("excluded")),
            Action("a", "pin a host (always bypass)…", lambda r, t, _: ["zapret", "auto", "add", t], prompt="<domain>"),
            Action("C", "forget all learned hosts", lambda r, *_: ["zapret", "auto", "clear"], confirm=True),
            Action("P", "probe the line's cutoff again", lambda r, *_: ["zapret", "cutoff", "probe"], mode="dialog"),
            Action("z", "start / stop zapret", _zapret_toggle),
        ],
    ),
    Tab(
        "inbounds",
        "Inbounds",
        _enabled("INBOUNDS_ENABLED"),
        [("tag", "Tag"), ("user", "User"), ("type", "Type"), ("port", "Port")],
        inbound_rows,
        summary=lambda: f"proxy-suite-inbounds: {ctl.svc_state('proxy-suite-inbounds') or 'unknown'}",
        actions=[
            Action("l", "share link", lambda r, *_: _link(r), when=ROW, mode="dialog"),
            Action("c", "copy share link", lambda r, *_: _link(r), when=ROW, mode="copy"),
            Action("Q", "share link as QR", lambda r, *_: _link(r, "--qr"), when=ROW, mode="dialog"),
            Action("s", "subscription URL", lambda r, *_: ["inbounds", "sub", r["user"]], when=lambda r: bool(r["user"]), mode="dialog"),
            Action("S", "subscription URL as QR", lambda r, *_: ["inbounds", "sub", r["user"], "--qr"], when=lambda r: bool(r["user"]), mode="dialog"),
            Action("y", "copy subscription URL", lambda r, *_: ["inbounds", "sub", r["user"]], when=lambda r: bool(r["user"]), mode="copy"),
            Action("t", "traffic per user", lambda r, *_: ["inbounds", "stats"], mode="dialog"),
        ],
    ),
    Tab(
        "apps",
        "Apps",
        _enabled("PER_APP_ROUTING_ENABLED"),
        [("profile", "Profile"), ("route", "Route")],
        app_rows,
        actions=[
            Action("x", "run a command through it…", lambda r, t, _: ["apps", "run", r["profile"], "--", *shlex.split(t)], when=ROW, prompt="<command> [args]", mode="pause"),
        ],
    ),
]

GLOBAL_KEYS = [
    ("enter", "actions for the selected row (or click it)"),
    ("← → ⇥", "switch tab; 1-8 jump to one"),
    ("/", "filter the rows (list:learned for one column); esc clears"),
    ("click", "a column heading sorts by it, again reverses, a third time unsorts"),
    ("w", "how is a domain routed"),
    ("L", "follow all logs"),
    ("o", "output of the last command"),
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

STATE_STYLES = {"active": "green", "inactive": "dim", "failed": "bold red", "activating": "yellow", "deactivating": "yellow"}
STATE_ICONS = {"active": "●", "inactive": "○", "failed": "✗", "activating": "◐", "deactivating": "◐"}
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


def _capture(argv):
    try:
        p = subprocess.run([CTL, *argv], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except OSError as e:
        return f"cannot run proxy-ctl: {e}"
    return p.stdout + p.stderr


def _safe(fn, *args, fallback=None):
    try:
        return fn(*args)
    except (Exception, SystemExit):
        return fallback  # Unreadable state: shown empty; a tab's own rows say why in its summary.


def _read_states():
    return _safe(unit_states, _safe(all_units, fallback=list(ctl.ALL_SERVICES)), fallback={})


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
    BINDINGS = [Binding("escape,q", "dismiss", "close"), Binding("c", "copy", "copy")]

    def __init__(self, title, text=None):
        super().__init__()
        self.heading, self.initial = title, text
        self.proc = None  # the streaming command, stopped when the dialog closes
        self.text = []  # plain lines, for copying

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog output"):
            yield Label(self.heading, classes="dialog-title", markup=False)
            # Follow a streaming command; show finished text from its top.
            log = RichLog(wrap=True, min_width=1, markup=False, auto_scroll=self.initial is None)
            if self.initial is not None:
                text = self.initial if isinstance(self.initial, Text) else Text.from_ansi(self.initial)
                self.text.append(text.plain)
                log.write(text)
            yield log
            yield hint(("c copy", "copy"), ("esc close", "dismiss"))

    def write(self, line):
        if self.is_attached:
            text = Text.from_ansi(line)
            self.text.append(text.plain)
            self.query_one(RichLog).write(text)

    def action_copy(self):
        self.app.copy_to_clipboard("\n".join(self.text))
        self.notify("Copied the output.")

    def on_unmount(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


# --- main screen --------------------------------------------------------------


def _short(label):
    return label.split(" (")[0].removesuffix("…")


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
        self.shown = self.available_tabs(self.states)
        self.rows = {}  # tab id -> {row key: row}
        self.filters = {}  # tab id -> text
        self.sorts = {}  # tab id -> (column, descending)
        self.loaded = {}  # tab id -> the last load, refilled at once when sorting or filtering changes
        self.status = []
        self.typed = {}  # prompt title -> what was last typed there
        self.feedback_timer = None
        self.last_output = None  # (title, text)
        self.animation_level = "none"  # tab switches land at once
        self.register_theme(THEME)
        self.theme = THEME.name

    def on_app_blur(self, event):
        # Textual drops focus when the terminal loses it, and the table's cursor and footer change with it.
        event.prevent_default()

    def available_tabs(self, states):
        return [t.id for t in TABS if _safe(t.available, states, fallback=False)]

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
        shown = [] if width >= WIDE or height >= TALL else [(f"act({tab.actions.index(a)})", a.key, _short(a.label)) for a in actions]
        # The key keeps its color outside the link: a link's own color would cover it.
        items = [f"[b ansi_cyan]{escape(k)}[/] [@click=app.{action}]{escape(label)}[/]" for action, k, label in shown + KEY_LINE]
        _update(self.main.query_one("#keys", Static), pack(items, width - 2))

    # --- reading --------------------------------------------------------------

    def action_reload(self):
        self.load(self.active_tab())

    @work(thread=True, exclusive=True, group="load")
    def load(self, tab_id):
        _memo.clear()
        tab = self.tabs[tab_id]
        states = _read_states()
        visible = self.available_tabs(states)
        status = _safe(status_text, states, fallback=["status unavailable"])
        summary = (_safe(tab.summary, fallback="") or "") if tab.summary else ""
        try:
            rows = tab.rows(states)
        except (Exception, SystemExit) as e:
            rows = []
            summary = f"✗ {str(e) or type(e).__name__}" + (f"\n{summary}" if summary else "")
        else:
            if not rows:
                hints = "   ".join(f"{a.key}: {_short(a.label)}" for a in tab.actions if a.prompt)
                summary = "Nothing here yet." + (f"   {hints}" if hints else "") + (f"\n{summary}" if summary else "")
        self.call_from_thread(self.fill, tab_id, states, visible, status, rows, summary)

    def show_status(self):
        _update(self.main.query_one("#status", Static), pack(self.status, self.size.width - 2))

    def refill(self, tab_id):
        if tab_id in self.loaded:
            self.fill(tab_id, *self.loaded[tab_id])

    def fill(self, tab_id, states, visible, status, rows, summary):
        self.loaded[tab_id] = (states, visible, status, rows, summary)
        self.states, self.status = states, status
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
        return [a for a in self.tabs[self.active_tab()].actions if a.when is None or (row is not None and a.when(row))]

    def check_action(self, action, parameters):
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
        self.perform(Action("w", "How is a domain routed", lambda r, t, _: ["where", t], prompt="<domain>", mode="dialog"), None)

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
            self.push_screen(Output(*self.last_output))
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
            argv = action.argv(row, text, self.states)
            confirm = action.confirm(row) if callable(action.confirm) else action.confirm
            if confirm:
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
            with self.suspend():
                ctl._run_foreground([CTL, *argv])
                if mode == "pause":
                    try:
                        input("\n[enter] back to proxy-tui")
                    except (EOFError, KeyboardInterrupt):
                        pass
            self.action_reload()
            return
        dialog = Output(command) if mode == "dialog" else None
        if dialog:
            self.push_screen(dialog)
        self.feedback(f"… {command}")
        self.stream(command, argv, dialog, mode == "copy")

    @work(thread=True)
    def stream(self, command, argv, dialog, copy=False):
        out = []
        try:
            p = subprocess.Popen(
                [CTL, *argv], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, text=True
            )
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
        last = Text.from_ansi(next((line for line in reversed(out) if line.strip()), "")).plain.strip()
        message = f"{last}  ({command})" if last else command
        self.last_output = (command, "\n".join(out))
        if status == -signal.SIGTERM and dialog:
            self.call_from_thread(self.feedback, f"stopped: {command}", False)
            return
        if copy and not status and last:
            self.call_from_thread(self.copy_to_clipboard, last)
            message = f"copied: {last}"
        if status:
            message = f"exit {status}: {message}"
            if dialog:
                self.call_from_thread(dialog.write, f"\x1b[31m(exit status {status})\x1b[0m")
        if len(out) > 1 and not dialog:
            message += "  · o: full output"
        self.call_from_thread(self.feedback, message, status == 0)
        self.call_from_thread(self.action_reload)

    def feedback(self, message, ok=None):
        icon, style = {True: ("✓ ", "green"), False: ("✗ ", "red"), None: ("", "")}[ok]
        bar = self.main.query_one("#feedback", Static)
        bar.update(Text(icon + message, style=style, no_wrap=True, overflow="ellipsis"))
        bar.display = True
        if self.feedback_timer:
            self.feedback_timer.stop()
        if ok is not None:
            self.feedback_timer = self.set_timer(FEEDBACK_SECONDS, lambda: setattr(bar, "display", False))


if __name__ == "__main__":
    ProxyTui().run()
