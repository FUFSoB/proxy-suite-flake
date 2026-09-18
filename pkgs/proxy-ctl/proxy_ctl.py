"""proxy-ctl: control proxy-suite services and inspect their runtime state.

Configuration arrives through the environment the Nix wrapper sets.
"""

import base64
import datetime
import http.client
import importlib
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ALL_SERVICES = [
    "proxy-suite-socks",
    "proxy-suite-tproxy",
    "proxy-suite-tun",
    "proxy-suite-inbounds",
    "proxy-suite-ssh-proxy",
    "proxy-suite-warp",
    "proxy-suite-warp-tunnel",
    "proxy-suite-tor",
    "proxy-suite-tg-ws-proxy",
    "proxy-suite-zapret",
    "proxy-suite-zapret-vm-exempt",
]

RESTART_SERVICES = [
    "proxy-suite-tproxy",
    "proxy-suite-tun",
    "proxy-suite-inbounds",
    "proxy-suite-ssh-proxy",
    "proxy-suite-warp-tunnel",
    "proxy-suite-tor",
    "proxy-suite-tg-ws-proxy",
    "proxy-suite-zapret",
]

HELP = """\
Usage: proxy-ctl <group> [verb] [args]
A group without a verb shows its status or list.
Secrets and changes need root, or the userControl group.

  status [--json]                        services and routing mode (--tray: deprecated key=value lines)
  restart                                restart active services
  logs [unit]                            follow logs (default: every proxy-suite unit)
  where <domain>                         how this host is routed right now

  proxy [status|on|off]                  local proxy backend
  proxy outbounds [list]                 outbounds, where each came from, and the pick
  proxy outbounds add [tag] <url|json|-> [--detour <tag>]
                                         add an outbound at runtime: a URL, or sing-box/XRay JSON (-: stdin),
                                         chained through another outbound with --detour; the tag first,
                                         or left out to name it after the link
  proxy outbounds chain <tag> <through-tag> [new tag]
                                         add a copy of an existing outbound that dials through
                                         another one; the original keeps dialing the way it did
  proxy outbounds rm <tag>               remove a runtime outbound
  proxy outbounds disable|enable <tag>   keep an outbound out of automatic use (selection, autoProxy, pins),
                                         or let it back in; declared ones too
  proxy outbounds test [tag...] [--ping] [--delay] [--download]
                                         TCP ping, real delay, download speed (default: ping, delay)
  proxy outbounds link <tag> [--qr|--json|--config]
                                         its URL, QR code, backend JSON, or a client config for it
  proxy pin [tag]                        always use this outbound (no tag: pick from a menu)
  proxy unpin                            let the configured selection pick again
  proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]
                                         show or override the routing mode
  proxy subs [list|update]               subscription caches; update refetches them
  proxy subs add [tag] <url>             add a subscription at runtime; no tag: named after its host
  proxy subs rm <tag>                    remove a runtime subscription
  proxy subs link <tag> [--qr]           its URL
  proxy config [--raw]                   client config to import elsewhere; --raw: as running
  proxy tun [status|on|off]              global TUN mode
  proxy tproxy [status|on|off]           global TProxy mode
  proxy auto [list]                      what autoProxy routed, and via which exit
  proxy auto probe <domain>[/path] [--json] [--keep-going] [--exits a,b | --via tag]
                                         find an exit that reaches a domain
  proxy auto learn <domain>              probe now and route it if an exit works
  proxy auto forget <domain>             drop what was learned about it: direct until learned again
  proxy auto relearn <domain>            forget it, then probe the host it was learned from now
  proxy auto clear                       forget every learned route and verdict
  proxy auto queue [count]               destinations waiting to be probed

  zapret [status|on|off]                 DPI bypass
  zapret auto [list]                     hosts zapret2 learned as blocked
  zapret auto add|forget|exclude <domain>
                                         pin, forget, or never learn a host
  zapret auto unpin|include <domain>     undo add, or undo exclude
  zapret auto clear                      forget learned hosts and strategies
  zapret cutoff [status]                 networks this line cuts at 16 KB, and their names
  zapret cutoff probe                    probe this line again now

  awg [list]                             AmneziaWG profiles and their state
  awg on <profile> | off [profile] | restart [profile]

  ssh [status|on|off]                    SSH SOCKS5 tunnel
  warp [status|on|off]                   WARP tunnel behind the warp outbound
  tor [status|on|off]                    Tor, behind the tor outbound and the onion service
  tor newnym                             new circuits for new connections
  tg [status|on|off]                     Telegram WebSocket proxy

  apps [list]                            per-app routing profiles
  apps run <profile> -- <cmd> [args]     run a command through a profile

  inbounds [list]                        server inbounds
  inbounds link <tag> [user] [--onion] [--qr|--json]
                                         client share link, or the client's outbound JSON;
                                         --onion: the one through the onion service
  inbounds link <tag> [user] --config [--qr]
                                         an AmneziaWG client's .conf, or its QR code
  inbounds link <tag> --server-json      the server's inbound JSON
  inbounds sub [user] [--qr]             subscription users, or one user's URL
  inbounds stats [days] [--by user|inbound|outbound]
                                         traffic per user, listener or exit
  inbounds online                        who is connected now, and when the rest were last seen
"""

ROUTE_MODES = ["whitelist", "blacklist", "all-proxy", "all-bypass"]
ROUTE_MODE_LABELS = {
    "whitelist": "Whitelist (direct by default)",
    "blacklist": "Blacklist (proxy by default)",
    "all-proxy": "All Proxy (override)",
    "all-bypass": "All Bypass (override)",
}

