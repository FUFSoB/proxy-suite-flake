"""What proxy-tui and proxy-suite-gui show and do, without drawing any of it.

Reads come from proxy_ctl in-process. Every change runs proxy-ctl itself, so
validation, permission errors and systemd triggers stay in one place, and its
die() cannot take a front end down.
"""

import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable

import proxy_ctl as ctl

CTL = "proxy-ctl"


def _die(message, status=1):
    # Readers run in-process: the message rides the SystemExit, so an empty tab can say why.
    sys.exit(message)


# Clash API calls and systemctl spawns that several readers repeat within one load.
MEMOIZED = ("_outbound_current", "_outbound_inventory", "_autoproxy_state", "_autoproxy_next_run", "svc_state")
# proxy_ctl as the CLI has it, before the patching below: its own tests put these back.
CLI_FUNCTIONS = {name: getattr(ctl, name) for name in ("die", *MEMOIZED)}

ctl.die = _die

_memo = {}  # (reader, args) -> result, cleared at the start of every load


def _per_load(fn):
    def wrapped(*args):
        key = (fn, args)
        if key not in _memo:
            _memo[key] = fn(*args)
        return _memo[key]

    return wrapped


for _name in MEMOIZED:
    setattr(ctl, _name, _per_load(getattr(ctl, _name)))


def new_load():
    _memo.clear()


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
    return ctl._unit_states(units)


def all_units():
    # The subscription update is read for the status line and the tray; it is no service to toggle.
    return ctl._snapshot_units()


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
    return [
        {"key": u, "unit": u, "name": u.removeprefix("proxy-suite-"), "state": s}
        for u, s in states.items()
        if u != ctl.SUBSCRIPTION_UPDATE
    ]


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


def snapshot(states):
    """proxy-ctl's status snapshot for these unit states; None when it cannot be read."""
    return _safe(ctl._status_snapshot, states)


def status_items(states):
    """(label, value, style) for the status line: style is "", "ok", "warn" or "bad"."""
    items = []
    overall = ctl._overall_state(snapshot(states) if states else None)
    items.append(("", overall["label"], {"failed": "bad", "busy": "warn", "unknown": "bad"}.get(overall["badge"], "")))
    if "proxy-suite-socks" in states:
        default = " (default)" if ctl._route_mode_current() == "default" else ""
        items.append(("mode ", ctl._route_mode_effective() + default, ""))
        items.append(("outbound ", ctl._status_outbound() or "-", ""))
    if autoproxy := ctl._status_autoproxy():
        items.append(("autoProxy ", autoproxy, ""))
    if zapret := ctl._status_zapret():
        items.append(("zapret ", f"{zapret} learned", ""))
    failed = sum(1 for s in states.values() if s == "failed")
    if failed:
        items.append(("", f"{failed} failed", "bad"))
    return items


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


def _sub_url(row):
    return bool(row["user"]) and bool(ctl.env("INBOUNDS_SUB_BASE_URL"))


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
            Action("n", "add a runtime outbound…", lambda r, t, _: ["proxy", "outbounds", "add", *t.split(None, 1)], prompt="<tag> <url or JSON>"),
            Action("d", "remove it", lambda r, *_: ["proxy", "outbounds", "rm", r["tag"]], when=lambda r: r["runtime"], confirm=True),
            # Credentials: proxy-ctl refuses these without root, and the dialog says so.
            Action("l", "its URL", lambda r, *_: ["proxy", "outbounds", "link", r["tag"]], when=ROW, mode="dialog"),
            Action("c", "copy its URL", lambda r, *_: ["proxy", "outbounds", "link", r["tag"]], when=ROW, mode="copy"),
            Action("Q", "its URL as QR", lambda r, *_: ["proxy", "outbounds", "link", r["tag"], "--qr"], when=ROW, mode="dialog"),
            Action("J", "its JSON", lambda r, *_: ["proxy", "outbounds", "link", r["tag"], "--json"], when=ROW, mode="dialog"),
            Action("F", "client config for it alone", lambda r, *_: ["proxy", "outbounds", "link", r["tag"], "--config"], when=ROW, mode="dialog"),
            Action("X", "client config with every outbound and rule", lambda r, *_: ["proxy", "config"], mode="dialog"),
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
            Action("k", "its URL", lambda r, *_: ["proxy", "subs", "link", r["tag"]], when=ROW, mode="dialog"),
            Action("y", "copy its URL", lambda r, *_: ["proxy", "subs", "link", r["tag"]], when=ROW, mode="copy"),
            Action("Q", "its URL as QR", lambda r, *_: ["proxy", "subs", "link", r["tag"], "--qr"], when=ROW, mode="dialog"),
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
            # Without subscriptions.baseUrl there is only a file path, with a hint after it: nothing to encode or copy.
            Action("S", "subscription URL as QR", lambda r, *_: ["inbounds", "sub", r["user"], "--qr"], when=_sub_url, mode="dialog"),
            Action("y", "copy subscription URL", lambda r, *_: ["inbounds", "sub", r["user"]], when=_sub_url, mode="copy"),
            Action("J", "client's outbound JSON", lambda r, *_: _link(r, "--json"), when=ROW, mode="dialog"),
            Action("V", "server's inbound JSON", lambda r, *_: ["inbounds", "link", r["tag"], "--server-json"], when=ROW, mode="dialog"),
            Action("t", "traffic per user", lambda r, *_: ["inbounds", "stats"], mode="dialog"),
            Action("o", "who is online", lambda r, *_: ["inbounds", "online"], mode="dialog"),
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