# A hostname: it lands in root-owned files and then in URLs.
HOSTNAME = re.compile(r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


# --- plumbing -----------------------------------------------------------------


def env(name, default=""):
    return os.environ.get(name) or default


def die(message, status=1):
    sys.stdout.flush()
    print(message, file=sys.stderr)
    sys.exit(status)


def usage(text):
    die(f"Usage: proxy-ctl {text}")


def _s(value):
    """A JSON value the way `jq -r` prints it."""
    return value if isinstance(value, str) else json.dumps(value)


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def require_enabled(variable, feature):
    """Refuses when the module did not build this feature in."""
    if env(variable) != "1":
        die(f"{feature} is not enabled in this configuration.")


def read_json_or(path, fallback):
    """The JSON at path, or fallback when it is missing, unreadable or not JSON."""
    try:
        value = read_json(path)
    except (OSError, ValueError):
        return fallback
    return value if isinstance(value, type(fallback)) else fallback


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def lines(text):
    """Lines the way awk and grep see them: a missing final newline is fine."""
    if not text:
        return []
    parts = text.split("\n")
    return parts[:-1] if text.endswith("\n") else parts


def readable(path):
    return bool(path) and os.access(path, os.R_OK)


def privileged():
    """Whether the services run as root: off on rootless hosts (home-manager, nix-on-droid)."""
    return env("PRIVILEGED", "1") == "1"


def service_manager():
    """What runs the units: systemd, systemd-user (home-manager), or supervisor (nix-on-droid)."""
    return env("SERVICE_MANAGER", "systemd")


def state_dir():
    return env("STATE_DIR", "/var/lib/proxy-suite")


def runtime_dir():
    """The parent of the units' runtime directories (proxy-suite-socks, ...)."""
    return env("RUNTIME_DIR", "/run")


def ask_group():
    """What lets a refused user in: root, or userControl's group with the scope for it."""
    if not privileged():
        return "check its owner and permissions"
    return f"join the {env('USER_CONTROL_GROUP', 'proxy-suite')} group, or re-run with sudo"


def denied(path, what="read"):
    die(f"Cannot {what} {path} - {ask_group()}.")


def _run(argv, capture=False, quiet=False, stdin=None):
    """Runs argv; (exit status, stdout if captured). A missing binary is 127."""
    sys.stdout.flush()
    try:
        p = subprocess.run(
            argv,
            input=stdin,
            stdout=subprocess.PIPE if capture else (subprocess.DEVNULL if quiet else None),
            stderr=subprocess.DEVNULL if quiet else None,
            text=True,
        )
    except OSError:
        return 127, ""
    return p.returncode, p.stdout or ""


def _run_foreground(argv):
    """Waits on argv the way a shell does: Ctrl-C is the child's to handle."""
    sys.stdout.flush()
    try:
        p = subprocess.Popen(argv)
    except OSError:
        return 127
    old = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        return p.wait()
    finally:
        signal.signal(signal.SIGINT, old)


def _exec(argv):
    sys.stdout.flush()
    try:
        os.execvp(argv[0], argv)
    except OSError as e:
        die(f"proxy-ctl: {argv[0]}: {e.strerror}", 126 if isinstance(e, PermissionError) else 127)


def _manager_argv(tool, args):
    """tool (systemctl, journalctl) with args, aimed at the manager that runs the units.

    Under systemd-user every unit is a user unit, so a --user of the caller's is redundant.
    Without systemd (nix-on-droid), proxy-suitectl answers both.
    """
    if service_manager() == "systemd-user":
        return [tool, "--user", *(a for a in args if a != "--user")]
    if service_manager() == "supervisor":
        ctl = env("SUPERVISOR_CTL", "proxy-suitectl")
        rest = [a for a in args if a != "--user"]
        return [ctl, "journal", *rest] if tool == "journalctl" else [ctl, *rest]
    return [tool, *args]


def systemctl(*args, capture=False, quiet=False):
    return _run(_manager_argv("systemctl", args), capture=capture, quiet=quiet)


def journal_hint(unit, count=None):
    """The command that shows unit's log, for messages."""
    return " ".join(_manager_argv("journalctl", ["-u", unit, *(["-n", str(count)] if count else [])]))


def must(*args):
    """systemctl that ends proxy-ctl with its status when it fails."""
    status, _ = systemctl(*args)
    if status:
        sys.exit(status)


def svc_exists(unit):
    return systemctl("cat", unit, quiet=True)[0] == 0


def svc_active(unit):
    return systemctl("is-active", "--quiet", unit)[0] == 0


def svc_state(unit):
    return systemctl("is-active", unit, capture=True, quiet=True)[1].rstrip("\n")


def _bool(value):
    return "true" if value else "false"


def _toggle(unit, name, verb="status", *_):
    if not svc_exists(unit):
        die(f"{name} is not enabled in this configuration.")
    if verb == "status":
        systemctl("is-active", unit)
    elif verb == "on":
        must("start", unit)
    elif verb == "off":
        must("stop", unit)
    else:
        usage(f"{name} [status|on|off]")


def _warp_unit():
    """The unit behind the warp outbound: its sing-box tunnel, or an outbound AmneziaWG profile.

    A global "warp" profile belongs to `awg on warp`, not here.
    """
    awg = _awg_service("warp")
    if "warp" not in _awg_profiles() and svc_exists(awg):
        return awg
    return "proxy-suite-warp-tunnel"


def _tor_control(*commands):
    """Replies to commands on Tor's control socket, one list of lines per command.

    The socket authenticates by who can open it: root and the userControl group.
    """
    path = env("TOR_CONTROL_SOCKET", f"{runtime_dir()}/proxy-suite-tor/control/socket")
    replies = []
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(path)
            stream = sock.makefile("rwb")
            for command in ("AUTHENTICATE", *commands):
                stream.write(command.encode("ascii") + b"\r\n")
                stream.flush()
                lines = []
                while True:
                    line = stream.readline()
                    if not line:
                        die("Tor closed its control connection.")
                    line = line.decode("utf-8", "replace").rstrip("\r\n")
                    lines.append(line)
                    # "250-" and "250+" continue a reply; "250 " ends it.
                    if len(line) >= 4 and line[3] == " ":
                        break
                if not lines[-1].startswith("250"):
                    die(f"Tor refused {command.split()[0]}: {lines[-1]}")
                replies.append(lines)
    except PermissionError:
        denied(path, "open")
    except (FileNotFoundError, ConnectionRefusedError):
        die("Tor is not running: no control socket.")
    except OSError as exc:
        die(f"Cannot talk to Tor: {exc}")
    return replies[1:]


def _tor_bootstrap():
    """Tor's bootstrap progress, as "100% (Done)"."""
    line = _tor_control("GETINFO status/bootstrap-phase")[0][0]
    progress = re.search(r"PROGRESS=(\d+)", line)
    summary = re.search(r'SUMMARY="((?:[^"\\]|\\.)*)"', line)
    if not progress:
        return line
    return f"{progress.group(1)}%" + (f" ({summary.group(1)})" if summary else "")


def cmd_tor(verb="status", *args):
    unit = "proxy-suite-tor"
    if verb == "newnym":
        if not svc_exists(unit):
            die("tor is not enabled in this configuration.")
        _tor_control("SIGNAL NEWNYM")
        print("New connections take new circuits (Tor allows this once every 10 seconds).")
        return
    if verb not in ("status", "on", "off"):
        usage("tor [status|on|off|newnym]")
    _toggle(unit, "tor", verb, *args)
    if verb == "status" and svc_active(unit):
        # Extra detail: the unit's state stands without it, for a user outside the group
        # or a Tor that has not opened its socket yet. The reason is on stderr.
        try:
            print(f"bootstrap {_tor_bootstrap()}")
        except SystemExit:
            print("bootstrap unknown")


def _emit(text, qr):
    """Prints text, or its QR code."""
    if not qr:
        print(text)
        return
    status, _ = _run(["qrencode", "-t", "ANSIUTF8"], stdin=text)
    if status:
        sys.exit(status)


def _json_list(path):
    return [_s(x) for x in read_json_or(path, [])]


def _sub_tags():
    return _json_list(env("SUB_TAGS_FILE"))


def _awg_profiles():
    return _json_list(env("AWG_PROFILES_FILE"))


# --- completion ---------------------------------------------------------------
#
# Candidates for the words already typed, one per line as word<TAB>description.
# The tree lives here, next to HELP, not in the completion files. A node offers
# its words and args until a positional is typed (always, when it repeats), and
# its flags until each is typed.

TOGGLE = {"status": "is it running", "on": "start it", "off": "stop it"}


def _outbound_choices():
    sources = _outbound_inventory().get("sources") or {}
    return {tag: _s(sources.get(tag) or "") for tag in _outbound_tags()}


def _inbound_link_choices():
    links = read_json(env("INBOUNDS_LINKS_FILE"))
    return dict(sorted((_s(x["tag"]), f"{_s(x.get('type', ''))} {_s(x.get('port', ''))}".strip()) for x in links))


def _autoproxy_choices():
    domains = read_json(os.path.join(_autoproxy_dir(), "state.json")).get("domains") or {}
    return {d: f"via {_s(v['exit'])}" if isinstance(v, dict) and "exit" in v else "" for d, v in sorted(domains.items())}


def _names(values):
    return dict.fromkeys(values, "")


COMPLETE = {
    "": {
        "words": {
            "status": "services and routing mode",
            "restart": "restart active services",
            "logs": "follow logs",
            "where": "how a host is routed right now",
            "proxy": "local proxy backend",
            "zapret": "DPI bypass",
            "awg": "AmneziaWG profiles",
            "ssh": "SSH SOCKS5 tunnel",
            "warp": "WARP tunnel behind the warp outbound",
            "tor": "Tor, behind the tor outbound and the onion service",
            "tg": "Telegram WebSocket proxy",
            "apps": "per-app routing profiles",
            "inbounds": "server inbounds",
            "help": "usage",
        }
    },
    "status": {"flags": {"--json": "machine-readable state, with the GUI's overall state"}},
    "logs": {"args": lambda: _names(_snapshot_units()), "repeat": True},
    "where": {"args": _autoproxy_choices},
    "proxy": {
        "words": {
            **TOGGLE,
            "outbounds": "outbounds, where each came from, and the pick",
            "pin": "always use this outbound",
            "unpin": "let the configured selection pick again",
            "mode": "show or override the routing mode",
            "subs": "subscription caches",
            "tun": "global TUN mode",
            "tproxy": "global TProxy mode",
            "auto": "what autoProxy routed",
            "config": "client config to import elsewhere",
        }
    },
    "proxy config": {"flags": {"--raw": "the config as it runs here"}},
    "proxy outbounds": {
        "words": {
            "list": "outbounds, where each came from, and the pick",
            "add": "add an outbound at runtime: [tag] <url or JSON>",
            "chain": "copy an outbound so it dials through another one",
            "rm": "remove a runtime outbound",
            "disable": "keep it out of automatic use",
            "enable": "let a disabled outbound back in",
            "test": "TCP ping, real delay, download speed",
            "link": "its URL, QR code, JSON or client config",
        }
    },
    "proxy outbounds add": {"flags": {"--detour": "chain it through another outbound"}},
    "proxy outbounds link": {
        "args": _outbound_choices,
        "flags": {"--qr": "print a QR code", "--json": "backend JSON", "--config": "client config for this server"},
    },
    # The outbound to copy, then the hop; the third word is the new tag, which nothing can suggest.
    "proxy outbounds chain": {"args": _outbound_choices, "repeat": True},
    "proxy outbounds rm": {"args": lambda: _names(_runtime_tags("outbound"))},
    "proxy outbounds disable": {"args": lambda: {t: d for t, d in _outbound_choices().items() if t not in _outbound_disabled()}},
    "proxy outbounds enable": {"args": lambda: _names(_outbound_disabled())},
    "proxy outbounds test": {
        "args": _outbound_choices,
        "repeat": True,
        "flags": {
            "--ping": "TCP connect to each server",
            "--delay": "the backend's URL test through each outbound",
            "--download": "timed download through each outbound",
        },
    },
    "proxy pin": {"args": lambda: {t: d for t, d in _outbound_choices().items() if t not in _outbound_disabled()}},
    "proxy mode": {"args": lambda: {"default": f"config default ({_route_mode_default()})", **ROUTE_MODE_LABELS}},
    "proxy subs": {
        "words": {
            "list": "subscription caches",
            "update": "refetch the subscriptions",
            "add": "add a subscription at runtime: [tag] <url>",
            "rm": "remove a runtime subscription",
            "link": "its URL",
        }
    },
    "proxy subs link": {"args": lambda: _names(_sub_tags() + _runtime_tags("subscription")), "flags": {"--qr": "print a QR code"}},
    "proxy subs rm": {"args": lambda: _names(_runtime_tags("subscription"))},
    "proxy tun": {"words": TOGGLE},
    "proxy tproxy": {"words": TOGGLE},
    "proxy auto": {
        "words": {
            "list": "what autoProxy routed, and via which exit",
            "probe": "find an exit that reaches a domain",
            "learn": "probe now and route it if an exit works",
            "forget": "drop what was learned about a domain",
            "relearn": "forget a domain, then probe it again now",
            "clear": "forget every learned route and verdict",
            "queue": "destinations waiting to be probed",
        }
    },
    "proxy auto forget": {"args": _autoproxy_choices},
    "proxy auto relearn": {"args": _autoproxy_choices},
    "proxy auto probe": {
        "flags": {
            "--json": "machine-readable result",
            "--keep-going": "try every exit, not just until one works",
            "--exits": "only these exits, comma-separated",
            "--via": "probe through this one exit",
        }
    },
    "zapret": {"words": {**TOGGLE, "auto": "hosts zapret2 learned as blocked", "cutoff": "networks this line cuts at 16 KB"}},
    "zapret auto": {
        "words": {
            "list": "hosts zapret2 learned as blocked",
            "add": "pin a host",
            "forget": "forget a learned host",
            "exclude": "never learn a host",
            "unpin": "undo add",
            "include": "undo exclude",
            "clear": "forget learned hosts and strategies",
        }
    },
    "zapret auto forget": {"args": lambda: _names(lines(read_text(_zapret_auto_file("zapret-hosts-auto.txt"))))},
    "zapret auto exclude": {"args": lambda: _names(lines(read_text(_zapret_auto_file("zapret-hosts-auto.txt"))))},
    "zapret auto unpin": {"args": lambda: _names(lines(read_text(_zapret_auto_file("zapret-hosts-user.txt"))))},
    "zapret auto include": {"args": lambda: _names(lines(read_text(_zapret_auto_file("zapret-hosts-user-exclude.txt"))))},
    "zapret cutoff": {"words": {"status": "networks this line cuts at 16 KB", "probe": "probe this line again now"}},
    "awg": {
        "words": {
            "list": "profiles and their state",
            "on": "start a profile",
            "off": "stop a profile",
            "restart": "restart a profile",
        }
    },
    "awg on": {"args": lambda: _names(_awg_profiles())},
    "awg off": {"args": lambda: _names(_awg_profiles())},
    "awg restart": {"args": lambda: _names(_awg_profiles())},
    "ssh": {"words": TOGGLE},
    "warp": {"words": TOGGLE},
    "tor": {"words": {**TOGGLE, "newnym": "new circuits for new connections"}},
    "tg": {"words": TOGGLE},
    "apps": {"words": {"list": "per-app routing profiles", "run": "run a command through a profile"}},
    "apps run": {"args": lambda: {_s(p["name"]): _s(p.get("route") or "") for p in read_json(env("PER_APP_ROUTING_PROFILES_FILE"))}},
    "inbounds": {
        "words": {
            "list": "server inbounds",
            "link": "client share link",
            "sub": "subscription users, or one user's URL",
            "stats": "traffic per user, listener or exit",
            "online": "who is connected now",
        }
    },
    "inbounds stats": {"flags": {"--by": "user, inbound or outbound"}},
    "inbounds link": {
        "args": _inbound_link_choices,
        "flags": {
            "--qr": "print a QR code",
            "--onion": "the link through the onion service",
            "--json": "the client's outbound JSON",
            "--config": "an AmneziaWG client's .conf",
            "--server-json": "the server's inbound JSON",
        },
    },
    "inbounds sub": {
        "args": lambda: _names(_s(x["user"]) for x in read_json(env("INBOUNDS_SUBS_FILE"))),
        "flags": {"--qr": "print a QR code"},
    },
}


def _complete_tree(*words):
    path, rest = "", list(words)
    while rest and f"{path} {rest[0]}".strip() in COMPLETE:
        path = f"{path} {rest.pop(0)}".strip()
    node = COMPLETE[path]
    if rest[-1:] in (["--exits"], ["--via"], ["--detour"]):
        return _outbound_choices()
    if rest[-1:] == ["--by"]:
        return _names(STATS_KINDS)
    candidates = {}
    if node.get("repeat") or not [w for w in rest if not w.startswith("-")]:
        candidates.update(node.get("words", {}))
        try:
            candidates.update(node["args"]() if "args" in node else {})
        except Exception:
            pass  # Unreadable state costs the values, not the verbs and flags.
    candidates.update((f, d) for f, d in node.get("flags", {}).items() if f not in rest)
    return candidates


def cmd_complete(*words):
    """The hidden verb the shell completions call. It never fails or speaks."""
    try:
        candidates = _complete_tree(*words)
    except Exception:
        return
    for word, description in candidates.items():
        print(f"{word}\t{description}" if description else word)


# --- status -------------------------------------------------------------------


def _route_mode_default():
    return env("DEFAULT_ROUTE_MODE", "blacklist")


def _route_mode_effective():
    mode = ""
    try:
        mode = re.sub(r"\s", "", read_text(env("ROUTE_MODE_STATE_FILE")))
    except OSError:
        pass
    return mode if mode in ROUTE_MODES else _route_mode_default()


def _route_mode_current():
    return _route_mode_effective() if readable(env("ROUTE_MODE_STATE_FILE")) else "default"


def _route_mode_label(mode):
    if mode == "default":
        return f"Default: {ROUTE_MODE_LABELS.get(_route_mode_default(), 'Unknown')}"
    return ROUTE_MODE_LABELS.get(mode, "Unknown")


def _unit_states(units):
    """unit -> ActiveState for the units that exist, in one systemctl call."""
    if not units:
        return {}
    _, out = systemctl("show", "--property=Id,LoadState,ActiveState", "--", *units, capture=True, quiet=True)
    states = {}
    for unit, block in zip(units, out.strip().split("\n\n")):
        props = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if props.get("LoadState") not in (None, "not-found"):
            states[unit] = props.get("ActiveState", "unknown")
    return states


SNAPSHOT_UNITS = {
    "proxy": "proxy-suite-socks",
    "tproxy": "proxy-suite-tproxy",
    "tun": "proxy-suite-tun",
    "zapret": "proxy-suite-zapret",
}
SUBSCRIPTION_UPDATE = "proxy-suite-subscription-update"
BUSY_STATES = ("activating", "deactivating", "reloading")


def _snapshot_units():
    profiles = _awg_profiles()
    # WARP as an AmneziaWG outbound has no profile to toggle, but it is a unit that can fail (_warp_unit).
    warp = [] if "warp" in profiles else [_awg_service("warp")]
    return [*ALL_SERVICES, SUBSCRIPTION_UPDATE, *map(_awg_service, profiles), *warp]


def _status_snapshot(states=None):
    """What runs, as data: the GUI's tray, `status --json` and `status --tray` all read this.

    states: unit -> ActiveState for the existing units, when the caller already has them.
    """
    if states is None:
        states = _unit_states(_snapshot_units())
    profiles = _awg_profiles()
    snapshot = {
        name: {"available": unit in states, "active": states.get(unit) == "active"} for name, unit in SNAPSHOT_UNITS.items()
    }
    snapshot["awg"] = {
        "available": bool(profiles),
        "profiles": profiles,
        "active": next((p for p in profiles if states.get(_awg_service(p)) == "active"), ""),
    }
    snapshot["route_mode"] = {
        "available": "proxy-suite-socks" in states,
        "current": _route_mode_current(),
        "default": _route_mode_default(),
    }
    snapshot["subscription_update"] = {"available": SUBSCRIPTION_UPDATE in states, "state": states.get(SUBSCRIPTION_UPDATE, "")}
    snapshot["units"] = dict(states)
    snapshot["failed"] = sorted(u for u, s in states.items() if s == "failed")
    snapshot["overall"] = _overall_state(snapshot)
    return snapshot


def _overall_state(snapshot):
    """base: the tray icon's color (tunnel > active > proxy > zapret > disabled); badge: failed > busy.

    A snapshot of None is state that could not be read.
    """
    if snapshot is None:
        return {"base": "disabled", "badge": "unknown", "label": "Status unavailable"}
    proxy, zapret = snapshot["proxy"]["active"], snapshot["zapret"]["active"]
    traffic = snapshot["tun"]["active"] or snapshot["tproxy"]["active"] or bool(snapshot["awg"]["active"])
    if traffic:
        base = "tunnel"
    elif proxy and zapret:
        base = "active"
    else:
        base = "proxy" if proxy else "zapret" if zapret else "disabled"
    if proxy:
        label = "Proxy" + (" + traffic" if traffic else "") + (" + zapret" if zapret else "")
        label = "Proxy only" if label == "Proxy" else label
    elif snapshot["awg"]["active"]:
        label = "AmneziaWG"
    elif traffic:
        # TUN runs its own backend, without proxy-suite-socks.
        label = "TUN" + (" + zapret" if zapret else "")
    else:
        label = "Zapret only" if zapret else "Inactive"
    units = snapshot.get("units") or {}
    if snapshot.get("failed"):
        badge = "failed"
    elif any(s in BUSY_STATES for s in units.values()):
        badge = "busy"
    else:
        badge = ""
    return {"base": base, "badge": badge, "label": label}


def _status_tray():
    """Deprecated key=value lines, for scripts written against the old tray."""
    snapshot = _status_snapshot()
    for key, name in (("socks", "proxy"), ("tproxy", "tproxy"), ("tun", "tun"), ("zapret", "zapret")):
        print(f"{key}_available={_bool(snapshot[name]['available'])}")
        print(f"{key}_active={_bool(snapshot[name]['active'])}")
    print(f"subscription_update_available={_bool(snapshot['subscription_update']['available'])}")
    print(f"route_mode_available={_bool(snapshot['route_mode']['available'])}")
    print(f"route_mode={snapshot['route_mode']['current']}")
    print(f"default_route_mode={snapshot['route_mode']['default']}")
    print(f"awg_available={_bool(snapshot['awg']['available'])}")
    print(f"awg_active={snapshot['awg']['active']}")
    print(f"awg_profiles={','.join(snapshot['awg']['profiles'])}")


def _status_tab(tab_id=""):
    """A front end's tab as JSON [rows, summary]: how the GUI reads, through pkexec, what only root can."""
    model = _module("proxy_model")
    tab = next((t for t in model.TABS if t.id == tab_id), None)
    if tab is None:
        usage(f"status --tab <{'|'.join(t.id for t in model.TABS)}>")
    print(json.dumps(model.load_tab(tab, model._read_states())))


def _status_json():
    snapshot = _status_snapshot()
    if snapshot["proxy"]["active"]:
        snapshot["outbound"] = _status_outbound() or ""
    snapshot["autoproxy"] = _status_autoproxy()
    snapshot["zapret"]["learned"] = _status_zapret()
    print(json.dumps(snapshot, indent=2))


def _status_row(key, value):
    print(f"  {key:<44} {value}")


def _status_row_if(key, value):
    """Nothing to say about a state that is absent or unreadable."""
    if value:
        _status_row(key, value)


def _svc_status(unit):
    if svc_exists(unit):
        _status_row(unit, svc_state(unit))


def _status_outbound():
    """The pin when there is one, otherwise whatever the backend is dialling, and the hop it chains through."""
    inventory = _outbound_inventory()
    pinned = _s(inventory.get("pinned") or "")
    tag = pinned or _outbound_current()
    # ponytail: detours are keyed by the inventory's tags; a `now` named otherwise shows no hop.
    hop = (inventory.get("detours") or {}).get(tag) if tag else None
    text = f"{tag} via {_s(hop)}" if hop else tag
    return f"{text} (pinned)" if pinned else text


def _status_autoproxy():
    if env("AUTOPROXY_ENABLED") != "1":
        return ""
    state = os.path.join(_autoproxy_dir(), "state.json")
    if not readable(state):
        return ""
    try:
        data = read_json(state)
        counts = [str(len(data.get(key) or {})) for key in ("domains", "backlog")]
        bad = sum(1 for e in (data.get("exits") or {}).values() if isinstance(e, dict) and e.get("bad") is True)
    except (OSError, ValueError, AttributeError, TypeError):
        counts, bad = ["?", "?"], 0
    text = f"{counts[0]} routed, {counts[1]} queued"
    if bad:
        text += f", {bad} bad exit{'' if bad == 1 else 's'}"
    next_run = _autoproxy_next_run()
    if next_run:
        text += f", next run {_in_time(next_run)}"
    return text


def _status_zapret():
    if env("ZAPRET_AUTO_ENABLED") != "1":
        return ""
    auto = _zapret_auto_file("zapret-hosts-auto.txt")
    if not readable(auto):
        return ""
    try:
        return str(sum(1 for line in lines(read_text(auto)) if line))
    except OSError:
        return ""


def cmd_status(*args):
    if args[:1] == ("--json",):
        _status_json()
        return
    if args[:1] == ("--tray",):
        _status_tray()
        return
    if args[:1] == ("--tab",):
        _status_tab(*args[1:2])
        return
    print("proxy-suite services:")
    for svc in _snapshot_units():
        if svc != SUBSCRIPTION_UPDATE:
            _svc_status(svc)
    if svc_exists("proxy-suite-socks"):
        print()
        print("routing:")
        _status_row("active mode", _route_mode_label(_route_mode_current()))
        _status_row_if("outbound", _status_outbound())
        _status_row_if("autoProxy", _status_autoproxy())
    zapret = _status_zapret()
    if zapret:
        print()
        print("zapret:")
        _status_row("learned hosts", zapret)


def cmd_restart(*_):
    """Restarts what is running; starting something stopped on purpose is `proxy on`."""
    for svc in ["proxy-suite-socks", *RESTART_SERVICES]:
        if svc_exists(svc) and svc_active(svc):
            must("restart", svc)
    for profile in _awg_profiles():
        if svc_active(_awg_service(profile)):
            must("restart", _awg_service(profile))


# --- proxy --------------------------------------------------------------------


def cmd_proxy(verb="status", *args):
    if verb in ("status", "on"):
        _toggle("proxy-suite-socks", "proxy", verb)
    elif verb == "off":
        if not svc_exists("proxy-suite-socks"):
            die("proxy is not enabled in this configuration.")
        for svc in ("proxy-suite-tproxy", "proxy-suite-tun"):
            if svc_exists(svc):
                systemctl("stop", svc)
        must("stop", "proxy-suite-socks")
    elif verb == "outbounds":
        cmd_outbounds(*args)
    elif verb == "config":
        _config_export(*args)
    elif verb == "pin":
        cmd_pin(*args)
    elif verb == "unpin":
        cmd_unpin()
    elif verb == "mode":
        cmd_route_mode(*args)
    elif verb == "subs":
        cmd_subscription(*args)
    elif verb == "tun":
        _toggle("proxy-suite-tun", "proxy tun", *args)
    elif verb == "tproxy":
        _toggle("proxy-suite-tproxy", "proxy tproxy", *args)
    elif verb == "auto":
        cmd_proxy_auto(*args)
    elif verb in ("probe", "learn", "forget", "relearn", "queue", "learned"):
        cmd_proxy_auto(verb, *args)
    else:
        usage("proxy [status|on|off|outbounds|pin|unpin|mode|subs|tun|tproxy|auto|config]")


def cmd_outbounds(verb="list", *args):
    if verb == "list":
        _outbounds_list()
    elif verb == "add":
        args = list(args)
        detour = ""
        if "--detour" in args:
            i = args.index("--detour")
            detour = args[i + 1] if i + 1 < len(args) else ""
            del args[i : i + 2]
            if not detour:
                usage("proxy outbounds add [tag] <url|json|-> [--detour <tag>]")
        _runtime_entry_add("outbound", *args, detour=detour)
    elif verb == "chain":
        cmd_outbound_chain(*args)
    elif verb in ("rm", "remove", "del"):
        _runtime_entry_rm("outbound", *args)
    elif verb == "disable":
        cmd_outbound_disable(*args)
    elif verb == "enable":
        cmd_outbound_enable(*args)
    elif verb == "test":
        cmd_outbounds_test(*args)
    elif verb == "link":
        _outbound_link(*args)
    else:
        usage("proxy outbounds [list|add [tag] <url|json|->|chain <tag> <through-tag>|rm <tag>|disable <tag>|enable <tag>|test [tag...]|link <tag>]")


def _outbound_inventory():
    """What the running backend wrote: tags, their sources, and the pin.

    Empty until the proxy has started once.
    """
    return read_json_or(env("OUTBOUND_INVENTORY_FILE"), {})


def _outbound_tags():
    return [_s(t) for t in _outbound_inventory().get("tags") or []]


def _outbound_disabled():
    """Disabled outbounds, as the running backend took them."""
    return [_s(t) for t in _outbound_inventory().get("disabled") or []]


def _require_outbound_inventory():
    if not _outbound_tags():
        die("No outbounds are available yet - is proxy-suite-socks running?")


def _outbound_current():
    """What the backend dials right now, when it exposes a selector.

    Empty otherwise, which is normal for XRay.
    """
    status, body = _clash("GET", "/proxies/proxy", timeout=5)
    now = body.get("now") if status == 200 and isinstance(body, dict) else None
    return "" if now is None else _s(now)


def _clash(method, path, body=None, timeout=10):
    """(HTTP status, JSON body or None) from the backend's Clash API; status 0 when unreachable."""
    # The API is on loopback: never through the shell's HTTP(S)_PROXY.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    data = None if body is None else json.dumps(body).encode()
    try:
        # Building the request is part of reaching the API: an unset or malformed
        # CLASH_API is "unreachable", not a traceback out of `status` or `where`.
        request = urllib.request.Request(
            f"{env('CLASH_API')}{path}", data=data, method=method, headers={"Content-Type": "application/json"}
        )
        with opener.open(request, timeout=timeout) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except (OSError, ValueError, http.client.HTTPException):
        return 0, None
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, None


# --- proxy outbounds test -----------------------------------------------------
#
# ping: a TCP connect to each outbound's server, from this host. delay: the
# backend's own URL test through the outbound, over the Clash API. download: a
# timed fetch through the loopback test listener, its selector switched to one
# outbound at a time. The socks start script writes what each needs next to the
# inventory: outbound-endpoints.json (servers; root and userControl only) and, on
# sing-box, outbound-test.json (listener, selector, user tag -> backend tag).

OUTBOUND_TESTS = ("ping", "delay", "download")
TEST_DOWNLOAD_HOST = "speed.cloudflare.com"
# Cloudflare refuses 100 MB and more; the fetch stops at the time limit anyway.
TEST_DOWNLOAD_PATH = "/__down?bytes=99000000"
TEST_DOWNLOAD_SECONDS = 10


def _runtime_file(name):
    return os.path.join(os.path.dirname(env("OUTBOUND_INVENTORY_FILE", f"{runtime_dir()}/proxy-suite-socks/outbounds.json")), name)


def _test_ping(endpoint, timeout=3):
    if not endpoint:
        return "-"
    # QUIC and WireGuard servers have no TCP handshake to time.
    if endpoint.get("network") == "udp":
        return "udp"
    try:
        family, kind, proto, _, addr = socket.getaddrinfo(endpoint["server"], endpoint["port"], type=socket.SOCK_STREAM)[0]
    except (OSError, UnicodeError, KeyError, TypeError):
        return "no DNS"
    with socket.socket(family, kind, proto) as s:
        s.settimeout(timeout)
        start = time.monotonic()
        try:
            s.connect(addr)
        except TimeoutError:
            return "timeout"
        except ConnectionRefusedError:
            return "refused"
        except OSError:
            return "failed"
        return f"{(time.monotonic() - start) * 1000:.0f} ms"


def _test_delay(backend_tag, url):
    query = urllib.parse.urlencode({"url": url, "timeout": 8000})
    status, body = _clash("GET", f"/proxies/{urllib.parse.quote(backend_tag, safe='')}/delay?{query}", timeout=12)
    if status == 200 and isinstance(body, dict) and "delay" in body:
        return f"{_s(body['delay'])} ms"
    return {0: "no API", 504: "timeout"}.get(status, "failed")


def _timed_download(port):
    """Megabits per second through the test listener, None when nothing arrived.

    A CONNECT tunnel by hand, so no proxy variable in the environment can send it
    anywhere else.
    """
    conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=TEST_DOWNLOAD_SECONDS)
    conn.set_tunnel(TEST_DOWNLOAD_HOST)
    got = 0
    start = time.monotonic()
    try:
        conn.request("GET", TEST_DOWNLOAD_PATH, headers={"User-Agent": "proxy-ctl"})
        response = conn.getresponse()
        while response.status == 200 and time.monotonic() - start < TEST_DOWNLOAD_SECONDS:
            chunk = response.read(65536)
            if not chunk:
                break
            got += len(chunk)
    except (OSError, http.client.HTTPException):
        pass
    finally:
        conn.close()
    return got * 8 / (time.monotonic() - start) / 1e6 if got else None