WHERE = Action("w", "How is a domain routed", lambda r, t, _: ["where", t], prompt="<domain>", mode="dialog")


def available_tabs(states):
    return [t.id for t in TABS if _safe(t.available, states, fallback=False)]


def applicable(tab, row):
    return [a for a in tab.actions if a.when is None or (row is not None and a.when(row))]


def load_tab(tab, states):
    """(rows, summary) for a tab: a failed read empties the rows and says why in the summary."""
    summary = (_safe(tab.summary, fallback="") or "") if tab.summary else ""
    try:
        rows = tab.rows(states)
    except (Exception, SystemExit) as e:
        return [], f"✗ {str(e) or type(e).__name__}" + (f"\n{summary}" if summary else "")
    if not rows:
        hints = "   ".join(f"{a.key}: {short(a.label)}" for a in tab.actions if a.prompt)
        summary = "Nothing here yet." + (f"   {hints}" if hints else "") + (f"\n{summary}" if summary else "")
    return rows, summary


def short(label):
    return label.split(" (")[0].removesuffix("…")


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


# --- tray menu ----------------------------------------------------------------


@dataclass
class MenuItem:
    id: str
    label: str = ""
    kind: str = "normal"  # normal, check, radio, separator, submenu
    checked: bool = False
    enabled: bool = True
    argv: list = None  # proxy-ctl argv to run when clicked
    app: str = ""  # or an app action: open, quit
    confirm: bool = False
    children: list = field(default_factory=list)


def _sep(n):
    return MenuItem(f"sep-{n}", kind="separator")


def tray_menu(snap, outbounds=None):
    """The tray's menu for a status snapshot (None: unreadable). outbounds: (tags, pinned) or None."""
    overall = ctl._overall_state(snap)
    items = [MenuItem("status", overall["label"] + (f" — {len(snap['failed'])} failed" if snap and snap["failed"] else ""), enabled=False)]
    items.append(MenuItem("open", "Open Proxy Suite", app="open"))
    if snap is None:
        return items + [_sep(0), MenuItem("quit", "Quit", app="quit")]
    items.append(_sep(1))
    if snap["proxy"]["available"]:
        active = snap["proxy"]["active"]
        items.append(MenuItem("proxy", "Proxy", kind="check", checked=active, argv=["proxy", "off" if active else "on"], confirm=active))
    if snap["route_mode"]["available"]:
        current = snap["route_mode"]["current"]
        items.append(
            MenuItem(
                "mode",
                f"Routing: {ctl._route_mode_label(current)}",
                kind="submenu",
                children=[
                    MenuItem(f"mode-{m}", ctl._route_mode_label(m), kind="radio", checked=m == current, argv=["proxy", "mode", m])
                    for m in ("default", *ctl.ROUTE_MODES)
                ],
            )
        )
    if outbounds and outbounds[0]:
        tags, pinned = outbounds
        items.append(
            MenuItem(
                "pin",
                f"Outbound: {pinned or 'auto'}",
                kind="submenu",
                children=[
                    MenuItem("pin-auto", "Automatic (unpin)", kind="radio", checked=not pinned, argv=["proxy", "unpin"]),
                    _sep(2),
                    *(MenuItem(f"pin-{t}", t, kind="radio", checked=t == pinned, argv=["proxy", "pin", t]) for t in tags),
                ],
            )
        )
    traffic = []
    for name, label in (("tun", "TUN mode"), ("tproxy", "TProxy mode")):
        if snap[name]["available"]:
            active = snap[name]["active"]
            traffic.append(MenuItem(name, label, kind="check", checked=active, argv=["proxy", name, "off" if active else "on"]))
    if snap["awg"]["available"]:
        current = snap["awg"]["active"]
        traffic.append(
            MenuItem(
                "awg",
                f"AmneziaWG: {current or 'off'}",
                kind="submenu",
                children=[
                    MenuItem("awg-off", "Off", kind="radio", checked=not current, argv=["awg", "off"]),
                    *(MenuItem(f"awg-{p}", p, kind="radio", checked=p == current, argv=["awg", "on", p]) for p in snap["awg"]["profiles"]),
                ],
            )
        )
    if traffic:
        items += [_sep(3), *traffic]
    if snap["zapret"]["available"]:
        active = snap["zapret"]["active"]
        items += [_sep(4), MenuItem("zapret", "zapret (DPI bypass)", kind="check", checked=active, argv=["zapret", "off" if active else "on"])]
    items.append(_sep(5))
    if snap["subscription_update"]["available"]:
        busy = snap["subscription_update"]["state"] in ctl.BUSY_STATES
        items.append(MenuItem("subs", "Updating subscriptions…" if busy else "Update subscriptions", enabled=not busy, argv=["proxy", "subs", "update"]))
    items.append(MenuItem("restart", "Restart active services", argv=["restart"]))
    items += [_sep(6), MenuItem("quit", "Quit", app="quit")]
    return items


def tray_outbounds(snap):
    """(tags, pinned) for the tray's pin submenu, when the proxy runs."""
    if not snap or not snap["proxy"]["active"]:
        return None
    inventory = _safe(ctl._outbound_inventory, fallback={}) or {}
    return [ctl._s(t) for t in inventory.get("tags") or []], ctl._s(inventory.get("pinned") or "")


def icon_name(overall):
    return "proxy-suite-" + overall["base"] + (f"-{overall['badge']}" if overall["badge"] else "")