def _test_download(backend_tag, test):
    # ponytail: no lock, so two concurrent download tests measure each other's pick.
    status, _ = _clash("PUT", f"/proxies/{urllib.parse.quote(test['selector'], safe='')}", {"name": backend_tag})
    if not 200 <= status < 300:
        return "failed" if status else "no API"
    mbps = _timed_download(test["port"])
    return "failed" if mbps is None else f"{mbps:.1f} Mbit/s"


def cmd_outbounds_test(*args):
    flags = [a for a in args if a.startswith("-")]
    for flag in flags:
        if flag[2:] not in OUTBOUND_TESTS or not flag.startswith("--"):
            die(f"Unknown option: {flag}")
    tests = [t for t in OUTBOUND_TESTS if f"--{t}" in flags] or ["ping", "delay"]
    _require_outbound_inventory()
    known = _outbound_tags()
    tags = [a for a in args if not a.startswith("-")] or known
    for tag in tags:
        if tag not in known:
            die(f"Unknown outbound: {tag}")

    notes = []
    endpoints = {}
    if "ping" in tests:
        try:
            endpoints = read_json(_runtime_file("outbound-endpoints.json"))
        except PermissionError:
            notes.append(f"ping: cannot read the servers - {ask_group()}.")
        except (OSError, ValueError):
            pass
    test = {}
    if "delay" in tests or "download" in tests:
        try:
            test = read_json(_runtime_file("outbound-test.json"))
        except (OSError, ValueError):
            message = "Real delay and download need the sing-box or hybrid backend (restart proxy-suite-socks after an upgrade)."
            if flags:
                die(message)
            tests.remove("delay")
            notes.append(message)
    backend = test.get("outbounds") or {}

    def cell(kind, tag):
        if kind == "ping":
            return _test_ping(endpoints.get(tag))
        if not backend.get(tag):
            return "-"
        if kind == "delay":
            return _test_delay(backend[tag], test.get("url") or "https://www.gstatic.com/generate_204")
        return _test_download(backend[tag], test)

    # Ping and delay all at once, and done before any download competes with them.
    with ThreadPoolExecutor(max_workers=16) as pool:
        futures = {(k, t): pool.submit(cell, k, t) for t in tags for k in tests if k != "download"}
        early = {key: f.result() for key, f in futures.items()}

    width = max([12] + [len(t) + 2 for t in tags])
    print(f"  {'TAG':<{width}}" + "".join(f"{k.upper():<12}" for k in tests).rstrip())
    for tag in tags:
        # Downloads one at a time: they share the test listener.
        cells = [early[(k, tag)] if k != "download" else cell(k, tag) for k in tests]
        print((f"  {tag:<{width}}" + "".join(f"{c:<12}" for c in cells)).rstrip(), flush=True)
    for note in notes:
        print(note, file=sys.stderr)


def _outbounds_list():
    _require_outbound_inventory()
    inventory = _outbound_inventory()
    pinned = _s(inventory.get("pinned") or "")
    sources = inventory.get("sources") or {}
    detours = inventory.get("detours") or {}
    excluded = set(inventory.get("excluded") or [])
    disabled = set(_outbound_disabled())
    current = _outbound_current()
    reputation = _reputation_by_tag()

    print(f"Selection: {_s(inventory.get('selection') or 'first')}")
    print(f"Pinned:    {pinned or '(none)'}")
    if current:
        print(f"Current:   {current}")
    print()
    # The reputation column only once the autoProxy prober has checked some exit.
    rep = (lambda tag: f"{reputation.get(tag, '-'):<16} ") if reputation else (lambda tag: "")
    print(f"  {'TAG':<34} {'REPUTATION':<16} SOURCE" if reputation else f"  {'TAG':<34} SOURCE")
    for tag in _outbound_tags():
        mark = " "
        if tag == pinned:
            mark = "*"
        elif not pinned and tag == current:
            mark = ">"
        elif tag in disabled:
            mark = "-"
        notes = [f"via {_s(detours[tag])}"] if tag in detours else []
        notes += ["disabled"] if tag in disabled else ["never picked"] if tag in excluded else []
        print(f" {mark}{tag:<34} {rep(tag)}{', '.join([_s(sources.get(tag) or '-'), *notes])}")


# --- sharing ------------------------------------------------------------------
#
# The socks start script writes outbound-share.json, root and userControl's group only:
# the URL each outbound was given (none for one declared as JSON, WARP or SSH) and its
# backend JSON. A URL is never rebuilt from JSON. `proxy config` turns the running config into one another
# device can import (proxy_export).


def _read_root_json(path, what):
    if not os.path.isfile(path):
        die(f"No {what} yet - is proxy-suite-socks running?")
    if not readable(path):
        denied(path)
    return read_json(path)


def _share_args(args, flags, noun):
    rest = [a for a in args if not a.startswith("-")]
    given = [a for a in args if a.startswith("-")]
    for flag in given:
        if flag not in flags:
            die(f"Unknown option: {flag}")
    if len(rest) != 1 or len(given) > 1:
        usage(f"{noun} link <tag> [{'|'.join(flags)}]")
    return rest[0], given[0] if given else ""


def _json_text(value):
    return json.dumps(value, indent=2, ensure_ascii=False)


def _outbound_share_entry(tag):
    """What the socks start script recorded for an outbound: the URL it was given, and its backend JSON."""
    entry = (_read_root_json(_runtime_file("outbound-share.json"), "outbounds").get("outbounds") or {}).get(tag)
    if entry is None:
        die(f"Unknown outbound: {tag}")
    return entry


def _outbound_link(*args):
    tag, flag = _share_args(args, ("--qr", "--json", "--config"), "proxy outbounds")
    if flag == "--config":
        _config_export(only=tag)
        return
    entry = _outbound_share_entry(tag)
    if flag == "--json":
        print(_json_text(_proxy_export().portable_outbound(entry.get("outbound") or {})))
    elif not entry.get("url"):
        die(f"{tag} has no URL (it was not given as one) - use --json.")
    else:
        _emit(_s(entry["url"]), flag == "--qr")


def _subscription_link(*args):
    tag, flag = _share_args(args, ("--qr",), "proxy subs")
    url = (_read_root_json(_runtime_file("outbound-share.json"), "subscriptions").get("subscriptions") or {}).get(tag)
    if not url:
        die(f"Unknown subscription: {tag}")
    _emit(_s(url), flag == "--qr")


def _module(name):
    # Not PYTHONPATH: that would reach every command `apps run` starts.
    sys.path.append(env("PROXY_CTL_MODULES", os.path.dirname(os.path.abspath(__file__))))
    return importlib.import_module(name)


def _proxy_export():
    return _module("proxy_export")


def _config_export(*args, only=None):
    proxy_export = _proxy_export()

    for arg in args:
        if arg != "--raw":
            usage("proxy config [--raw]")
    cfg = _read_root_json(_runtime_file("config.json"), "running config")
    if "--raw" in args:
        sidecar = _runtime_file("xray-sidecar.json")
        print(_json_text({"sing-box": cfg, "xray": read_json(sidecar)} if os.path.isfile(sidecar) else cfg))
        return
    if only is not None and only not in _outbound_tags():
        die(f"Unknown outbound: {only}")
    try:
        cfg, warnings = proxy_export.portable(cfg, only)
    except ValueError as e:
        die(f"Cannot export: {e}")
    print(_json_text(cfg))
    sys.stdout.flush()
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)


def cmd_pin(tag="", *_):
    if not tag:
        if not (os.isatty(0) and os.isatty(1)):
            usage("proxy pin <tag>")
        _require_outbound_inventory()
        pinned = _s(_outbound_inventory().get("pinned") or "") or "(none)"
        status, tag = _run(
            ["fzf", "--prompt=pin> ", "--height=40%", "--reverse", f"--header=pinned: {pinned}"],
            capture=True,
            stdin="".join(f"{t}\n" for t in _outbound_tags() if t not in _outbound_disabled()),
        )
        tag = tag.strip("\n")
        # Dismissed.
        if status or not tag:
            return
    # The inventory too: the marker sits in a dir only root and the group can look into.
    if os.path.exists(_outbound_disabled_marker(tag)) or tag in _outbound_disabled():
        die(f"Outbound '{tag}' is disabled; enable it first: proxy-ctl proxy outbounds enable {tag}")
    status, escaped = _run(["systemd-escape", "--", tag], capture=True)
    if status:
        sys.exit(status)
    unit = "proxy-suite-outbound-pin@" + escaped.rstrip("\n")
    if systemctl("start", f"{unit}.service")[0]:
        die(f"Failed - see: proxy-ctl logs {unit}")
    print(f"Pinned: {tag}")


def cmd_unpin(*_):
    if systemctl("start", "proxy-suite-outbound-unpin.service")[0]:
        die("Failed - see: proxy-ctl logs proxy-suite-outbound-unpin")
    print("Unpinned: the configured selection picks again.")


# --- runtime outbounds and subscriptions --------------------------------------
#
# One entry per file in a spool directory the userControl group may write: <tag>.url,
# or for an outbound <tag>.json, one sing-box or XRay outbound as `link --json` prints
# it. The backend reads them at start, which the reload unit triggers.


def _runtime_dir(kind):
    if kind == "outbound":
        return env("RUNTIME_OUTBOUNDS_DIR", f"{state_dir()}/outbounds.d")
    return env("RUNTIME_SUBS_DIR", f"{state_dir()}/subscriptions.d")


def _runtime_hidden(kind):
    """The runtime entry dir when it cannot be listed, empty otherwise: the URLs in it make it root-only."""
    path = _runtime_dir(kind)
    return path if os.path.isdir(path) and not os.access(path, os.R_OK | os.X_OK) else ""


def _runtime_noun(kind):
    return "outbounds" if kind == "outbound" else "subs"


def _runtime_tags(kind):
    try:
        names = os.listdir(_runtime_dir(kind))
    except OSError:
        return []
    exts = (".url", ".json") if kind == "outbound" else (".url",)
    return sorted(os.path.splitext(n)[0] for n in names if n.endswith(exts))


def _runtime_path(kind, tag):
    """The file behind a runtime entry, or its .url spelling when there is none."""
    for ext in (".url", ".json") if kind == "outbound" else (".url",):
        path = os.path.join(_runtime_dir(kind), tag + ext)
        if os.path.exists(path):
            return path
    return os.path.join(_runtime_dir(kind), f"{tag}.url")


def _runtime_json_outbound(text):
    """One outbound object from `text`, the tag left to the entry's name."""
    try:
        ob = json.loads(text)
    except ValueError as e:
        die(f"Not a URL, and not valid JSON: {e}")
    if not isinstance(ob, dict) or not ("type" in ob or "protocol" in ob):
        die('JSON must be one outbound object: sing-box ("type") or XRay ("protocol").')
    ob.pop("tag", None)
    return json.dumps(ob, ensure_ascii=False)


def _check_runtime_tag(kind, tag):
    if tag in ("proxy", "direct", "block"):
        die(f"'{tag}' is reserved; pick another {kind} tag.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
        die(f"Invalid {kind} tag '{tag}': letters, digits, dot, dash and underscore only.")
    if tag in _runtime_tags(kind):
        die(f"A runtime {kind} named '{tag}' already exists; remove it first.")
    if kind == "outbound":
        if tag in _outbound_tags():
            die(f"An outbound named '{tag}' already exists.")
    elif tag in _sub_tags():
        die(f"A subscription named '{tag}' is declared in the configuration.")


RUNTIME_TAG_MAX = 32


def _runtime_source(kind, arg):
    """Whether an add argument is the entry itself rather than its tag."""
    return "://" in arg or (kind == "outbound" and (arg == "-" or arg.lstrip().startswith("{")))


def _vmess_name(url):
    """The name inside a vmess:// link, whose body is base64 JSON rather than a URL."""
    body = url.split("://", 1)[1].split("#", 1)[0].strip()
    try:
        decoded = json.loads(base64.b64decode(body + "=" * (-len(body) % 4)).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return ""
    return _s(decoded.get("ps") or decoded.get("add") or "") if isinstance(decoded, dict) else ""


def _host_label(host):
    """The name a host goes by: sub.provider.com -> provider; an address as it is."""
    if re.fullmatch(r"[0-9.]+|[0-9a-fA-F:]+", host):
        return host
    labels = [label for label in host.split(".") if label]
    return labels[-2] if len(labels) >= 2 else labels[0] if labels else ""


def _runtime_tag_for(kind, source):
    """A tag for an entry added without one: the name the link carries, else where it points.

    Never one already taken: -2, -3... after it.
    """
    text = source.strip()
    name = ""
    if text.startswith("{"):
        try:
            ob = json.loads(text)
        except ValueError:
            ob = None
        if isinstance(ob, dict):
            name = _s(ob.get("tag") or ob.get("type") or ob.get("protocol") or "")
    else:
        try:
            parts = urllib.parse.urlsplit(text)
            host = parts.hostname or ""
        except ValueError:
            parts, host = None, ""
        if parts:
            name = urllib.parse.unquote(parts.fragment)
            if not name and parts.scheme.lower() == "vmess":
                name = _vmess_name(text)
            if not name and host:
                label = _host_label(host)
                name = label if kind == "subscription" else f"{parts.scheme.lower()}-{label}"
    return _unique_runtime_tag(kind, name, "sub" if kind == "subscription" else "outbound")


def _unique_runtime_tag(kind, name, fallback):
    """`name` as a tag nothing else has taken: -2, -3... after it."""
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-._")[:RUNTIME_TAG_MAX].strip("-._") or fallback
    taken = {"proxy", "direct", "block", *_runtime_tags(kind), *(_outbound_tags() if kind == "outbound" else _sub_tags())}
    tag, n = base, 1
    while tag in taken:
        n += 1
        suffix = f"-{n}"
        tag = base[: RUNTIME_TAG_MAX - len(suffix)] + suffix
    return tag


def _runtime_entry_add(kind, *args, detour=""):
    what = "<url|json|-> [--detour <tag>]" if kind == "outbound" else "<url>"
    shape = f"proxy {_runtime_noun(kind)} add [tag] {what}"
    if len(args) == 1 and _runtime_source(kind, args[0]):
        tag, url = "", args[0]
    elif len(args) == 2 and _runtime_source(kind, args[0]):
        die(f"The tag goes first, the {'URL or JSON' if kind == 'outbound' else 'URL'} after it: proxy-ctl {shape}")
    elif len(args) == 2 and args[1]:
        tag, url = args
    else:
        usage(shape)
    if tag:
        _check_runtime_tag(kind, tag)
    # The start script checks the chain again, and leaves the outbound out if it breaks later.
    if detour and (detour == tag or detour not in _outbound_tags()):
        die(f"Cannot chain through '{detour}': not an outbound. See: proxy-ctl proxy outbounds")
    if kind == "outbound" and url == "-":
        url = sys.stdin.read()
    if not tag:
        tag = _runtime_tag_for(kind, url)
        _check_runtime_tag(kind, tag)
        print(f"Tag: {tag} (none given; pass one first to choose it)")
    ext = ".url"
    if kind == "outbound" and url.lstrip().startswith("{"):
        url, ext = _runtime_json_outbound(url), ".json"
    elif re.search(r"\s", url.strip()):
        die("A URL cannot contain whitespace.")
    else:
        url = url.strip()
    path = os.path.join(_runtime_dir(kind), tag + ext)
    old = os.umask(0o027)
    try:
        # The hop first: the entry is what the start script looks for.
        hop = os.path.join(_runtime_dir(kind), f"{tag}.detour")
        if detour:
            with open(hop, "w", encoding="utf-8") as f:
                f.write(f"{detour}\n")
        elif os.path.exists(hop):
            os.unlink(hop)  # left from an earlier entry of this name: it would chain this one too
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"{url}\n")
    except OSError:
        denied(path, "write")
    finally:
        os.umask(old)
    _runtime_reload()
    _runtime_entry_verify(kind, tag)


def cmd_outbound_chain(tag="", hop="", new_tag="", *_):
    """A runtime copy of an existing outbound that dials through another one.

    A detour belongs to the outbound that carries it, so chaining two that already exist
    means a third: the original keeps dialing the way it did.
    """
    if not tag or not hop:
        usage("proxy outbounds chain <tag> <through-tag> [new tag]")
    _require_outbound_inventory()
    tags = _outbound_tags()
    if tag not in tags:
        die(f"Unknown outbound: {tag}")
    if hop not in tags:
        die(f"Cannot chain through '{hop}': not an outbound. See: proxy-ctl proxy outbounds")
    if tag == hop:
        die(f"'{tag}' cannot chain through itself; name another outbound as the hop.")
    entry = _outbound_share_entry(tag)
    source = _s(entry.get("url") or "")
    if not source:
        ob = entry.get("outbound") or {}
        if not ob:
            die(f"Nothing to copy from '{tag}': the backend recorded neither a URL nor JSON for it.")
        source = _json_text(_proxy_export().portable_outbound(ob))
    if new_tag:
        _check_runtime_tag("outbound", new_tag)
    else:
        new_tag = _unique_runtime_tag("outbound", f"{tag}-via-{hop}", "chain")
        print(f"Tag: {new_tag} (none given; pass one after the hop to choose it)")
    if own_hop := _s((_outbound_inventory().get("detours") or {}).get(tag) or ""):
        print(f"Note: '{tag}' chains through {own_hop}; the copy chains through {hop} instead.")
    _runtime_entry_add("outbound", new_tag, source, detour=hop)


def _runtime_entry_rm(kind, tag="", *_):
    if not tag:
        usage(f"proxy {_runtime_noun(kind)} rm <tag>")
    path = _runtime_path(kind, tag)
    if not os.path.exists(path):
        # The dir may be root-only: an entry that is there looks absent from outside it.
        if _runtime_hidden(kind):
            die(f"Cannot see the entry for '{tag}' in {_runtime_dir(kind)} - {ask_group()}")
        die(f"No runtime {kind} named '{tag}'. Ones declared in the NixOS configuration are removed there.")
    try:
        os.unlink(path)
        # Its hop, and a disable left from it: a new entry of this name would inherit them.
        for extra in (".detour", ".disabled") if kind == "outbound" else ():
            if os.path.exists(os.path.join(_runtime_dir(kind), tag + extra)):
                os.unlink(os.path.join(_runtime_dir(kind), tag + extra))
    except FileNotFoundError:
        pass
    except OSError:
        denied(path, "remove")
    _runtime_reload()
    print(f"Removed {kind}: {tag}")


def _runtime_reload():
    if systemctl("start", "proxy-suite-outbound-reload.service")[0]:
        die("Saved, but applying it failed - see: proxy-ctl logs proxy-suite-outbound-reload")


# --- disabled outbounds -------------------------------------------------------
#
# <tag>.disabled in the runtime outbound dir, for declared outbounds as much as runtime
# ones. The outbound stays in the config, so rules and chains naming it still reach
# it; selection, autoProxy's probes and pins leave it alone, and autoProxy forgets
# the routes it learned through it.


def _outbound_disabled_marker(tag):
    return os.path.join(_runtime_dir("outbound"), f"{tag}.disabled")


def cmd_outbound_disable(tag="", *_):
    if not tag:
        usage("proxy outbounds disable <tag>")
    _require_outbound_inventory()
    inventory = _outbound_inventory()
    if tag not in _outbound_tags():
        die(f"Unknown outbound: {tag}")
    marker = _outbound_disabled_marker(tag)
    if os.path.exists(marker) and tag in _outbound_disabled():
        print(f"Already disabled: {tag}")
        return
    pinned = _s(inventory.get("pinned") or "")
    excluded = set(inventory.get("excluded") or [])
    # With none left to pick the proxy would not start, pinned or not: an unpin falls back to selection.
    if [t for t in _outbound_tags() if t not in excluded] == [tag]:
        die(f"'{tag}' is the only outbound selection can pick; enable or add another first.")
    old = os.umask(0o027)
    try:
        with open(marker, "w", encoding="utf-8"):
            pass
    except OSError:
        denied(marker, "write")
    finally:
        os.umask(old)
    # The reload drops a pin on it too.
    _runtime_reload()
    if tag in _outbound_disabled():
        print(f"Disabled: {tag} - never picked, pinned or probed; rules and chains naming it still use it.")
    else:
        sys.stdout.flush()
        print(f"Saved, but the running proxy does not list '{tag}' as disabled yet. Check: proxy-ctl logs", file=sys.stderr)


def cmd_outbound_enable(tag="", *_):
    if not tag:
        usage("proxy outbounds enable <tag>")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
        die(f"Not disabled: {tag}")
    marker = _outbound_disabled_marker(tag)
    if not os.path.exists(marker):
        if tag in _outbound_disabled():
            die(f"Cannot see the marker for '{tag}' in {_runtime_dir('outbound')} - {ask_group()}")
        die(f"Not disabled: {tag}")
    try:
        os.unlink(marker)
    except FileNotFoundError:
        pass
    except OSError:
        denied(marker, "remove")
    _runtime_reload()
    print(f"Enabled: {tag} - selection and autoProxy may use it again.")


def _subscription_cache(tag):
    return os.path.join(env("SUB_CACHE_DIR", f"{state_dir()}/subscriptions"), f"{tag}.json")


def _runtime_entry_verify(kind, tag):
    """Only the backend parses the entry, so confirm it actually came up."""
    if kind == "outbound":
        if tag in _outbound_tags():
            print(f"Added outbound: {tag}")
            return
    elif os.path.isfile(_subscription_cache(tag)):
        print(f"Added subscription: {tag} ({_subscription_proxy_count_text(_subscription_cache(tag))} proxies)")
        return
    sys.stdout.flush()
    print(f"Saved {kind} '{tag}', but it did not come up. Check: proxy-ctl logs", file=sys.stderr)
    print(f"Remove it again with: proxy-ctl proxy {_runtime_noun(kind)} rm {tag}", file=sys.stderr)
    sys.exit(1)


def cmd_route_mode(action="status", *_):
    if not svc_exists("proxy-suite-socks"):
        die("proxy is not enabled in this configuration.")
    if action == "status":
        print(_route_mode_label(_route_mode_current()))
    elif action in ("default", *ROUTE_MODES):
        must("start", f"proxy-suite-route-mode@{action}.service")
        print(f"Switched to: {_route_mode_label(action)}")
    else:
        usage("proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]")


def _subscription_proxy_count(path):
    cache = read_json(path)
    if isinstance(cache, list):
        return len(cache)
    if isinstance(cache, dict) and isinstance(cache.get("singBox"), list) and isinstance(cache.get("xray"), list):
        return len(cache["singBox"]) + len(cache["xray"])
    raise ValueError("unsupported subscription cache shape")


def _subscription_proxy_count_text(path):
    try:
        return str(_subscription_proxy_count(path))
    except (OSError, ValueError):
        return "?"


def _subscription_row(tag, source):
    cache = _subscription_cache(tag)
    if os.path.isfile(cache):
        try:
            age = datetime.datetime.fromtimestamp(os.path.getmtime(cache)).strftime("%Y-%m-%d %H:%M:%S")
        except OSError:
            age = "unknown"
        count = _subscription_proxy_count_text(cache)
    else:
        age = "(no cache)"
        count = "-"
    print(f"  {tag:<30} {age:<22} {count:<9} {source}")


def _subscription_list():
    static = _sub_tags()
    runtime = _runtime_tags("subscription")
    hidden = _runtime_hidden("subscription")
    if not static and not runtime:
        if hidden:
            denied(hidden)
        print("No subscriptions configured.")
        return
    print(f"  {'TAG':<30} {'LAST UPDATED':<22} {'PROXIES':<9} SOURCE")
    for tag in static:
        _subscription_row(tag, "static")
    for tag in runtime:
        _subscription_row(tag, "runtime")
    if hidden:
        print(f"  (runtime subscriptions are not listed: cannot read {hidden} - {ask_group()})")
    next_run = _timer_next_run(f"{SUBSCRIPTION_UPDATE}.timer")
    if next_run:
        print()
        print(f"Next update: {datetime.datetime.fromtimestamp(next_run):%H:%M:%S}, {_in_time(next_run)}")


def cmd_subscription(verb="list", *args):
    if verb == "list":
        _subscription_list()
    elif verb == "add":
        _runtime_entry_add("subscription", *args)
    elif verb in ("rm", "remove", "del"):
        _runtime_entry_rm("subscription", *args)
    elif verb == "link":
        _subscription_link(*args)
    elif verb == "update":
        if not svc_exists("proxy-suite-subscription-update"):
            die("The proxy is not enabled in this configuration.")
        must("start", "proxy-suite-subscription-update")
        print("Subscription update triggered. Follow with: proxy-ctl logs proxy-suite-subscription-update")
    else:
        usage("proxy subs [list|update|add [tag] <url>|rm <tag>|link <tag>]")


# --- proxy auto: reachability probe -------------------------------------------
#
# Fetches a URL through one exit after another (direct first) and finds one
# whose origin answers. The exits are the per-exit loopback listeners
# proxy-suite-socks opens for autoProxy (PROBE_EXITS_FILE); without them, only
# this host and the local proxy. The apex decides when any exit gets content
# from it; robots.txt breaks ties when the apex is refused everywhere.
#
# A fetch result is "<curl-exit>|<appconnect-seconds>|<http-status>|<bytes>|<block-page>|<location>".
# block-page names the vendor page a refusal came with (PROBE_BLOCK_PAGES): the
# site's security layer turning the address away, not its origin answering.

PROBE_BLOCK_REDIRECT = re.compile(r"unavailable|not-available|blocked|geo|region|restricted", re.I)
PROBE_WRITE_OUT = "%{exitcode}|%{time_appconnect}|%{http_code}|%{size_download}|%{redirect_url}"
# name -> (kind, pattern over a refusal's headers and first 8 KiB of body). "address":
# the address itself was refused, so an exit that gets past it reaches the site.
# "geo": its country was, which is an ordinary refusal.
PROBE_BLOCK_PAGES = {
    name: (kind, re.compile(pattern))
    for name, kind, pattern in [
        # CloudFront's AWS WAF page (game-version.sekai.colorfulpalette.org).
        ("aws-waf", "address", r"(?ims)^server: cloudfront\b.*Request blocked\."),
        ("cloudfront-geo", "geo", r"(?i)configured to block access from your country"),
        ("cloudflare", "address", r'(?im)^cf-mitigated: challenge|cf-error-code">10(06|07|08|20)<|error code: 10(06|07|08|20)\b'),
        ("cloudflare-geo", "geo", r'(?i)cf-error-code">1009<|error code: 1009\b'),
        ("akamai", "address", r"(?ims)^server: AkamaiGHost\b.*Access Denied"),
        ("imperva", "address", r"(?i)Incapsula incident ID"),
        ("datadome", "address", r"(?im)^x-datadome:"),
    ]
}


def _probe_paths():
    fallback = env("PROBE_PATH_FALLBACK", "/robots.txt")
    return [env("PROBE_PATH", "/"), *([fallback] if fallback else [])]


def _probe_exits_file():
    return env("PROBE_EXITS_FILE", f"{runtime_dir()}/proxy-suite-socks/probe-exits.json")


def _probe_site(url):
    """Last two labels: only used to keep redirect following on one site."""
    host = url.split("://", 1)[-1]
    host = re.split(r"[/:?#]", host, maxsplit=1)[0]
    return ".".join(host.split(".")[-2:])


def run_curl(argv):
    return _run(argv, capture=True, quiet=True)


def _probe_fetch(domain, path, *selector):
    """The first hop that is not a same-site redirect.

    A block can sit at the end of a chain (spotify.com -> www -> open ->
    accounts -> why-not-available). `selector` picks the egress.
    """
    url = f"https://{domain}{path}"
    site = _probe_site(url)
    curl = env("PROBE_CURL")
    # An impersonating curl must keep its browser's own User-Agent.
    ua = [] if curl else ["-A", env("PROBE_UA", "Mozilla/5.0 (X11; Linux x86_64) proxy-suite-probe")]
    result = ""
    with tempfile.TemporaryDirectory(prefix="proxy-ctl-probe-") as tmp:
        for hop in range(6):
            head, body = os.path.join(tmp, f"{hop}.head"), os.path.join(tmp, f"{hop}.body")
            status, out = run_curl(
                [
                    curl or "curl",
                    "-sS",
                    "-D",
                    head,
                    "-o",
                    body,
                    *ua,
                    "--connect-timeout",
                    env("PROBE_CONNECT_TIMEOUT", "8"),
                    "--max-time",
                    env("PROBE_MAX_TIME", "15"),
                    "-w",
                    PROBE_WRITE_OUT,
                    *selector,
                    url,
                ]
            )
            # Not a dead site: curl itself did not start.
            if not out and status >= 126:
                die(f"Cannot run {curl or 'curl'} (exit {status}).")
            fields = (out or "99|0|000|0|").split("|", 4)
            fields += [""] * (5 - len(fields))
            result = "|".join([*fields[:4], _probe_block_page(fields[2], head, body), fields[4]])
            if not re.fullmatch(r"3..", _probe_field(result, 3)) or _probe_redirect_is_block(result):
                break
            url = _probe_field(result, 6)
            if not url or _probe_site(url) != site:
                break
    return result


def _probe_block_page(code, head, body):
    """The PROBE_BLOCK_PAGES name a refusal's page matches; "" for none."""
    if not re.fullmatch(r"[45]..", code):
        return ""
    text = ""
    for path, limit in ((head, -1), (body, 8192)):
        try:
            with open(path, "rb") as f:
                text += f.read(limit).decode("latin-1") + "\n\n"
        except OSError:
            pass
    return next((name for name, (_, pattern) in PROBE_BLOCK_PAGES.items() if pattern.search(text)), "")


def _probe_field(result, n):
    fields = result.split("|", 5)
    return fields[n - 1] if n <= len(fields) else ""


def _probe_tls_ok(result):
    """curl reports appconnect 0 when TLS never finished."""
    return _probe_field(result, 2) not in ("", "0", "0.000000")


def _probe_redirect_is_block(result):
    return bool(PROBE_BLOCK_REDIRECT.search(_probe_field(result, 6)))


def _probe_http_ok(result):
    code = _probe_field(result, 3)
    if re.fullmatch(r"2..", code) or code in ("401", "404"):
        return True
    if re.fullmatch(r"3..", code):
        return not _probe_redirect_is_block(result)
    return False


def _probe_exit_verdict(result):
    """dead: failed before the origin spoke (the censor's doing, zapret's job).

    wall: the site's security layer refused this address (an exit past it helps).
    blocked: the origin answered and refused (a proxy hop can fix it).
    """
    if not _probe_tls_ok(result) or _probe_field(result, 3) == "000":
        return "dead"
    if _probe_http_ok(result):
        return "ok"
    return "wall" if PROBE_BLOCK_PAGES.get(_probe_field(result, 5), ("",))[0] == "address" else "blocked"


def _probe_reaches(direct_judgement, judgement):
    """Content, or - where direct hit a wall - any answer from the origin past it.

    ponytail: an origin refusing behind the wall (its own geo-block) counts as
    reached too; compare with robots.txt if that misroutes a site.
    """
    return judgement == "ok" or (direct_judgement == "wall" and judgement == "blocked")


def _probe_verdict(direct, via):
    d = _probe_exit_verdict(direct)
    v = _probe_exit_verdict(via)
    if d == "ok":
        return "ok"
    if _probe_reaches(d, v):
        return "censor" if d == "dead" else "destination"
    return "unreachable" if d == "dead" else "both-fail"


def _probe_verdict_text(verdict, exit_tag):
    return {
        "ok": "reachable directly - nothing to do",
        "destination": f"destination-side block - route via {exit_tag or 'proxy'}",
        "censor": "censor-side block - zapret2 territory, do not proxy",
        "both-fail": "fails through every egress - not an egress problem",
        "unreachable": "no egress reaches it at all",
    }.get(verdict, "inconclusive")


def _probe_describe(result):
    if not _probe_tls_ok(result):
        return f"no TLS (curl exit {_probe_field(result, 1)})"
    status = _probe_field(result, 3)
    if status == "000":
        return f"TLS {_probe_field(result, 2)}s, then no response"
    text = f"TLS {_probe_field(result, 2)}s, {status}, {_probe_field(result, 4)} bytes"
    if _probe_field(result, 5):
        text += f", {_probe_field(result, 5)} page"
    location = _probe_field(result, 6)
    return f"{text} -> {location}" if location else text


def _probe_exits():
    """(tag, proxy url) per exit, in order; an empty url means this host."""
    path = _probe_exits_file()
    if readable(path):
        return [(_s(e["tag"]), f"http://127.0.0.1:{_s(e['port'])}") for e in read_json(path)]
    return [("direct", ""), ("proxy", env("LOCAL_PROXY_URL", "http://127.0.0.1:1080"))]


def _probe_fetch_exit(domain, path, proxy_url):
    if proxy_url:
        return _probe_fetch(domain, path, "--proxy", proxy_url)
    return _probe_fetch(domain, path, "--noproxy", "*")


def _walk(**fields):
    return {"rows": [], "verdict": "", "exit": "", "path": "", "direct": "", "via": "", **fields}


def _probe_walk(domain, exits, paths, keep_going):
    """Walks exits (direct first) and stops at the first that reaches it: gets
    content, or gets past a wall direct hit (_probe_reaches).

    keep_going still tries the rest, keeping that first one. rows are
    (tag, path, result, judgement) per request.
    """
    w = _walk()
    (direct_tag, direct_url), others = exits[0], exits[1:]
    first_direct = ""
    for path in paths:
        direct = _probe_fetch_exit(domain, path, direct_url)
        dj = _probe_exit_verdict(direct)
        w["rows"].append((direct_tag, path, direct, dj))
        first_direct = first_direct or direct
        if dj == "ok" and not w["verdict"]:
            w.update(verdict="ok", path=path, direct=direct)
            if not keep_going:
                return w
        for tag, url in others:
            result = _probe_fetch_exit(domain, path, url)
            judgement = _probe_exit_verdict(result)
            w["rows"].append((tag, path, result, judgement))
            if _probe_reaches(dj, judgement) and not w["verdict"]:
                w.update(verdict=_probe_verdict(direct, result), exit=tag, path=path, direct=direct, via=result)
                if not keep_going:
                    return w
    if not w["verdict"]:
        dead = _probe_exit_verdict(first_direct) == "dead"
        w.update(path=paths[0], direct=first_direct, verdict="unreachable" if dead else "both-fail")
    return w


def _probe_stand_in(domain, exits, paths):
    """--via: can exits[1] carry what direct reaches?

    It must get content on some path and fail on none where direct succeeds.
    Verdict "ok" or "blocked".
    """
    w = _walk(verdict="ok", exit=exits[1][0], path=paths[0])
    got = False
    for path in paths:
        direct = _probe_fetch_exit(domain, path, exits[0][1])
        via = _probe_fetch_exit(domain, path, exits[1][1])
        dj = _probe_exit_verdict(direct)
        vj = _probe_exit_verdict(via)
        w["rows"] += [(exits[0][0], path, direct, dj), (exits[1][0], path, via, vj)]
        if path == paths[0]:
            w.update(direct=direct, via=via)
        got = got or vj == "ok"
        if dj == "ok" and vj != "ok":
            w["verdict"] = "blocked"
    if not got:
        w["verdict"] = "blocked"
    return w


def cmd_proxy_probe(*args):
    json_out = keep_going = False
    domain = via = ""
    wanted = None
    args = list(args)
    while args:
        arg = args.pop(0)
        if arg == "--json":
            json_out = True
        elif arg == "--keep-going":
            keep_going = True
        elif arg in ("--exits", "--via"):
            if not args:
                die("--exits needs a comma-separated list of exit tags" if arg == "--exits" else "--via needs an exit tag")
            value = args.pop(0)
            wanted = value.split(",")
            if arg == "--via":
                via = value
        elif arg.startswith("-"):
            die(f"Unknown option: {arg}")
        else:
            domain = arg

    if not domain:
        usage("proxy auto probe <domain>[/path] [--json] [--keep-going] [--exits a,b | --via tag]")
    domain = domain.split("://", 1)[-1]
    paths = _probe_paths()
    if "/" in domain:
        domain, path = domain.split("/", 1)
        paths = [f"/{path}"]

    if not svc_active("proxy-suite-socks"):
        die("The local proxy (proxy-suite-socks) is not running; a probe needs its exits.")

    # direct first, then every exit in order, or the ones asked for in that order.
    rows = _probe_exits()
    exits = [row for row in rows if row[0] == "direct"]
    for tag in [row[0] for row in rows] if wanted is None else wanted:
        if tag != "direct":
            exits += [row for row in rows if row[0] == tag][:1]
    if not exits or exits[0][0] != "direct":
        die(f"No direct exit to probe from ({_probe_exits_file()}).")
    if via and len(exits) != 2:
        die(f"No exit named {via} other than direct ({_probe_exits_file()}).")

    w = _probe_stand_in(domain, exits, paths) if via else _probe_walk(domain, exits, paths, keep_going)

    if json_out:
        out = {
            "domain": domain,
            "url": f"https://{domain}{w['path']}",
            "path": w["path"],
            "verdict": w["verdict"],
            "exit": w["exit"] or None,
            "direct": w["direct"],
            "proxy": w["via"],
            "exits": [dict(zip(("tag", "path", "result", "judgement"), row), block=_probe_field(row[2], 5)) for row in w["rows"]],
        }
        print(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
        return

    print(f"  domain     {domain}")
    print(f"  probe      https://{domain}{w['path']}")
    print("  exits")
    for tag, path, result, judgement in w["rows"]:
        chosen = "  <- chosen" if tag == w["exit"] and path == w["path"] else ""
        print(f"    {tag:<18} {path:<12} {_probe_describe(result):<44} {judgement}{chosen}")
    if via:
        if w["verdict"] == "ok":
            print(f"  verdict    {via} answers it as well as direct does - it can carry it")
        else:
            print(f"  verdict    {via} answers it worse than direct does")
        return
    print(f"  verdict    {_probe_verdict_text(w['verdict'], w['exit'])}")
    if w["verdict"] == "destination":
        print(f'             pin: proxy.routing.rules = [ {{ outbound = "{w["exit"]}"; domains = [ "{domain}" ]; }} ]')
    elif w["verdict"] == "censor":
        print(f"             try: proxy-ctl zapret auto add {domain}")


# --- bad exits -----------------------------------------------------------------
#
# The autoProxy prober strikes an exit when a destination refuses it while
# another egress gets content, or crawls on it (autoproxy-strike.jq). An exit
# struck by several destinations within a TTL is bad, and probed last.


def _backend_tags():
    """User outbound tag -> the backend's tag, which probe exits and their reputation are keyed by."""
    return read_json_or(_runtime_file("outbound-test.json"), {}).get("outbounds") or {}


def _backend_tag(tag, backend=None):
    return _s((_backend_tags() if backend is None else backend).get(tag) or tag)


def _reputation_by_tag():
    """User tag -> "bad" or "ok" once the prober has judged its exit; {} before it has."""
    if env("AUTOPROXY_ENABLED") != "1":
        return {}
    exits = _autoproxy_state(_autoproxy_dir()).get("exits") or {}
    backend = _backend_tags()
    out = {}
    for tag in _outbound_tags():
        e = exits.get(_backend_tag(tag, backend))
        if isinstance(e, dict) and "strikes" in e:
            out[tag] = "bad" if e.get("bad") is True else "ok"
    return out


def _autoproxy_dir():
    return env("AUTOPROXY_STATE_DIR", f"{state_dir()}/autoproxy")


def _require_autoproxy():
    require_enabled("AUTOPROXY_ENABLED", "proxy.autoProxy")


def _autoproxy_unreadable(path):
    """The path a refused read stops at, empty when the state is readable or simply not there yet.

    The state dir is 0751, opened to 0771 for the autoProxy scope's group, and
    state.json inside it stays 0640: a member gets past the directory and a
    stranger does not, so both are checked.
    """
    if not os.path.isdir(path):
        return ""
    if not os.access(path, os.R_OK | os.X_OK):
        return path
    state = os.path.join(path, "state.json")
    return state if os.path.exists(state) and not readable(state) else ""


def _require_autoproxy_readable(path):
    """Root-only without userControl: say so rather than show an empty queue."""
    if not os.path.isdir(path):
        die("No autoProxy state yet - the prober has not completed a run.")
    if blocked := _autoproxy_unreadable(path):
        denied(blocked)


def _autoproxy_state(path):
    return read_json_or(os.path.join(path, "state.json"), {})


def cmd_proxy_auto(verb="list", *args):
    if verb in ("list", "learned"):
        cmd_proxy_learned()
    elif verb == "probe":
        cmd_proxy_probe(*args)
    elif verb == "learn":
        cmd_proxy_learn(*args)
    elif verb == "forget":
        cmd_proxy_forget(*args)
    elif verb == "relearn":
        cmd_proxy_relearn(*args)
    elif verb == "clear":
        cmd_proxy_clear(*args)
    elif verb == "queue":
        cmd_proxy_queue(*args)
    else:
        usage("proxy auto [list|probe|learn|forget|relearn|clear|queue]")


def _autoproxy_next_run():
    return _timer_next_run("proxy-suite-autoproxy.timer")


def _timer_next_run(timer):
    """Epoch seconds of the timer's next run, None when none is armed.

    The timers are relative, so only list-timers knows it.
    """
    _, out = systemctl("list-timers", "-o", "json", timer, capture=True, quiet=True)
    try:
        next_run = json.loads(out)[0].get("next")
    except (ValueError, IndexError, AttributeError, TypeError, KeyError):
        return None
    return int(next_run) // 1000000 if isinstance(next_run, (int, float)) and next_run else None


def _in_time(epoch):
    left = epoch - int(time.time())
    return "under a minute" if left < 60 else f"in {left // 60} min"


def _ago(at, now):
    minutes = (now - (at or 0)) // 60
    return f"{minutes}m" if minutes < 120 else f"{minutes // 60}h"


def cmd_proxy_queue(top="20", *_):
    _require_autoproxy()
    if not re.fullmatch(r"[0-9]+", top):
        usage("proxy auto queue [count]")
    top = int(top)
    path = _autoproxy_dir()
    _require_autoproxy_readable(path)

    print("Requested with proxy-ctl proxy auto learn:")
    requested = ""
    for name in ("requests", "requests.taking"):
        try:
            requested += read_text(os.path.join(path, name))
        except OSError:
            pass
    for line in lines(requested) or ["(none)"]:
        print(f"  {line}")

    backlog = _autoproxy_state(path).get("backlog") or {}
    print()
    print(f"Waiting to be probed, most-dialled first ({len(backlog)}):")
    if backlog:
        entries = sorted(backlog.items(), key=lambda kv: -((kv[1] or {}).get("hits") or 0))
        for host, entry in entries[:top]:
            print(f"  {_s((entry or {}).get('hits'))}\t{host}")
        if len(backlog) > top:
            print(f"  ... and {len(backlog) - top} more")
    else:
        print("  (none)")

    next_run = _autoproxy_next_run()
    if next_run:
        print()
        print(f"Next run: {datetime.datetime.fromtimestamp(next_run):%H:%M:%S}, {_in_time(next_run)}")
    elif systemctl("show", "-p", "ActiveState", "--value", "proxy-suite-autoproxy.service", capture=True, quiet=True)[1].strip() == "activating":
        print()
        print("Next run: one is running now")


def cmd_proxy_learned(*_):
    _require_autoproxy()
    path = _autoproxy_dir()
    _require_autoproxy_readable(path)
    state = _autoproxy_state(path)
    domains = state.get("domains") or {}

    if not domains:
        print("Nothing routed yet.")
    else:
        print("Routed through an exit:")
        now = int(time.time())
        for domain, d in sorted(domains.items()):
            host = _s(d.get("host"))
            if d.get("verdict") == "slow":
                host += ", which crawled directly"
            print(f"  {domain:<28} -> {_s(d.get('exit')):<12} (learned from {host}, checked {_ago(d.get('at'), now)} ago)")

    counts = {}
    for h in (state.get("hosts") or {}).values():
        verdict = _s(h.get("verdict"))
        counts[verdict] = counts.get(verdict, 0) + 1
    judged = "  ".join(f"{v}={n}" for v, n in sorted(counts.items()))
    print()
    print(f"Hosts judged: {judged or 'none yet'}")

    bad = {t: e.get("badBy") or [] for t, e in (state.get("exits") or {}).items() if isinstance(e, dict) and e.get("bad") is True}
    if bad:
        print()
        print("Probed last, refused or crawled by several destinations:")
        for tag, by in sorted(bad.items()):
            print(f"  {_s(tag):<28} {', '.join(_s(b) for b in by)}")


def _autoproxy_queue(name, line):
    """Appends a line for the prober's own unit, which takes it under the same lock as a timer run."""
    path = os.path.join(_autoproxy_dir(), name)
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{line}\n")
    except OSError:
        denied(path, "write")


def _autoproxy_run(what):
    if systemctl("start", "proxy-suite-autoproxy-learn.service", quiet=True)[0]:
        sys.stdout.flush()
        print(f"The probe run failed. {what} is still queued and will be tried again at the next run.", file=sys.stderr)
        die(f"Details: {journal_hint('proxy-suite-autoproxy-learn', 20)}")


def _autoproxy_report(host):
    h = (_autoproxy_state(_autoproxy_dir()).get("hosts") or {}).get(host)
    if h is None:
        print(f"No verdict recorded; see: {journal_hint('proxy-suite-autoproxy-learn')}")
    elif h.get("exit"):
        print(f"{_s(h.get('domain'))}: {_s(h.get('verdict'))} - routed via {_s(h['exit'])} from now on, no restart needed")
    else:
        print(f"{host}: {_s(h.get('verdict'))} - nothing to route")
    return h


def cmd_proxy_learn(host="", *_):
    _require_autoproxy()
    if not HOSTNAME.fullmatch(host):
        usage("proxy auto learn <domain>")
    _autoproxy_queue("requests", host)
    print(f"Probing {host} through each exit...")
    _autoproxy_run(host)
    _autoproxy_report(host)


def _autoproxy_learned(name, verb):
    """(registrable domain, its route or None) for a domain or one of its hosts."""
    _require_autoproxy()
    if not HOSTNAME.fullmatch(name):
        usage(f"proxy auto {verb} <domain>")
    path = _autoproxy_dir()
    _require_autoproxy_readable(path)
    state = _autoproxy_state(path)
    domains = state.get("domains") or {}
    if name in domains:
        return name, domains[name]
    judged = (state.get("hosts") or {}).get(name) or (state.get("backlog") or {}).get(name) or {}
    domain = _s(judged.get("domain") or "")
    if domain:
        return domain, domains.get(domain)
    # A host under a routed domain: the route covers it.
    for d in domains:
        if name.endswith(f".{d}"):
            return d, domains[d]
    return name, None


def cmd_proxy_forget(name="", *_):
    domain, route = _autoproxy_learned(name, "forget")
    _autoproxy_queue("edits", f"forget {domain}")
    _autoproxy_run(f"Forgetting {domain}")
    via = f" (was via {_s(route.get('exit'))})" if route else ""
    print(f"Forgot {domain}{via}: direct until it is dialled and learned again.")


def cmd_proxy_relearn(name="", *_):
    domain, route = _autoproxy_learned(name, "relearn")
    host = _s((route or {}).get("host") or "") or name
    was = _s((route or {}).get("exit") or "")
    _autoproxy_queue("edits", f"forget {domain}")
    _autoproxy_queue("requests", host)
    print(f"Forgot {domain}{f' (was via {was})' if was else ''}; probing {host} through each exit...")
    _autoproxy_run(host)
    h = _autoproxy_report(host)
    if was and h and _s(h.get("exit") or "") == was:
        print(f"Same exit as before. To keep {domain} off it: proxy-ctl proxy outbounds disable {was}")


def cmd_proxy_clear(*_):
    _require_autoproxy()
    _autoproxy_queue("edits", "clear")
    _autoproxy_run("Forgetting everything")
    print("Forgot every learned route and verdict: all direct until dialled and learned again.")


# --- zapret -------------------------------------------------------------------


def cmd_zapret(*args):
    if args[:1] == ("auto",):
        cmd_zapret_auto(*args[1:])
    elif args[:1] == ("cutoff",):
        cmd_zapret_cutoff(*args[1:])
    else:
        _toggle("proxy-suite-zapret", "zapret", *args)


def _zapret_state_dir():
    return env("ZAPRET_STATE_DIR", f"{state_dir()}/zapret2")


def _zapret_auto_file(name):
    return os.path.join(_zapret_state_dir(), name)


def _replace_lines(path, keep, extra=()):
    """Rewrites path with the lines keep() accepts, plus extra.

    Via a temp file in the same directory, world-readable: unprivileged
    proxy-ctl reads these lists too.
    """
    try:
        old = lines(read_text(path)) if os.path.exists(path) else []
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=os.path.dirname(path) or ".")
    except OSError:
        denied(path, "write")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(f"{line}\n" for line in [*filter(keep, old), *extra])
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        denied(path, "replace")


def _zapret_auto_edit(path, domain, action):
    """nfqws2 re-reads a list when its mtime changes; no reload needed."""
    if action == "drop" and not os.path.exists(path):
        return
    _replace_lines(path, lambda line: line != domain, [domain] if action == "add" else [])


def _zapret_strategy_drop(domain):
    """Forgets strategies remembered for domain or any parent of it.

    They are keyed by the domain circular rotates on (usually the apex);
    z2k-state-persist.lua applies external deletions live.
    """
    path = _zapret_auto_file("circular/state.tsv")
    if not (os.path.isfile(path) and os.path.getsize(path) > 0):
        return

    def keep(line):
        fields = line.split("\t")
        key = fields[1] if len(fields) > 1 else ""
        return line.startswith("#") or (key != domain and not domain.endswith(f".{key}"))

    _replace_lines(path, keep)


def _truncate(path):
    _replace_lines(path, lambda _: False)


def cmd_zapret_auto(verb="list", domain="", *_):
    if env("ZAPRET_AUTO_ENABLED") != "1":
        die('Learned hostlists need zapret.engine = "zapret2".')
    auto = _zapret_auto_file("zapret-hosts-auto.txt")
    user = _zapret_auto_file("zapret-hosts-user.txt")
    exclude = _zapret_auto_file("zapret-hosts-user-exclude.txt")

    if verb in ("add", "forget", "exclude", "unpin", "include") and not HOSTNAME.fullmatch(domain):
        usage(f"zapret auto {verb} <domain>")
    if verb == "list":
        if os.path.isfile(auto) and os.path.getsize(auto) > 0:
            sys.stdout.write(read_text(auto))
        else:
            print("No hostnames learned yet.")
    elif verb == "add":
        _zapret_auto_edit(user, domain, "add")
        print(f"Pinned {domain} (always bypassed).")
    elif verb == "forget":
        _zapret_auto_edit(auto, domain, "drop")
        _zapret_strategy_drop(domain)
        print(f"Forgot {domain}. It is learned again if it keeps failing; 'exclude' prevents that.")
    elif verb == "exclude":
        _zapret_auto_edit(auto, domain, "drop")
        _zapret_strategy_drop(domain)
        _zapret_auto_edit(exclude, domain, "add")
        print(f"Excluded {domain}. It is no longer touched or learned.")
    elif verb == "unpin":
        _zapret_auto_edit(user, domain, "drop")
        print(f"Unpinned {domain}. It is bypassed again only if learned.")
    elif verb == "include":
        _zapret_auto_edit(exclude, domain, "drop")
        print(f"Included {domain}. It can be learned again.")
    elif verb == "clear":
        _truncate(auto)
        state = _zapret_auto_file("circular/state.tsv")
        if os.path.exists(state):
            _truncate(state)
        print("Cleared learned hosts and remembered strategies.")
    else:
        usage("zapret auto [list|add|forget|exclude|unpin|include|clear]")


# --- zapret cutoff ------------------------------------------------------------
#
# The 16 KB cutoff probe's verdict: which networks this line cuts after the
# handshake, and the whitelisted name that gets each through. Networks without a
# name are what the proxy fallback routes.


def _tsv(path):
    try:
        return [line.split("\t") for line in lines(read_text(path))]
    except OSError:
        return []


def cmd_zapret_cutoff(verb="status", *_):
    path = os.path.join(_zapret_state_dir(), "cutoff")
    if env("ZAPRET_CUTOFF_ENABLED") != "1":
        die('The cutoff probe needs zapret.engine = "zapret2" with zapret2.cutoff.enable.')
    if verb == "probe":
        try:
            open(os.path.join(path, "force"), "w").close()
        except OSError:
            denied(path, "write")
        print("Probing this line; this takes a few minutes...")
        if systemctl("start", "proxy-suite-zapret2-cutoff.service")[0]:
            die(f"The probe failed. Details: {journal_hint('proxy-suite-zapret2-cutoff', 30)}")
    elif verb != "status":
        usage("zapret cutoff [status|probe]")

    try:
        ts = int(read_text(os.path.join(path, "ts")).strip())
    except (OSError, ValueError):
        print("Not probed yet.")
        return
    try:
        egress = read_text(os.path.join(path, "egress")).rstrip("\n")
    except OSError:
        egress = ""
    print(f"Probed:  {datetime.datetime.fromtimestamp(ts):%Y-%m-%d %H:%M} from {egress}")
    # Same test as the probe's own awk (cutoff.nix): a row is a network only when
    # its first field is entirely digits, so the count and the list cannot disagree.
    cut = [row[0] for row in _tsv(os.path.join(path, "asn.txt")) if row[0].isdigit()]
    if not cut:
        print("Cutoff:  none on this line")
        return
    print(f"Cutoff:  {len(cut)} network(s)")
    names = {row[0]: row[1] if len(row) > 1 else "" for row in _tsv(os.path.join(path, "sni.txt")) if row[0].isdigit()}
    for asn in cut:
        print(f"  AS{asn:<8} {names.get(asn, 'no name - proxy fallback')}")


# --- where --------------------------------------------------------------------
#
# What the runtime state says about one host. Hostlists and autoProxy both key
# on an apex, so a miss on the full name retries each parent label.


def _where_row(key, value):
    print(f"  {key:<14} {value}")


def _where_parents(domain):
    while domain:
        yield domain
        domain = domain.split(".", 1)[1] if "." in domain else ""


def _where_in(names, domain):
    """The first parent of domain that names holds, empty when none is."""
    return next((d for d in _where_parents(domain) if d in names), "")


def _where_in_list(path, domain):
    if not readable(path):
        return ""
    try:
        return _where_in(set(lines(read_text(path))), domain)
    except OSError:
        return ""


# The generated configs are walked rule by rule, the way each backend would for
# a connection by name: IP rules need an address, so they are not consulted.


def _where_suffix(domain, suffix):
    """sing-box domain_suffix: the name or a subdomain; a leading dot means subdomains only."""
    return domain.endswith(suffix) if suffix.startswith(".") else domain == suffix or domain.endswith("." + suffix)


def _where_rule_set_match(rule_set, domain):
    path, fmt = rule_set.get("path"), rule_set.get("format", "source")
    if not isinstance(path, str) or not readable(path):
        return False
    try:
        out = subprocess.run(
            [env("SING_BOX", "sing-box"), "rule-set", "match", "-f", fmt, path, domain],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    # sing-box logs the verdict to stderr, and prints nothing on a miss.
    return "match rules" in out.stdout + out.stderr


def _where_sing_box(config, domain):
    """(outbound, why) of the first route rule matching domain; the final outbound when none does."""
    route = config.get("route") or {}
    rule_sets = {r.get("tag"): r for r in route.get("rule_set") or [] if isinstance(r, dict)}
    for rule in route.get("rules") or []:
        # Inbound-bound rules belong to probes and test listeners; the rest are actions.
        if not isinstance(rule, dict) or "inbound" in rule or "outbound" not in rule:
            continue
        hit = next((f"domain {d}" for d in rule.get("domain") or [] if d == domain), "")
        hit = hit or next((f"domain_suffix {s}" for s in rule.get("domain_suffix") or [] if _where_suffix(domain, s)), "")
        hit = hit or next((f"domain_keyword {k}" for k in rule.get("domain_keyword") or [] if k in domain), "")
        hit = hit or next((f"domain_regex {r}" for r in rule.get("domain_regex") or [] if re.search(r, domain)), "")
        hit = hit or next(
            (f"rule-set {t}" for t in rule.get("rule_set") or [] if _where_rule_set_match(rule_sets.get(t, {}), domain)),
            "",
        )
        if hit:
            return _s(rule["outbound"]), hit
    return _s(route.get("final", "direct")), "no rule matches, the final outbound"


def _where_inbounds(config, domain, geosite_dir):
    """(outboundTag, why) of the first XRay inbound routing rule matching domain by name."""
    for rule in (config.get("routing") or {}).get("rules") or []:
        if not isinstance(rule, dict):
            continue
        if rule.get("ruleTag") == "inbound-final":
            return _s(rule.get("outboundTag")), "no rule matches, the default egress"
        for entry in rule.get("domain") or []:
            kind, _, value = entry.partition(":") if ":" in entry else ("keyword", "", entry)
            matched = (
                (kind == "domain" and _where_suffix(domain, value))
                or (kind == "full" and domain == value)
                or (kind == "keyword" and value in domain)
                or (kind == "regexp" and re.search(value, domain))
                # XRay's geosite data is not readable from here; sing-box's lists of the same name stand in.
                or (kind == "geosite" and geosite_dir
                    and _where_rule_set_match({"path": os.path.join(geosite_dir, f"geosite-{value}.srs"), "format": "binary"}, domain))
            )
            if matched:
                # A rule held to some listeners or ports says so: the rest go on down the list.
                scope = "".join(
                    [f", listeners {','.join(map(_s, rule['inboundTag']))}" if rule.get("inboundTag") else ""]
                    + [f", ports {_s(rule['port'])}" if rule.get("port") else ""]
                )
                return _s(rule.get("outboundTag")), f"{_s(rule.get('ruleTag'))} ({entry}{scope})"
    return "", ""


def _where_live(domain):
    """Open connections to domain or a subdomain, as Counter-like {exit: count}."""
    status, body = _clash("GET", "/connections", timeout=5)
    exits = {}
    for c in (body or {}).get("connections") or [] if status == 200 and isinstance(body, dict) else []:
        host = _s((c.get("metadata") or {}).get("host") or "")
        chains = c.get("chains") or []
        if host and chains and _where_suffix(host, domain):
            exits[_s(chains[0])] = exits.get(_s(chains[0]), 0) + 1
    return exits


def cmd_where(domain="", *_):
    if not domain:
        usage("where <domain>")
    domain = domain.split("://", 1)[-1].split("/", 1)[0]
    verdict = ""
    _where_row("domain", domain)

    local = ""
    if svc_exists("proxy-suite-socks"):
        _where_row("route mode", _route_mode_label(_route_mode_current()))
        outbound = _status_outbound()
        if outbound:
            _where_row("outbound", outbound)

        config_path = _runtime_file("config.json")
        geosite_dir = ""
        if readable(config_path):
            try:
                config = read_json(config_path)
            except (OSError, ValueError):
                config = None
            if isinstance(config, dict) and "route" in config:
                exit_tag, why = _where_sing_box(config, domain)
                local = outbound if exit_tag == "proxy" and outbound else exit_tag
                shown = f"proxy -> {outbound}" if local != exit_tag else exit_tag
                _where_row("sing-box", f"{shown} - {why}")
                geosite_dir = next(
                    (os.path.dirname(r["path"]) for r in config["route"].get("rule_set") or []
                     if isinstance(r, dict) and "/geosite-" in _s(r.get("path", ""))),
                    "",
                )

        live = _where_live(domain)
        if live:
            _where_row("live", ", ".join(f"{n} via {tag}" for tag, n in sorted(live.items())))
            local = " and ".join(sorted(live))

        if env("INBOUNDS_ENABLED") == "1":
            inbounds_path = f"{runtime_dir()}/proxy-suite-inbounds/config.json"
            if not readable(inbounds_path):
                _where_row("inbounds", f"routing is not readable - {ask_group()}")
            else:
                try:
                    tag, why = _where_inbounds(read_json(inbounds_path), domain, geosite_dir)
                except (OSError, ValueError, AttributeError):
                    tag, why = "", ""
                if tag:
                    shown = f"{tag} (then sing-box: {local})" if tag == "proxy" and local else tag
                    _where_row("inbounds", f"{shown} - {why}")

    if env("AUTOPROXY_ENABLED") == "1":
        if not readable(os.path.join(_autoproxy_dir(), "state.json")):
            _where_row("autoProxy", f"state is not readable - {ask_group()}")
        else:
            domains = _autoproxy_state(_autoproxy_dir()).get("domains")
            hit = _where_in(domains if isinstance(domains, dict) else {}, domain)
            if not hit:
                _where_row("autoProxy", "not routed")
            else:
                d = domains[hit]
                exit_tag = _s(d.get("exit"))
                ago = _ago(d.get("at"), int(time.time()))
                _where_row("autoProxy", f"routed via {exit_tag}, learned from {_s(d.get('host'))}, checked {ago} ago")
                verdict = f"proxied via {exit_tag}"

    if env("ZAPRET_AUTO_ENABLED") == "1":
        excluded = _where_in_list(_zapret_auto_file("zapret-hosts-user-exclude.txt"), domain)
        pinned = _where_in_list(_zapret_auto_file("zapret-hosts-user.txt"), domain)
        learned = _where_in_list(_zapret_auto_file("zapret-hosts-auto.txt"), domain)
        if excluded:
            _where_row("zapret", f"excluded ({excluded}) - never bypassed, never learned")
        elif pinned:
            _where_row("zapret", f"pinned ({pinned}) - always bypassed")
            verdict = verdict or "direct, with the zapret bypass"
        elif learned:
            _where_row("zapret", f"learned ({learned}) - bypassed")
            verdict = verdict or "direct, with the zapret bypass"
        else:
            _where_row("zapret", "not learned, not pinned, not excluded")

    if local:
        zapret = verdict == "direct, with the zapret bypass"
        verdict = f"{local}, with the zapret bypass" if zapret and local == "direct" else local
        print(f"  -> {verdict}")
        return
    print(f"  -> {verdict or 'nothing runtime matches it; the configured routing decides'}")
    print("  The sing-box config is not readable here. Test what reaches it:")
    print(f"    proxy-ctl proxy auto probe {domain}")


# --- awg ----------------------------------------------------------------------


def _awg_service(profile):
    return f"proxy-suite-awg-{profile}"


def _active_awg_profiles():
    return [p for p in _awg_profiles() if svc_active(_awg_service(p))]


def cmd_awg(verb="list", *args):
    profiles = _awg_profiles()
    if args and args[0] not in profiles:
        die(f"Unknown AmneziaWG profile: {args[0]}")
    if verb in ("list", "status"):
        if not profiles:
            print("No AmneziaWG profiles configured.")
            return
        print(f"  {'PROFILE':<24} STATUS")
        for profile in profiles:
            print(f"  {profile:<24} {svc_state(_awg_service(profile)) or 'unknown'}")
    elif verb == "on":
        if not args:
            usage("awg on <profile>")
        must("start", _awg_service(args[0]))
    elif verb in ("off", "restart"):
        targets = list(args[:1]) or _active_awg_profiles()
        if not targets:
            if verb == "off":
                return
            die("No AmneziaWG profile is active.")
        for profile in targets:
            must("stop" if verb == "off" else "restart", _awg_service(profile))
    else:
        usage("awg [list] | on <profile> | off [profile] | restart [profile]")


# --- apps ---------------------------------------------------------------------

SLICE_ROUTES = {
    "tun": ("proxy-suite-per-app-tun", "PER_APP_ROUTING_TUN_ENABLED", "perAppRouting.tun.enable"),
    "tproxy": ("proxy-suite-per-app-tproxy", "PER_APP_ROUTING_TPROXY_ENABLED", "perAppRouting.tproxy.enable"),
    "zapret": ("proxy-suite-per-app-zapret", "PER_APP_ROUTING_ZAPRET_ENABLED", "perAppRouting.zapret.enable"),
}


def _per_app_profiles():
    try:
        return read_json(env("PER_APP_ROUTING_PROFILES_FILE"))
    except (OSError, ValueError):
        die(f"Cannot read perAppRouting profiles: {env('PER_APP_ROUTING_PROFILES_FILE')}")


def _ensure_app_routing():
    require_enabled("PER_APP_ROUTING_ENABLED", "perAppRouting")


def _check_no_global_proxy(route):
    for svc in ("proxy-suite-tun", "proxy-suite-tproxy"):
        if svc_active(f"{svc}.service"):
            die(f"Global {svc}.service is active. Stop it before using route={route} profiles.")


def _has_units(*args):
    return bool(re.search(".", systemctl(*args, capture=True)[1]))


def _cleanup_slice_if_idle(slice_base, anchor_unit, user_svc, backend_svc):
    if _has_units("--user", "list-units", "--type=scope", "--state=running", "--plain", "--no-legend", f"{slice_base}-*"):
        return
    systemctl("stop", user_svc)
    systemctl("--user", "stop", anchor_unit)
    if not _has_units("list-units", "--type=service", "--state=active", "--plain", "--no-legend", f"{slice_base}-user@*.service"):
        systemctl("stop", backend_svc)


def _stub_resolver_nameservers(path="/etc/resolv.conf"):
    """The resolvers /etc/resolv.conf names, if every one of them is a local stub."""
    try:
        found = [
            line.split()[1]
            for line in lines(read_text(path))
            if line.split()[:1] == ["nameserver"] and len(line.split()) > 1
        ]
    except OSError:
        return []
    stub = [x for x in found if x.startswith("127.") or x in ("::1", "localhost")]
    return stub if found and len(stub) == len(found) else []


def _warn_stub_resolver(route):
    """A wrapped app asking a local stub resolver leaks its names: the stub answers from
    its own process, which is outside the app's cgroup and so outside the app's route."""
    stub = _stub_resolver_nameservers()
    if not stub:
        return
    print(
        f"warning: {stub[0]} is this host's only resolver, and it answers from outside the "
        f"wrapped app's cgroup, so names resolve outside route={route}. Point the app at a "
        "resolver of its own to keep its DNS in the tunnel.",
        file=sys.stderr,
    )


def _wrap_slice(slice_base, profile, backend_svc, cmd):
    """Runs cmd in a user scope inside the route's slice, then stops what went idle."""
    uid = os.getuid()
    scope_unit = f"{slice_base}-{profile}-{os.getpid()}"
    anchor_unit = f"{slice_base}-anchor.service"
    user_svc = f"{slice_base}-user@{uid}.service"
    # SIGTERM still cleans up, as it did behind bash's EXIT trap.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        status = systemctl("--user", "start", anchor_unit)[0]
        status = status or systemctl("start", backend_svc)[0]
        status = status or systemctl("start", user_svc)[0]
        if not status:
            status = _run_foreground(
                [
                    "systemd-run",
                    "--user",
                    "--scope",
                    "--quiet",
                    "--collect",
                    "--same-dir",
                    f"--slice={slice_base}",
                    f"--unit={scope_unit}",
                    *cmd,
                ]
            )
    finally:
        _cleanup_slice_if_idle(slice_base, anchor_unit, user_svc, backend_svc)
    sys.exit(status)


def cmd_apps(verb="list", *args):
    _ensure_app_routing()
    if verb == "list":
        profiles = _per_app_profiles()
        if not profiles:
            print("No perAppRouting profiles configured.")
            return
        print(f"  {'PROFILE':<24} ROUTE")
        for p in profiles:
            print(f"  {_s(p.get('name')):<24} {_s(p.get('route'))}")
    elif verb == "run":
        cmd_apps_run(*args)
    else:
        usage("apps [list] | run <profile> -- <cmd> [args]")


def cmd_apps_run(profile="", *cmd):
    if cmd[:1] == ("--",):
        cmd = cmd[1:]
    if not profile or not cmd:
        usage("apps run <profile> -- <cmd> [args]")

    route = next((_s(p.get("route")) for p in _per_app_profiles() if p.get("name") == profile), "")
    if not route:
        die(f"Unknown perAppRouting profile: {profile}")

    if route == "direct":
        _exec(list(cmd))
    elif route == "proxychains":
        if env("PER_APP_ROUTING_PROXYCHAINS_ENABLED") != "1":
            die(f"Profile '{profile}' uses route=proxychains, but perAppRouting.proxychains.enable is false.")
        config = env("PROXYCHAINS_CONFIG")
        if not readable(config):
            die(f"Proxychains config is not readable: {config} (is proxy-suite-socks running?)")
        _exec(["proxychains4", *env("PROXYCHAINS_QUIET_ARG").split(), "-f", config, *cmd])
    elif route in SLICE_ROUTES:
        slice_base, enabled, option = SLICE_ROUTES[route]
        _check_no_global_proxy(route)
        if env(enabled) != "1":
            die(f"Profile '{profile}' uses route={route}, but {option} is false.")
        _warn_stub_resolver(route)
        _wrap_slice(slice_base, profile, f"{slice_base}.service", list(cmd))
    else:
        die(f"Route backend '{route}' is not implemented.")


# --- inbounds -----------------------------------------------------------------


def _inbound_links():
    """Links carry listener credentials, so the file is root/group-only."""
    path = env("INBOUNDS_LINKS_FILE")
    if not os.path.isfile(path):
        die("No share links available. Is proxy-suite-inbounds running, and is inbounds.shareLinks enabled?")
    if not readable(path):
        denied(path)
    return read_json(path)


def _inbound_server_json(tag):
    """The XRay inbound as the server runs it, secrets and all."""
    path = os.path.join(os.path.dirname(env("INBOUNDS_LINKS_FILE", f"{runtime_dir()}/proxy-suite-inbounds/links.json")), "config.json")
    if not os.path.isfile(path):
        die("No inbound config yet - is proxy-suite-inbounds running?")
    if not readable(path):
        denied(path)
    inbound = next((x for x in read_json(path).get("inbounds") or [] if x.get("tag") == tag), None)
    if inbound is None:
        die(f"Unknown inbound: {tag}")
    print(_json_text(inbound))


def _inbound_link_for(tag, user="", *_, field="link", variant=""):
    """variant "onion": the link to the listener through the onion service."""
    matches = [
        x
        for x in _inbound_links()
        if x.get("tag") == tag and (not user or x.get("user") == user) and (x.get("variant") or "") == variant
    ]
    if not matches:
        if variant == "onion":
            die(f"No onion link for {tag}: is it in tor.onionService.listeners, and has Tor written its address?")
        die(f"Unknown inbound, or no share link for it: {tag}")
    if len(matches) > 1:
        sys.stdout.flush()
        print(f"Multiple users match '{tag}'; specify one of:", file=sys.stderr)
        for x in matches:
            print(f"  {_s(x.get('user'))}", file=sys.stderr)
        sys.exit(1)
    entry = matches[0]
    if field == "link":
        return _s(entry.get("link"))
    if entry.get(field) is not None:
        return entry[field]
    if field == "config":
        die(f"No client config for {tag}: only AmneziaWG listeners have one - use the link.")
    if entry.get("type") == "amneziawg":
        die(f"No client JSON for {tag}: AmneziaWG clients take a config - use --config.")
    die(f"No client JSON for {tag}: proxy-suite cannot parse its link.")


def _human_bytes(b):
    if b >= 1073741824:
        return f"{b / 1073741824:.1f} GiB"
    if b >= 1048576:
        return f"{b / 1048576:.1f} MiB"
    if b >= 1024:
        return f"{b / 1024:.0f} KiB"
    return f"{b:g} B"


def _today():
    return datetime.date.today()


STATS_KINDS = ("user", "inbound", "outbound")


def _inbound_stats(*args):
    """Traffic over the last `days` days by user, inbound or outbound, newest first, then totals."""
    days, kind, rest = "7", "user", list(args)
    if "--by" in rest:
        i = rest.index("--by")
        kind = rest[i + 1] if i + 1 < len(rest) else ""
        del rest[i : i + 2]
    if rest:
        days = rest.pop(0)
    if rest or kind not in STATS_KINDS or not re.fullmatch(r"[1-9][0-9]*", days):
        usage("inbounds stats [days] [--by user|inbound|outbound]")
    path = env("INBOUNDS_STATS_FILE", f"{state_dir()}/inbound-stats.json")
    # Collect what XRay counted since the last run first; root and userControl
    # members may, anyone else reads what the timer last wrote.
    systemctl("--no-ask-password", "start", "proxy-suite-inbound-stats.service", quiet=True)
    if not os.path.exists(path):
        die("No traffic recorded yet - the collector runs every 5 minutes.")
    if not readable(path):
        denied(path)
    stats = read_json(path)
    since = (_today() - datetime.timedelta(days=int(days) - 1)).isoformat()
    print(f"Traffic through the inbounds since {since}, by {kind}:")

    records = [
        (day, name, (c or {}).get("down") or 0, (c or {}).get("up") or 0)
        for day, kinds in (stats.get("days") or {}).items()
        if day >= since
        for name, c in ((kinds or {}).get(kind) or {}).items()
    ]
    if not records:
        print("  (nothing recorded)")
        return
    row = "  {:<12} {:<20} {:>10} {:>10}"
    print(row.format("DAY", kind.upper(), "DOWN", "UP"))
    # Newest day first, names in order within a day.
    for day, name, down, up in sorted(sorted(records, key=lambda r: r[1]), key=lambda r: r[0], reverse=True):
        print(row.format(day, name, _human_bytes(down), _human_bytes(up)))
    totals = {}
    for _, name, down, up in records:
        d, u = totals.get(name, (0, 0))
        totals[name] = (d + down, u + up)
    total = "  {:<33} {:>10} {:>10}"
    print()
    print(total.format("TOTAL", "DOWN", "UP"))
    for name, (down, up) in sorted(totals.items()):
        print(total.format(name, _human_bytes(down), _human_bytes(up)))


AWG_ONLINE_SECONDS = 180


def _inbound_presence():
    """user -> (state, addresses): "online", "seen <time>" or "never seen"; dies when the stats API is silent."""
    status, out = _run(
        [env("INBOUNDS_XRAY", "xray"), "api", "statsonlineiplist", f"--server={env('INBOUNDS_API', '127.0.0.1:18536')}", "-all"],
        capture=True,
        quiet=True,
    )
    if status != 0:
        die("The inbounds' stats API is not answering - is proxy-suite-inbounds running?")
    try:
        online = {_s(u.get("email")): u.get("ips") or [] for u in json.loads(out or "{}").get("users") or []}
    except (ValueError, AttributeError):
        die("Unexpected answer from the inbounds' stats API.")
    # Users nobody has seen yet, when the links say who exists.
    path = env("INBOUNDS_LINKS_FILE")
    links = read_json(path) if readable(path) else []
    known = {_s(x.get("user")) for x in links if x.get("user")}
    # AmneziaWG peers are only known by their last handshake, which the collector reads;
    # the XRay API already told who else is online now.
    if any(x.get("type") == "amneziawg" for x in links):
        systemctl("--no-ask-password", "start", "proxy-suite-inbound-stats.service", quiet=True)
    path = env("INBOUNDS_STATS_FILE", f"{state_dir()}/inbound-stats.json")
    stats = read_json(path) if readable(path) else {}
    seen = stats.get("seen") or {}
    now = time.time()
    for user, peer in (stats.get("awgPeers") or {}).items():
        handshake = (peer or {}).get("handshake") or 0
        endpoint = _s((peer or {}).get("endpoint") or "")
        # A live peer handshakes every two minutes.
        if handshake and now - handshake < AWG_ONLINE_SECONDS and endpoint:
            online.setdefault(_s(user), []).append({"ip": endpoint.rsplit(":", 1)[0].strip("[]")})

    def when(ts):
        return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")

    presence = {}
    for user in sorted(set(online) | set(seen) | known):
        ips = online.get(user)
        if ips:
            presence[user] = ("online", ", ".join(_s(i.get("ip")) for i in ips))
        elif user in seen:
            presence[user] = (f"seen {when(seen[user])}", "")
        else:
            presence[user] = ("never seen", "")
    return presence


def _inbound_online():
    """Users connected right now with their addresses, then when the others were last seen."""
    row = "  {:<20} {:<24} {}"
    presence = _inbound_presence()
    print(row.format("USER", "STATE", "ADDRESSES"))
    for user, (state, addresses) in presence.items():
        print(row.format(user, state, addresses))
    sys.stdout.flush()
    print(
        "A user counts as online while a connection is open, or for AmneziaWG within three minutes "
        "of a handshake. Behind a web server that needs the listener's transport.trustedXForwardedFor, "
        "or everyone reads as never seen.",
        file=sys.stderr,
    )


def _inbound_subscriptions(*args):
    """Without a user: user names only, since each URL is its user's secret."""
    user = ""
    qr = False
    for arg in args:
        if arg == "--qr":
            qr = True
        else:
            user = arg
    path = env("INBOUNDS_SUBS_FILE", f"{runtime_dir()}/proxy-suite-inbounds/subscriptions.json")
    base = env("INBOUNDS_SUB_BASE_URL")
    if not os.path.isfile(path):
        die("No subscriptions available. Is proxy-suite-inbounds running, and is inbounds.subscriptions enabled?")
    if not readable(path):
        denied(path)
    subs = read_json(path)
    if not user:
        if qr:
            usage("inbounds sub <user> --qr")
        for s in subs:
            print(f"  {_s(s.get('user'))}")
        sys.stdout.flush()
        print("Show one with: proxy-ctl inbounds sub <user> [--qr]", file=sys.stderr)
        return
    token = next((s.get("token") for s in subs if s.get("user") == user), None)
    if not token:
        die(f"No subscription for user: {user}")
    if base:
        _emit(f"{base.removesuffix('/')}/{_s(token)}", qr)
    else:
        if qr:
            die("A QR code needs inbounds.subscriptions.baseUrl.")
        print(f"{path.removesuffix('.json')}/{_s(token)}")
        sys.stdout.flush()
        print("Set inbounds.subscriptions.baseUrl to get a URL instead of a path.", file=sys.stderr)


def cmd_inbounds(verb="list", *args):
    require_enabled("INBOUNDS_ENABLED", "inbounds")
    if verb == "list":
        state = svc_state("proxy-suite-inbounds")
        row = "  {:<24} {:<16} {:<14} {:<8} {}"
        print(row.format("TAG", "USER", "TYPE", "PORT", "STATE"))
        for x in _inbound_links():
            kind = _s(x.get("type")) + (" (onion)" if x.get("variant") == "onion" else "")
            print(row.format(_s(x.get("tag")), _s(x.get("user")), kind, _s(x.get("port")), state))
    elif verb in ("link", "qr"):
        rest = [a for a in args if not a.startswith("--")]
        if not rest:
            usage("inbounds link <tag> [user] [--onion] [--qr|--json|--config|--server-json]")
        qr = verb == "qr" or "--qr" in args
        variant = "onion" if "--onion" in args else ""
        if "--server-json" in args:
            _inbound_server_json(rest[0])
        elif "--json" in args:
            print(_json_text(_inbound_link_for(*rest, field="outbound", variant=variant)))
        elif "--config" in args:
            _emit(_inbound_link_for(*rest, field="config", variant=variant).rstrip("\n"), qr)
        else:
            _emit(_inbound_link_for(*rest, variant=variant), qr)
    elif verb == "stats":
        _inbound_stats(*args)
    elif verb == "online":
        _inbound_online()
    elif verb == "sub":
        _inbound_subscriptions(*args)
    else:
        usage("inbounds [list] | link <tag> [user] [--qr] | sub [user] [--qr] | stats [days] [--by user|inbound|outbound] | online")


# --- main ---------------------------------------------------------------------

# Old spellings: still accepted, not in the help.
ALIASES = {
    "tun": ["proxy", "tun"],
    "tproxy": ["proxy", "tproxy"],
    "outbounds": ["proxy", "outbounds"],
    "route-mode": ["proxy", "mode"],
    "subscription": ["proxy", "subs"],
    "wrap": ["apps", "run"],
}


def cmd_logs(*units):
    if units:
        # One -u per unit: a bare second name would be taken as a journal match.
        _exec(_manager_argv("journalctl", ["-f", *(f"--unit={u}" for u in units)]))
    # journalctl takes unit globs, so the default needs no unit list of its own.
    _exec(_manager_argv("journalctl", ["-f", "-u", "proxy-suite-*"]))


COMMANDS = {
    "help": lambda *_: sys.stdout.write(HELP),
    "-h": lambda *_: sys.stdout.write(HELP),
    "--help": lambda *_: sys.stdout.write(HELP),
    "status": cmd_status,
    "restart": cmd_restart,
    "logs": cmd_logs,
    "proxy": cmd_proxy,
    "zapret": cmd_zapret,
    "awg": cmd_awg,
    "ssh": lambda *args: _toggle("proxy-suite-ssh-proxy", "ssh", *args),
    "warp": lambda *args: _toggle(_warp_unit(), "warp", *args),
    "tor": cmd_tor,
    "tg": lambda *args: _toggle("proxy-suite-tg-ws-proxy", "tg", *args),
    "apps": cmd_apps,
    "inbounds": cmd_inbounds,
    "where": cmd_where,
    "__complete": cmd_complete,
}


def main(argv):
    # Die quietly on a closed pipe (`proxy-ctl help | head`), as a shell tool does.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    if argv and argv[0] in ALIASES:
        argv = ALIASES[argv[0]] + argv[1:]
    cmd, args = (argv[0], argv[1:]) if argv else ("status", [])
    if cmd not in COMMANDS:
        sys.stderr.write(HELP)
        sys.exit(1)
    try:
        COMMANDS[cmd](*args)
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main(sys.argv[1:])
