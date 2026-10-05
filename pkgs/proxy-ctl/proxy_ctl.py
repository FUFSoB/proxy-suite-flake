"""proxy-ctl: control proxy-suite services and inspect their runtime state.

Configuration arrives through the environment the Nix wrapper sets.
"""

import base64
import contextlib
import datetime
import errno
import fcntl
import getpass
import http.client
import importlib
import ipaddress
import json
import os
import re
import shutil
import signal
import socket
import stat
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
    "proxy-suite-killswitch",
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
A group alone shows its status or list.
Groups with on|off also take toggle and restart.
Changes and secrets need root or the userControl group.

  status [--json]                        services and routing mode (--tray: deprecated)
  restart                                restart running services
  logs [unit...]                         follow logs (default: all proxy-suite units); in a
                                         terminal, in lnav: scroll back, G follows, q quits
  where <domain>                         how a domain is routed right now

  proxy [status|on|off]                  local proxy
  proxy outbounds [list]                 outbounds, their source, and the current pick
  proxy outbounds add [tag] <url|json|-> [--detour <tag>]
                                         add an outbound from a link or JSON (-: stdin);
                                         --detour: connect through another outbound
  proxy outbounds add [tag] <vpn://…|file.conf|-> [--container <name>]
                                         add an AmneziaWG outbound (runs in wireproxy)
  proxy outbounds chain <tag> <through-tag> [new tag]
                                         add a copy of an outbound that connects through another
  proxy outbounds rm <tag>               remove a runtime outbound
  proxy outbounds disable|enable <tag>   exclude from automatic use (selection, autoProxy), or undo
  proxy outbounds test [tag...] [--ping] [--delay] [--download]
                                         test ping, delay, download speed (default: ping, delay)
  proxy outbounds link <tag> [--qr|--json|--config]
                                         its link, QR code, JSON, or client config
  proxy pin [tag] [--in <group>]         always use this outbound (no tag: pick from a menu);
                                         --in: hold a group on one of its members
  proxy unpin [--in <group>]             go back to automatic selection
  proxy groups [list]                    outbound groups, their members, and what each uses
  proxy groups add <tag> [member...] [--sub <sub>]... [--match <pattern>]...
               [--strategy failover|urltest|selector] [--no-failback] [--interval <d>]
                                         add a group (failover by default)
  proxy groups rm <tag>                  remove a group added with groups add
  proxy groups members <tag> add|rm <member...>
  proxy groups strategy <tag> failover|urltest|selector
  proxy priority [list]                  the top level in the order it is picked in
  proxy priority <tag> <n>|up|down|--clear
                                         lower goes first; up/down renumbers the top level
  proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]
                                         show or override the routing mode
  proxy subs [list|update]               subscriptions; update refetches them
  proxy subs add [tag] <url|->           add a subscription (no tag: named after its host; -: stdin)
  proxy subs rm <tag>                    remove a runtime subscription
  proxy subs link <tag> [--qr]           its URL
  proxy rulesets [list|update]           rule sets and when they were fetched; update refetches
  proxy config [--raw]                   client config to use elsewhere; --raw: as running
  proxy tun [status|on|off]              global TUN mode
  proxy tproxy [status|on|off]           global TProxy mode
  proxy auto [list]                      what autoProxy routed, and through which exit
  proxy auto probe <domain>[/path] [--json] [--keep-going] [--exits a,b | --via tag]
                                         find an exit that reaches a domain
  proxy auto learn <domain>              probe now, and route it if an exit works
  proxy auto forget <domain>             forget it (direct until learned again)
  proxy auto relearn <domain>            forget it and probe again now
  proxy auto clear                       forget everything learned
  proxy auto queue [count]               destinations waiting to be probed

  zapret [status|on|off]                 DPI bypass
  zapret auto [list]                     sites zapret2 learned as blocked
  zapret auto add|forget|exclude <domain>
                                         treat a site as blocked, forget it, or never touch it
  zapret auto unpin|include <domain>     undo add or exclude
  zapret auto retry <domain|ip>          give zapret2 another try where it sent the proxy
  zapret auto clear                      forget learned sites and strategies
  zapret cutoff [status]                 networks cut off at 16 KB, and names that pass
  zapret cutoff probe                    probe again now

  awg [list]                             AmneziaWG profiles
  awg on <profile> | off [profile] | toggle [profile] | restart [profile]
  awg add [name] <vpn://…|file.conf|-> [--container <name>]
                                         add a global profile (-: stdin)
  awg rm <profile>                       remove a profile added with awg add

  killswitch [status|on|off]             block traffic outside the global tunnel;
                                         stays on until turned off here or with the tunnel

  ssh [status|on|off]                    SSH tunnel
  warp [status|on|off] [device]          WARP tunnel (every device, or the one named)
  tor [status|on|off]                    Tor
  tor newnym                             new circuits for new connections
  tg [status|on|off]                     Telegram proxy
  wl [list]                              whitelist-bypass creators and joiners
  wl link <creator> [--qr]               the call link for its joiner
  wl auth <creator> [file|-]             replace its login: cookies, or prompt (DION, Bitrix)
  wl join <joiner> <link|->              set the call to join
  wl new <creator>                       start a new call
  wl on|off|toggle|restart [name]        one creator or joiner, or all

  apps [list]                            per-app routing profiles
  apps run <profile> -- <cmd> [args]     run a command through a profile
  apps run --via <outbound> -- <cmd>     run a command through one outbound
                                         (--route tun|tproxy picks the method)
  apps add <name> [--route r] [--via o]  add a profile without a rebuild
  apps rm <name>                         remove one added that way

  inbounds [list]                        server inbounds
  inbounds link <tag> [user] [--onion|--variant=<name>] [--qr|--json]
                                         share link or client JSON; --onion: via the onion
                                         service; --variant: one of the listener's shareVariants
  inbounds link <tag> [user] --config [--qr]
                                         AmneziaWG client .conf or its QR code
  inbounds link <tag> --server-json      the server's inbound JSON
  inbounds sub [user] [--qr]             subscription users, or one user's URL
  inbounds stats [days] [--by user|inbound|outbound]
                                         traffic by user, listener or exit
  inbounds users [list]                  users: order, serverSource address, listeners
                                         (the rest below needs inbounds.runtime)
  inbounds users add <name> [--order N] [--listener <tag>]...
                                         add a user at runtime, with generated secrets
  inbounds users rm <name>               remove a runtime user
  inbounds users order <name> <N>        a runtime user's order (serverSource number)
  inbounds bind|unbind <user> <tag>      put a user on a listener, or take it off
                                         (a runtime user, or a runtime listener)
  inbounds add <tag> <type> [--port N] [--via V] [--transport T] [--path P] [--host H]
      [--reality SNI[,SNI]] [--tls <cert>] [--alpn a,b] [--flow vision] [--method M]
      [--listen A] [--user U]... [more: see inbounds add --help]
                                         add a listener at runtime
  inbounds add <tag> <file.json|->       add one from JSON shaped like inbounds.listeners.<tag>
  inbounds rm <tag>                      remove a runtime listener
  inbounds show <tag>                    a runtime listener's JSON
  inbounds online                        who is online, and when others were last seen
"""

ROUTE_MODES = ["whitelist", "blacklist", "all-proxy", "all-bypass"]
ROUTE_MODE_LABELS = {
    "whitelist": "Whitelist (direct by default)",
    "blacklist": "Blacklist (proxy by default)",
    "all-proxy": "All Proxy (override)",
    "all-bypass": "All Bypass (override)",
}

# `inbounds add`: the listener types and flags scripts/inbound_runtime.py takes.
INBOUND_TYPES = ("vless", "vmess", "trojan", "hysteria2", "shadowsocks", "socks", "http")
INBOUND_ADD_FLAGS = {
    "--port": "port, from inbounds.runtime.ports",
    "--listen": "listening address (default ::)",
    "--via": "where its traffic exits",
    "--transport": "raw, ws, grpc, httpupgrade or xhttp",
    "--path": "ws, httpupgrade or xhttp path",
    "--host": "expected Host header",
    "--mode": "xhttp mode",
    "--service-name": "gRPC service name",
    "--reality": "REALITY server names, comma-separated",
    "--reality-dest": "REALITY dest host:port",
    "--short-id": "REALITY short ID",
    "--tls": "a certificate from inbounds.runtime.tlsCertificates",
    "--alpn": "ALPN, comma-separated",
    "--sni": "SNI in share links",
    "--flow": "vless flow (vision)",
    "--method": "shadowsocks cipher",
    "--share-port": "port in share links",
    "--share-address": "address in share links",
    "--fingerprint": "browser fingerprint in share links (fp)",
    "--order": "position in links and subscriptions",
    "--masquerade": "hysteria2: site shown to anything else",
    "--salamander": "hysteria2: Salamander obfuscation",
    "--user": "a user it accepts",
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


# Lists the zapret and outbounds groups write to: zapret's learned hosts run to thousands of
# lines, never to this.
SHARED_TEXT_MAX_BYTES = 16 * 1024 * 1024


def read_shared_text(path, limit=SHARED_TEXT_MAX_BYTES):
    """A file in a directory a group writes to: regular, not through a symlink, at most limit
    bytes, else OSError. A member's link, FIFO or /dev/zero must not be read by root's run."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError(errno.EINVAL, "not a regular file", path)
        data = f.read(limit + 1)
    if len(data) > limit:
        raise OSError(errno.EFBIG, "file too large", path)
    return data.decode("utf-8", errors="replace")


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
    primary = env("USER_CONTROL_GROUP", "proxy-suite")
    # userControl.groups too, each with scopes of its own: whichever holds the one needed.
    try:
        groups = [primary] + sorted(g for g in json.loads(env("USER_CONTROL_GROUPS") or "{}") if g != primary)
    except (ValueError, TypeError):
        groups = [primary]
    if len(groups) == 1:
        return f"join the {primary} group, or re-run with sudo"
    return f"join a userControl group whose scopes allow it ({', '.join(groups)}), or re-run with sudo"


def denied(path, what="read"):
    die(f"Cannot {what} {path} - {ask_group()}.")


def _spool_write(path, text="", mode=0o640):
    """Replaces path whole, 0640 by default, in a directory userControl's group may write to.

    Through a new file renamed over it: a symlink a member left at path is replaced rather
    than followed, so proxy-ctl run as root never writes where it points. The file takes
    the directory's group (the spools are setgid). Raises OSError.
    """
    fd, tmp = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            # By fd: a member may swap tmp for a symlink before a chmod by path.
            os.fchmod(f.fileno(), mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


LOCK_WAIT = 10


def _lock_path(path):
    return os.path.join(os.path.dirname(path) or ".", f".{os.path.basename(path)}.lock")


@contextlib.contextmanager
def _file_lock(path):
    """flock on .<name>.lock over a read-modify-write of path, so two proxy-ctl don't drop each
    other's change. Yields whether it is held: no lock file to be had means unlocked, as before."""
    lock = _lock_path(path)
    deadline = time.monotonic() + LOCK_WAIT
    while True:
        # Read-only and O_NOFOLLOW: flock needs no more, and the directory may be the group's.
        try:
            fd = os.open(lock, os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o660)
        except OSError:
            yield False
            return
        try:
            held = False
            while not held:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    held = True
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        die(f"Something else is still changing {path} (it holds {lock}); try again.")
                    time.sleep(0.05)
                except OSError:
                    break  # a lock flock refuses: unlocked, as without one
            # Removed by its holder meanwhile (groups rm): lock the one there now instead.
            if held and not _same_file(fd, lock):
                continue
            yield held
            return
        finally:
            os.close(fd)


def _same_file(fd, path):
    try:
        st, fst = os.stat(path, follow_symlinks=False), os.fstat(fd)
    except OSError:
        return False
    return (st.st_dev, st.st_ino) == (fst.st_dev, fst.st_ino)


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


def _run_foreground(argv, env=None):
    """Waits on argv the way a shell does: Ctrl-C is the child's to handle."""
    sys.stdout.flush()
    try:
        p = subprocess.Popen(argv, env=env)
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


def _flip(unit, verb="status"):
    """toggle as on or off, for the state unit is in now; any other verb as it is."""
    if verb == "toggle":
        return "off" if svc_active(unit) else "on"
    return verb


def _toggle(unit, name, verb="status", *_):
    if not svc_exists(unit):
        die(f"{name} is not enabled in this configuration.")
    verb = _flip(unit, verb)
    if verb == "status":
        # is-active's code too, as systemctl gives it (3: not active): `if proxy-ctl tor status` works.
        status, _ = systemctl("is-active", unit)
        if status:
            sys.exit(status)
    elif verb == "on":
        must("start", unit)
    elif verb == "off":
        must("stop", unit)
    elif verb == "restart":
        must("restart", unit)
    else:
        usage(f"{name} [status|on|off|toggle|restart]")


def _warp_devices():
    """[(tag, unit)] of the WARP devices behind outbounds: their sing-box tunnels or AmneziaWG profiles.

    A global "warp" profile belongs to `awg on warp`, not here.
    """
    try:
        devices = json.loads(env("WARP_DEVICES", "[]"))
    except ValueError:
        devices = []
    listed = [(_s(d["tag"]), _s(d["unit"])) for d in devices if isinstance(d, dict) and d.get("tag") and d.get("unit")]
    if listed:
        return listed
    # A wrapper from before WARP_DEVICES: the one device there was.
    awg = _awg_service("warp")
    if "warp" not in _awg_profiles() and svc_exists(awg):
        return [("warp", awg)]
    return [("warp", "proxy-suite-warp-tunnel")]


def cmd_warp(*args):
    """warp [status|on|off|toggle|restart] [device]: every device, or the one named."""
    devices = _warp_devices()
    tags = [t for t, _ in devices]
    args = list(args)
    if args and args[-1] in tags and args[-1] not in ("status", "on", "off", "toggle", "restart"):
        tag = args.pop()
        devices = [(t, u) for t, u in devices if t == tag]
    if len(args) > 1:
        usage(f"warp [status|on|off|toggle|restart] [{'|'.join(tags)}]")
    if len(devices) == 1:
        _toggle(devices[0][1], "warp", *args)
        return
    verb = args[0] if args else "status"
    states = []
    for tag, unit in devices:
        if verb == "status":
            state = systemctl("is-active", unit, capture=True, quiet=True)[1].strip() or "inactive"
            states.append(state)
            print(f"{tag:<16} {state}")
        else:
            print(f"{tag}:", flush=True)
            _toggle(unit, tag, verb)
    # As `systemctl is-active` with several units: 0 when any is active, else 3.
    if verb == "status" and "active" not in states:
        sys.exit(3)


def _tor_control(*commands):
    """Replies to commands on Tor's control socket, one list of lines per command.

    The socket authenticates by who can open it: root, and Tor's own user. Not the
    userControl group, which could publish any loopback port as an onion service with it.
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
        if env("PRIVILEGED") == "1" and os.geteuid() != 0:
            # The group's way in, polkit's "services" scope: a root unit that asks Tor.
            must("start", "proxy-suite-tor-newnym.service")
        else:
            _tor_control("SIGNAL NEWNYM")
        print("New connections take new circuits (Tor allows this once every 10 seconds).")
        return
    if verb not in ("status", "on", "off", "toggle", "restart"):
        usage("tor [status|on|off|toggle|restart|newnym]")
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
    """Global AmneziaWG profiles: the declared ones, then those added with `awg add`."""
    declared = _awg_declared()
    return declared + [p for p in _awg_runtime_profiles() if p not in declared]


def _awg_declared():
    return _json_list(env("AWG_PROFILES_FILE"))


def _awg_added(profile):
    """Whether a profile was added with `awg add` (a declared one of that name wins)."""
    return profile in _awg_runtime_profiles() and profile not in _awg_declared()


def _awg_runtime_dir():
    return env("AWG_RUNTIME_DIR", f"{state_dir()}/amneziawg.d")


def _awg_runtime_profiles():
    """Profiles added with `awg add`: <name>.conf in a listable dir, each file root-only."""
    if env("AWG_RUNTIME_GLOBAL") != "1":
        return []
    try:
        names = os.listdir(_awg_runtime_dir())
    except OSError:
        return []
    return sorted(n.removesuffix(".conf") for n in names if n.endswith(".conf") and AWG_NAME.fullmatch(n.removesuffix(".conf")))


# --- completion ---------------------------------------------------------------
#
# Candidates for the words already typed, one per line as word<TAB>description.
# The tree lives here, next to HELP, not in the completion files. A node offers
# its words and args until a positional is typed (always, when it repeats), and
# its flags until each is typed.

TOGGLE = {
    "status": "is it running",
    "on": "start it",
    "off": "stop it",
    "toggle": "start it if stopped, stop it if running",
    "restart": "stop it and start it again",
}


def _outbound_choices():
    sources = _outbound_inventory().get("sources") or {}
    return {tag: _s(sources.get(tag) or "") for tag in _outbound_tags()}


def _group_choices():
    return {g: f"group: {_s(i.get('strategy') or 'failover')}" for g, i in _outbound_groups().items()}


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
            "killswitch": "reject traffic outside the global tunnel",
            "ssh": "SSH SOCKS5 tunnel",
            "warp": "WARP tunnel behind the warp outbound",
            "tor": "Tor, behind the tor outbound and the onion service",
            "tg": "Telegram WebSocket proxy",
            "wl": "whitelist-bypass creators and joiners",
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
            "groups": "outbound groups",
            "priority": "the order the top level picks in",
            "mode": "show or override the routing mode",
            "subs": "subscription caches",
            "rulesets": "routing rule sets",
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
    "proxy outbounds add": {
        "flags": {
            "--detour": "chain it through another outbound",
            "--interface": "an AmneziaWG config on an interface of its own",
            "--userspace": "an AmneziaWG config in wireproxy",
        }
    },
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
    "proxy pin": {
        "args": lambda: {t: d for t, d in {**_outbound_choices(), **_group_choices()}.items() if t not in _outbound_disabled()},
        "flags": {"--in": "hold a group on one of its members"},
    },
    "proxy unpin": {"flags": {"--in": "let a group pick again"}},
    "proxy groups": {
        "words": {
            "list": "groups, their members, and what each uses",
            "add": "add a group: <tag> [member...]",
            "rm": "remove a group added with groups add",
            "members": "add or remove a group's members",
            "strategy": "how a group picks: failover, urltest or selector",
        }
    },
    "proxy groups add": {
        "args": lambda: {**_outbound_choices(), **_group_choices()},
        "repeat": True,
        "flags": {
            "--sub": "every entry of a subscription",
            "--match": "every outbound whose tag matches a pattern",
            "--strategy": "failover, urltest or selector",
            "--no-failback": "stay on a member until it fails",
            "--interval": "how often members are tested",
        },
    },
    "proxy groups rm": {"args": lambda: {g: "" for g, i in _outbound_groups().items() if i.get("runtime")}},
    "proxy groups members": {"args": lambda: {g: "" for g, i in _outbound_groups().items() if i.get("runtime")}},
    "proxy groups strategy": {"args": lambda: {g: "" for g, i in _outbound_groups().items() if i.get("runtime")}},
    "proxy priority": {"args": lambda: {"list": "the top level in order", **{_s(t): "" for t in _outbound_inventory().get("top") or []}}},
    "proxy mode": {"args": lambda: {"default": f"config default ({_route_mode_default()})", **ROUTE_MODE_LABELS}},
    "proxy subs": {
        "words": {
            "list": "subscription caches",
            "update": "refetch the subscriptions",
            "add": "add a subscription at runtime: [tag] <url, or - for stdin>",
            "rm": "remove a runtime subscription",
            "link": "its URL",
        }
    },
    "proxy rulesets": {"words": {"list": "when each rule set was fetched", "update": "fetch the rule sets now"}},
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
            "add": "pin a host: treat it as blocked",
            "forget": "forget a learned host",
            "exclude": "never touch or learn a host",
            "unpin": "undo add",
            "include": "undo exclude",
            "retry": "give zapret2 another try where it sent the proxy",
            "clear": "forget learned hosts and strategies",
        }
    },
    "zapret auto retry": {"args": lambda: _names(name for name, _ in _zapret_proxied())},
    "zapret auto forget": {"args": lambda: _names(lines(read_shared_text(_zapret_auto_file("zapret-hosts-auto.txt"))))},
    "zapret auto exclude": {"args": lambda: _names(lines(read_shared_text(_zapret_auto_file("zapret-hosts-auto.txt"))))},
    "zapret auto unpin": {"args": lambda: _names(lines(read_shared_text(_zapret_auto_file("zapret-hosts-user.txt"))))},
    "zapret auto include": {"args": lambda: _names(lines(read_shared_text(_zapret_auto_file("zapret-hosts-user-exclude.txt"))))},
    "zapret cutoff": {"words": {"status": "networks this line cuts at 16 KB", "probe": "probe this line again now"}},
    "awg": {
        "words": {
            "list": "profiles and their state",
            "on": "start a profile",
            "off": "stop a profile",
            "toggle": "start a profile if stopped, stop it if running",
            "restart": "restart a profile",
            "add": "add a profile from a .conf or vpn:// link",
            "rm": "remove a profile added with awg add",
        }
    },
    "awg add": {"flags": {"--container": "which container of a vpn:// export"}},
    "awg rm": {"args": lambda: _names(_awg_runtime_profiles())},
    "awg on": {"args": lambda: _names(_awg_profiles())},
    "awg off": {"args": lambda: _names(_awg_profiles())},
    "awg toggle": {"args": lambda: _names(_awg_profiles())},
    "awg restart": {"args": lambda: _names(_awg_profiles())},
    "ssh": {"words": TOGGLE},
    "warp": {"words": TOGGLE, "args": lambda: {t: u for t, u in _warp_devices()} if len(_warp_devices()) > 1 else {}},
    "killswitch": {"words": TOGGLE},
    "tor": {"words": {**TOGGLE, "newnym": "new circuits for new connections"}},
    "tg": {"words": TOGGLE},
    "wl": {
        "words": {
            "list": "creators and joiners and their state",
            "link": "the call link a creator's joiner takes",
            "auth": "replace a creator's login",
            "join": "set the call a joiner joins",
            "new": "drop a creator's call for a new one",
            "on": "start one, or all",
            "off": "stop one, or all",
            "toggle": "start it if stopped, stop it if running",
            "restart": "restart one, or all",
        }
    },
    "wl link": {"args": lambda: _names(w["name"] for w in _wl() if w["role"] == "creator"), "flags": {"--qr": "print a QR code"}},
    "wl auth": {"args": lambda: _names(w["name"] for w in _wl() if w["role"] == "creator")},
    "wl join": {"args": lambda: _names(w["name"] for w in _wl() if w["role"] == "joiner")},
    "wl new": {"args": lambda: _names(w["name"] for w in _wl() if w["role"] == "creator" and not w.get("fixedLink"))},
    **{f"wl {verb}": {"args": lambda: {w["name"]: w["role"] for w in _wl()}} for verb in ("on", "off", "toggle", "restart")},
    "apps": {
        "words": {
            "list": "per-app routing profiles",
            "run": "run a command through a profile",
            "add": "add a profile at runtime",
            "rm": "remove a profile added at runtime",
        }
    },
    "apps add": {"flags": {"--route": "how the app is routed", "--via": "the outbound it goes through"}},
    "apps rm": {"args": lambda: _names(p["name"] for p in _runtime_apps())},
    "apps run": {
        "args": lambda: {
            _s(p["name"]): _s(p.get("outbound") or p.get("route") or "")
            for p in [*_runtime_apps(), *read_json(env("PER_APP_ROUTING_PROFILES_FILE"))]
        },
        "flags": {"--via": "through one outbound, not a profile", "--route": "tun or tproxy, for --via"},
    },
    "inbounds": {
        "words": {
            "list": "server inbounds",
            "link": "client share link",
            "sub": "subscription users, or one user's URL",
            "stats": "traffic per user, listener or exit",
            "online": "who is connected now",
            "users": "users, and adding them at runtime",
            "bind": "put a user on a listener",
            "unbind": "take a user off a listener",
            "add": "add a listener at runtime",
            "rm": "remove a runtime listener",
            "show": "a runtime listener's JSON",
        }
    },
    "inbounds stats": {"flags": {"--by": "user, inbound or outbound"}},
    "inbounds users": {
        "words": {
            "list": "users, their order, address and listeners",
            "add": "add a user at runtime",
            "rm": "remove a runtime user",
            "order": "set a runtime user's order",
        }
    },
    "inbounds users add": {"flags": {"--order": "its serverSource number", "--listener": "a listener to put it on"}},
    "inbounds users rm": {"args": lambda: _inbound_runtime_names("users", "runtime")},
    "inbounds users order": {"args": lambda: _inbound_runtime_names("users", "runtime")},
    "inbounds bind": {"args": lambda: {**_inbound_runtime_names("users"), **_inbound_runtime_names("listeners")}, "repeat": True},
    "inbounds unbind": {"args": lambda: {**_inbound_runtime_names("users"), **_inbound_runtime_names("listeners")}, "repeat": True},
    "inbounds add": {"args": lambda: {t: "" for t in INBOUND_TYPES}, "repeat": True, "flags": INBOUND_ADD_FLAGS},
    "inbounds rm": {"args": lambda: _inbound_runtime_names("listeners", "runtime")},
    "inbounds show": {"args": lambda: _inbound_runtime_names("listeners", "runtime")},
    "inbounds link": {
        "args": _inbound_link_choices,
        "flags": {
            "--qr": "print a QR code",
            "--onion": "the link through the onion service",
            "--variant=": "one of the listener's share variants: --variant=<name>",
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
    if path == "apps add" and rest[-1:] == ["--route"]:
        return _names(APP_ROUTES)
    if path in ("apps run", "apps add") and rest[-1:] == ["--via"]:
        return {
            **(_outbound_choices() if _pin_routes() else {}),
            **_names(_via_outbounds()),
            **({p: "AmneziaWG profile" for p in _awg_profiles()} if env("PER_APP_VIA_PROFILES") == "1" else {}),
        }
    if path == "apps run" and rest[-1:] == ["--route"]:
        return _names(_pin_routes())
    if rest[-1:] in (["--exits"], ["--via"], ["--detour"]):
        return _outbound_choices()
    if rest[-1:] == ["--by"]:
        return _names(STATS_KINDS)
    if rest[-1:] == ["--in"]:
        return _group_choices()
    if rest[-1:] == ["--strategy"]:
        return _names(GROUP_STRATEGIES)
    if rest[-1:] == ["--sub"]:
        return _names(_sub_tags())
    candidates = {}
    if node.get("repeat") or not [w for w in rest if not w.startswith("-")]:
        candidates.update(node.get("words", {}))
        try:
            candidates.update(node["args"]() if "args" in node else {})
        except Exception:
            pass  # Unreadable state costs the values, not the verbs and flags.
    candidates.update((f, d) for f, d in node.get("flags", {}).items() if f not in rest)
    return candidates


# A completion word as a shell may take it: many come from group-writable files, and bash's
# `compgen -W` expands "$(...)" in them as whoever pressed TAB.
COMPLETION_WORD = re.compile(r"[\w.@:+=,/%-]+")


def cmd_complete(*words):
    """The hidden verb the shell completions call. It never fails or speaks."""
    try:
        candidates = _complete_tree(*words)
    except Exception:
        return
    for word, description in candidates.items():
        if not isinstance(word, str) or not COMPLETION_WORD.fullmatch(word):
            continue
        description = _UNPRINTABLE.sub("", str(description or "").replace("\t", " ").replace("\n", " "))
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
    status, out = systemctl("show", "--property=Id,LoadState,ActiveState", "--", *units, capture=True, quiet=True)
    if status:
        return {}  # unread, as when it prints nothing: the front ends show it as unavailable
    # By Id, not position: a block skipped or out of order must not shift states onto other units.
    names = {**{f"{u}.service": u for u in units}, **{u: u for u in units}}
    states = {}
    for block in (out or "").strip().split("\n\n"):
        props = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        unit = names.get(props.get("Id", ""))
        if unit and props.get("LoadState") not in (None, "not-found"):
            states[unit] = props.get("ActiveState", "unknown")
    return states


SNAPSHOT_UNITS = {
    "proxy": "proxy-suite-socks",
    "tproxy": "proxy-suite-tproxy",
    "tun": "proxy-suite-tun",
    "killswitch": "proxy-suite-killswitch",
    "zapret": "proxy-suite-zapret",
}
SUBSCRIPTION_UPDATE = "proxy-suite-subscription-update"
KILL_SWITCH = "proxy-suite-killswitch"
BUSY_STATES = ("activating", "deactivating", "reloading")


def _lift_kill_switch():
    """Stops the kill switch once a global tunnel is stopped on purpose, unless another one still runs."""
    if not svc_exists(KILL_SWITCH):
        return
    tunnels = ["proxy-suite-tun", "proxy-suite-tproxy", *map(_awg_service, _awg_profiles())]
    running = sorted(u for u, s in _unit_states(tunnels).items() if s in ("active", "activating", "reloading"))
    if running:
        print(f"The kill switch stays up for {', '.join(running)}; lift it anyway with: proxy-ctl killswitch off", file=sys.stderr)
        return
    systemctl("stop", KILL_SWITCH)


def _snapshot_units():
    profiles = _awg_profiles()
    # WARP devices have no profile to toggle, but their units can fail (_warp_devices). A wrapper
    # from before WARP_DEVICES: the AmneziaWG unit of the one device there was, if it runs.
    if env("WARP_DEVICES"):
        warp = [u for _, u in _warp_devices() if u not in ALL_SERVICES and u not in map(_awg_service, profiles)]
    else:
        warp = [] if "warp" in profiles else [_awg_service("warp")]
    return [*ALL_SERVICES, SUBSCRIPTION_UPDATE, *map(_awg_service, profiles), *warp, *map(_wl_unit, _wl())]


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
        # With runtime profiles on, `awg add` can add the first one.
        "available": bool(profiles) or env("AWG_RUNTIME_GLOBAL") == "1",
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
    if _autoproxy_unreadable(_autoproxy_dir()):
        return "state not readable"
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
        return str(sum(1 for line in lines(read_shared_text(auto)) if line))
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
    verb = _flip("proxy-suite-socks", verb)
    if verb in ("status", "on", "restart"):
        _toggle("proxy-suite-socks", "proxy", verb)
    elif verb == "off":
        if not svc_exists("proxy-suite-socks"):
            die("proxy is not enabled in this configuration.")
        for svc in ("proxy-suite-tproxy", "proxy-suite-tun"):
            if svc_exists(svc):
                systemctl("stop", svc)
        _lift_kill_switch()
        must("stop", "proxy-suite-socks")
    elif verb == "outbounds":
        cmd_outbounds(*args)
    elif verb == "config":
        _config_export(*args)
    elif verb == "pin":
        cmd_pin(*args)
    elif verb == "unpin":
        cmd_unpin(*args)
    elif verb == "groups":
        cmd_groups(*args)
    elif verb == "priority":
        cmd_priority(*args)
    elif verb == "mode":
        cmd_route_mode(*args)
    elif verb == "subs":
        cmd_subscription(*args)
    elif verb == "rulesets":
        cmd_rulesets(*args)
    elif verb in ("tun", "tproxy"):
        action = _flip(f"proxy-suite-{verb}", *args[:1])
        _toggle(f"proxy-suite-{verb}", f"proxy {verb}", action)
        # A mode stopped on purpose lifts the kill switch; one that fails leaves it up.
        if action == "off":
            _lift_kill_switch()
    elif verb == "clash-broker":
        # proxy-suite-clash-api's ExecStart.
        _clash_broker_serve()
    elif verb == "auto":
        cmd_proxy_auto(*args)
    elif verb in ("probe", "learn", "forget", "relearn", "queue", "learned"):
        cmd_proxy_auto(verb, *args)
    else:
        usage("proxy [status|on|off|toggle|restart|outbounds|groups|priority|pin|unpin|mode|subs|rulesets|tun|tproxy|auto|config]")


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
        container = ""
        if "--container" in args:
            i = args.index("--container")
            container = args[i + 1] if i + 1 < len(args) else ""
            del args[i : i + 2]
            if not container:
                usage("proxy outbounds add [tag] <vpn://…|file.conf|-> [--container <name>]")
        awg_kind = ""
        for flag in ("--interface", "--userspace"):
            if flag in args:
                if awg_kind:
                    die("Pick one of --interface and --userspace.")
                awg_kind = flag[2:]
                args.remove(flag)
        _runtime_entry_add("outbound", *args, detour=detour, container=container, awg_kind=awg_kind)
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


def _local_proxy_login():
    """(user, password) the loopback listeners take with listener.auth, else None.

    From the proxychains config the socks start script writes for it, which root and the
    userControl group read; without auth that file names no login.
    """
    try:
        with open(env("PROXYCHAINS_CONFIG"), encoding="utf-8") as f:
            for line in f:
                fields = line.split()
                if len(fields) == 5 and fields[0] == "socks5":
                    return fields[3], fields[4]
    except (OSError, UnicodeError):
        pass
    return None


def _clash_secret():
    """The socks start script's secret for this run: root only (the broker hands the rest out)."""
    try:
        with open(_runtime_file("clash-secret"), encoding="utf-8") as f:
            return f.read().strip()
    except (OSError, UnicodeError):
        return None


def _clash(method, path, body=None, timeout=10):
    """(HTTP status, JSON body or None) from the backend's Clash API; status 0 when unreachable.

    Root reads the secret and asks the API itself; anyone else asks proxy-suite-clash-api,
    which lets a userControl group's member make the requests their scopes allow.
    """
    secret = _clash_secret()
    broker = env("CLASH_BROKER")
    if secret is None and broker and os.path.exists(broker):
        return _clash_via_broker(broker, method, path, body, timeout)
    return _clash_direct(method, path, body, timeout, secret)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """The Clash API never redirects: one that did would lead the broker past its checks."""

    def redirect_request(self, *_):
        return None


def _clash_direct(method, path, body, timeout, secret):
    # The API is on loopback: never through the shell's HTTP(S)_PROXY.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)
    data = None if body is None else json.dumps(body).encode()
    headers = {"Content-Type": "application/json"}
    # Without the secret the API answers 401, which reads as no API.
    if secret is not None:
        headers["Authorization"] = f"Bearer {secret}"
    try:
        # Building the request is part of reaching the API: an unset or malformed
        # CLASH_API is "unreachable", not a traceback out of `status` or `where`.
        request = urllib.request.Request(f"{env('CLASH_API')}{path}", data=data, method=method, headers=headers)
        with opener.open(request, timeout=timeout) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return 0, None
        status, raw = e.code, e.read()
    except (OSError, ValueError, http.client.HTTPException):
        return 0, None
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, None


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        # A Unix socket whose listen queue is full refuses at once with EAGAIN, timeout or
        # not: a burst of callers (a whole outbounds test) is waited out, not read as no API.
        deadline = time.monotonic() + (self.timeout or 0)
        while True:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            try:
                sock.connect(self._path)
            except BlockingIOError:
                sock.close()
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
                continue
            except BaseException:
                sock.close()
                raise
            self.sock = sock
            return


def _clash_via_broker(broker, method, path, body, timeout):
    conn = _UnixHTTPConnection(broker, timeout + 5)
    try:
        conn.request(method, path, body=None if body is None else json.dumps(body), headers={"Content-Type": "application/json"})
        response = conn.getresponse()
        status, raw = response.status, response.read()
    except (OSError, http.client.HTTPException):
        return 0, None
    finally:
        conn.close()
    # The broker's own "not the API": unreachable, as a direct call would read.
    if status == 502:
        return 0, None
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, None


# --- the Clash API broker -------------------------------------------------------
#
# proxy-suite-clash-api: the Clash API's secret is root's; members of the userControl groups
# reach the API through this, and only for what their scopes cover. A bare secret would
# let any of them switch what everyone dials and see everyone's connections.

CLASH_TEST_SELECTOR = "proxy-suite-test"
# What delay tests fetch when the start script names no proxy.urlTest.url.
URL_TEST_DEFAULT = "https://www.gstatic.com/generate_204"
CLASH_BROKER_MAX_BODY = 64 * 1024
# Any local user may connect: a caller that stalls, or opens many, holds no thread for long
# and never all of them.
CLASH_BROKER_TIMEOUT = 15
CLASH_BROKER_MAX_CLIENTS = 64


def _peer_uid(sock):
    import struct

    creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", creds)[1]


def _broker_scopes(uid):
    """The scopes a caller holds, "*" for root; None when it is in no userControl group."""
    if uid == 0:
        return {"*"}
    import grp
    import pwd

    try:
        user = pwd.getpwuid(uid)
        gids = os.getgrouplist(user.pw_name, user.pw_gid)
    except (KeyError, OSError):
        return None
    try:
        table = json.loads(env("USER_CONTROL_GROUPS") or "{}")
    except ValueError:
        table = {}
    held = None
    for gid in gids:
        try:
            name = grp.getgrgid(gid).gr_name
        except KeyError:
            continue
        if isinstance(table.get(name), list):
            held = (held or set()) | set(table[name])
    return held


def _broker_test_urls():
    """The URLs a delay test through the broker may fetch: urlTest.url, as proxy-ctl reads it."""
    test = read_json_or(_runtime_file("outbound-test.json"), {})
    return {_s(test.get("url") or URL_TEST_DEFAULT), _s(_outbound_inventory().get("url") or URL_TEST_DEFAULT)}


def _broker_allows(method, path, scopes, query=""):
    """Whether a caller holding `scopes` may make this request; `path` and its `query` apart.

    Only what proxy-ctl asks: reads and delay tests for any member, the download test's own
    selector too, switching the others with `routing`, live connections with `secrets`.
    Nothing else: not closing connections, the config, the logs or the traffic stream.
    A delay test fetches the configured test URL only: any other would have the backend
    fetch what the caller names, LAN addresses included.
    """
    if "*" in scopes:
        return True
    parts = path.split("/")[1:] if path.startswith("/") else None
    # Names as the API's router reads them: a "%2F" or "%2E%2E" in one must not turn
    # /proxies/<name> into another endpoint once decoded and cleaned.
    if not parts or any(not p or "/" in (u := urllib.parse.unquote(p)) or u in (".", "..") for p in parts):
        return False
    if method == "GET":
        return (
            parts == ["proxies"]
            or (parts[0] == "proxies" and len(parts) == 2)
            or (
                parts[0] in ("proxies", "group")
                and len(parts) == 3
                and parts[2] == "delay"
                and len(urls := urllib.parse.parse_qs(query, keep_blank_values=True).get("url") or []) == 1
                and urls[0] in _broker_test_urls()
            )
            or (parts == ["connections"] and "secrets" in scopes)
        )
    if method == "PUT" and parts[0] == "proxies" and len(parts) == 2:
        return urllib.parse.unquote(parts[1]) == CLASH_TEST_SELECTOR or "routing" in scopes
    return False


def _clash_broker_serve():
    """proxy-suite-clash-api's ExecStart: an HTTP server on a Unix socket in front of the API."""
    path = env("CLASH_BROKER")
    if not path:
        die("CLASH_BROKER is not set.")
    server = _clash_broker_server(path)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server.serve_forever()


def _clash_broker_server(path):
    import http.server
    import socketserver
    import threading

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"
        timeout = CLASH_BROKER_TIMEOUT

        def _reply(self, status, payload):
            raw = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _handle(self, method):
            uid = _peer_uid(self.connection)
            scopes = _broker_scopes(uid)
            parts = urllib.parse.urlsplit(self.path)
            if scopes is None or not _broker_allows(method, parts.path, scopes, parts.query):
                # repr: the path is the caller's, escape sequences and all.
                print(f"proxy-suite-clash-api: refused uid {uid}: {method} {parts.path!r}", file=sys.stderr)
                return self._reply(403, {"message": "not allowed for your userControl scopes"})
            body = None
            if method == "PUT":
                try:
                    length = int(self.headers.get("Content-Length") or 0)
                except ValueError:
                    length = -1
                if not 0 <= length <= CLASH_BROKER_MAX_BODY:
                    return self._reply(400, {"message": "bad request body"})
                try:
                    body = json.loads(self.rfile.read(length) or b"null")
                except ValueError:
                    return self._reply(400, {"message": "bad request body"})
            target = parts.path + (f"?{parts.query}" if parts.query else "")
            status, answer = _clash_direct(method, target, body, 30, _clash_secret())
            # 502: the API itself could not be reached, which the client reads as no API.
            self._reply(status or 502, answer)

        def do_GET(self):
            self._handle("GET")

        def do_PUT(self):
            self._handle("PUT")

        def log_message(self, *_):
            pass

    class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True
        slots = threading.BoundedSemaphore(CLASH_BROKER_MAX_CLIENTS)
        # socketserver listens with a queue of 5: the rest of a burst that arrives while
        # this thread checks a caller's groups was refused before it could be accepted.
        request_queue_size = CLASH_BROKER_MAX_CLIENTS

        def verify_request(self, request, client_address):
            # Someone in no userControl group is closed on before sending a byte.
            try:
                return _broker_scopes(_peer_uid(request)) is not None
            except OSError:
                return False

        def process_request(self, request, client_address):
            # A full house turns the next one away at once: waiting here would stall accept().
            if not self.slots.acquire(blocking=False):
                self.shutdown_request(request)
                return
            try:
                super().process_request(request, client_address)
            except BaseException:
                self.slots.release()
                raise

        def process_request_thread(self, request, client_address):
            try:
                super().process_request_thread(request, client_address)
            finally:
                self.slots.release()

    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = Server(path, Handler)
    # Anyone may connect: whom the broker answers, and with what, it decides per request.
    os.chmod(path, 0o666)
    return server


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


def _probe_login():
    """(user, password) of the probe and test listeners, drawn on each start (they reach any
    exit, so not every local user may); None when unreadable."""
    try:
        user, sep, password = read_text(_runtime_file("probe-login")).strip().partition(":")
    except OSError:
        return None
    return (user, password) if sep and user and password else None


def _timed_download(port):
    """Megabits per second through the test listener, None when nothing arrived.

    A CONNECT tunnel by hand, so no proxy variable in the environment can send it
    anywhere else.
    """
    conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=TEST_DOWNLOAD_SECONDS)
    login = _probe_login()
    auth = {"Proxy-Authorization": "Basic " + base64.b64encode(":".join(login).encode()).decode()} if login else {}
    conn.set_tunnel(TEST_DOWNLOAD_HOST, headers=auth)
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
            return _test_delay(backend[tag], test.get("url") or URL_TEST_DEFAULT)
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


def _outbound_tree(inventory):
    """[(depth, tag, parent group or "")] in display order: the top level, each group's members under it.

    An inventory from before groups has no "top": every tag is top level then.
    """
    groups = inventory.get("groups") or {}
    rows = []

    def walk(tag, depth, parent, path):
        rows.append((depth, tag, parent))
        if tag in groups and tag not in path:
            for member in groups[tag].get("members") or []:
                walk(_s(member), depth + 1, tag, (*path, tag))

    for tag in inventory.get("top") or inventory.get("tags") or []:
        walk(_s(tag), 0, "", ())
    return rows


def _outbounds_list():
    _require_outbound_inventory()
    inventory = _outbound_inventory()
    pinned = _s(inventory.get("pinned") or "")
    sources = inventory.get("sources") or {}
    detours = inventory.get("detours") or {}
    excluded = set(inventory.get("excluded") or [])
    disabled = set(_outbound_disabled())
    groups = inventory.get("groups") or {}
    # One Clash API read for every group's pick, only when there are groups.
    nows = _group_nows() if groups else {}
    current = _outbound_current()
    down = {t for t, m in (_group_state().get("members") or {}).items() if isinstance(m, dict) and m.get("up") is False}
    reputation = _reputation_by_tag()

    print(f"Selection: {_s(inventory.get('selection') or 'first')}")
    print(f"Pinned:    {pinned or '(none)'}")
    if current:
        print(f"Current:   {current}")
    print()
    # The reputation column only once the autoProxy prober has checked some exit.
    rep = (lambda tag: f"{reputation.get(tag, '-'):<16} ") if reputation else (lambda tag: "")
    print(f"  {'TAG':<34} {'REPUTATION':<16} SOURCE" if reputation else f"  {'TAG':<34} SOURCE")
    for depth, tag, parent in _outbound_tree(inventory):
        if parent:
            info = groups.get(parent) or {}
            chosen, live = _s(info.get("pinned") or ""), nows.get(parent, "")
        else:
            chosen, live = pinned, current
        mark = " "
        if tag == chosen:
            mark = "*"
        elif not chosen and tag == live:
            mark = ">"
        elif tag in disabled:
            mark = "-"
        if tag in groups:
            info = groups[tag]
            source = f"group: {_s(info.get('strategy') or 'failover')}"
            notes = [f"pinned {_s(info['pinned'])}"] if info.get("pinned") else [f"using {nows[tag]}"] if nows.get(tag) else []
        else:
            source = _s(sources.get(tag) or "-")
            notes = [f"via {_s(detours[tag])}"] if tag in detours else []
        if tag in disabled:
            notes.append("disabled")
        elif tag in down:
            notes.append("down")
        elif not parent and tag in excluded:
            notes.append("never picked")
        name = "  " * depth + tag
        print(f" {mark}{name:<34} {rep(tag)}{', '.join([source, *notes])}")


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


def _pin_args(args, verb):
    """(tag, group) from `pin [tag] [--in <group>]` or `unpin [--in <group>]`."""
    args = list(args)
    group = ""
    if "--in" in args:
        i = args.index("--in")
        group = args[i + 1] if i + 1 < len(args) else ""
        del args[i : i + 2]
        if not group:
            usage(f"proxy {verb} {'[tag] ' if verb == 'pin' else ''}--in <group>")
        if group not in _outbound_groups():
            die(f"Unknown group: {group}")
    for arg in args:
        if arg.startswith("-"):
            die(f"Unknown option: {arg}")
    if verb == "unpin" and args:
        usage("proxy unpin [--in <group>]")
    if len(args) > 1:
        usage("proxy pin [tag] [--in <group>]")
    return (args[0] if args else ""), group


def _pick_pin(choices, header):
    status, tag = _run(
        ["fzf", "--prompt=pin> ", "--height=40%", "--reverse", f"--header={header}"],
        capture=True,
        stdin="".join(f"{t}\n" for t in choices),
    )
    tag = tag.strip("\n")
    # Dismissed.
    return "" if status else tag


def unit_escape(text):
    """systemd-escape, in-process: proxy-suitectl hosts have no systemd to run it from."""
    out = []
    for i, byte in enumerate(text.encode()):
        char = chr(byte)
        if char == "/":
            out.append("-")
        elif (char == "." and i == 0) or not (char.isascii() and (char.isalnum() or char in ":_.")):
            out.append(f"\\x{byte:02x}")
        else:
            out.append(char)
    return "".join(out)


def _start_pin_unit(instance):
    unit = "proxy-suite-outbound-pin@" + unit_escape(instance)
    if systemctl("start", f"{unit}.service")[0]:
        die(f"Failed - see: proxy-ctl logs {unit}")


def cmd_pin(*args):
    tag, group = _pin_args(args, "pin")
    if not tag:
        if not (os.isatty(0) and os.isatty(1)):
            usage("proxy pin <tag> [--in <group>]")
        _require_outbound_inventory()
        disabled = _outbound_disabled()
        if group:
            info = _outbound_groups()[group]
            choices = [m for m in info.get("members") or [] if m not in disabled and m != "block"]
            header = f"{group} pinned: {_s(info.get('pinned') or '') or '(none)'}"
        else:
            choices = [t for t in _outbound_tags() + list(_outbound_groups()) if t not in disabled]
            header = f"pinned: {_s(_outbound_inventory().get('pinned') or '') or '(none)'}"
        tag = _pick_pin(choices, header)
        if not tag:
            return
    # The inventory too: the marker sits in a dir only root and the group can look into.
    if os.path.exists(_outbound_disabled_marker(tag)) or tag in _outbound_disabled():
        die(f"Outbound '{tag}' is disabled; enable it first: proxy-ctl proxy outbounds enable {tag}")
    if group:
        if tag not in (_outbound_groups()[group].get("members") or []):
            die(f"'{tag}' is not in group '{group}'. See: proxy-ctl proxy groups")
        _start_pin_unit(f"{group}/{tag}")
        print(f"Pinned in {group}: {tag}")
        return
    _start_pin_unit(tag)
    print(f"Pinned: {tag}")


def cmd_unpin(*args):
    _, group = _pin_args(args, "unpin")
    if group:
        _start_pin_unit(f"{group}/")
        print(f"Unpinned in {group}: it picks again.")
        return
    if systemctl("start", "proxy-suite-outbound-unpin.service")[0]:
        die("Failed - see: proxy-ctl logs proxy-suite-outbound-unpin")
    print("Unpinned: the configured selection picks again.")


# --- outbound groups ----------------------------------------------------------
#
# proxy.groups and runtime <tag>.group files (in the runtime outbound dir) are resolved by the
# start script, which lists them in the inventory: strategy, members in order, and the pin.
# proxy-suite-outbound-groups runs `proxy groups watch` for the failover ones.

GROUP_STRATEGIES = ("failover", "urltest", "selector")
# A member is down after this many failed tests in a row, or after one that follows a hint.
GROUP_MISSES_DOWN = 2
# A member that was down is up again after this many passes in a row.
GROUP_PASSES_UP = 3
GROUP_TEST_TIMEOUT_MS = 5000


def _outbound_groups():
    """{group: {strategy, failback, interval, members, pinned, runtime}}, as the running backend took them."""
    groups = _outbound_inventory().get("groups") or {}
    return groups if isinstance(groups, dict) else {}


def _groups_dir():
    """proxy-suite-outbound-groups' runtime dir: health/ for hints, groups-state.json for the front ends."""
    return os.path.join(runtime_dir(), "proxy-suite-outbound-groups")


def _group_state():
    """What the watcher last saw: {"groups": {group: {"now"}}, "members": {tag: {"up", "since"}}}."""
    state = read_json_or(os.path.join(_groups_dir(), "groups-state.json"), {})
    return state if isinstance(state, dict) else {}


def _group_nows():
    """{group: the member it uses now} for every sing-box group, the top-level "proxy" included."""
    status, body = _clash("GET", "/proxies", timeout=5)
    proxies = body.get("proxies") if status == 200 and isinstance(body, dict) else None
    if not isinstance(proxies, dict):
        return {}
    return {_s(name): _s(p["now"]) for name, p in proxies.items() if isinstance(p, dict) and p.get("now")}


def _duration(text, fallback=30.0):
    """Seconds in a Go duration ("30s", "3m", "1h30m")."""
    total = 0.0
    for number, unit in re.findall(r"(\d+(?:\.\d+)?)(ms|s|m|h)", str(text or "")):
        total += float(number) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[unit]
    return total or fallback


class GroupWatch:
    """Moves failover groups, and "failover" selection, to the first member that works.

    Every group is tested on its interval; a hint (a file a watchdog touches in health/, named
    after the outbound it saw fail) tests that outbound at once. A member is down after
    GROUP_MISSES_DOWN failed tests in a row, or one failed test right after a hint; one that was
    down is up again after GROUP_PASSES_UP passes. With failback the group goes back to an
    earlier member once it is up; without, it stays until its member goes down. Pinned groups
    are left alone. urltest groups are sing-box's to move; a hint only makes them test now.
    """

    def __init__(self, clash=None, clock=time.monotonic, wall=time.time):
        self.clash = clash or _clash
        self.clock = clock
        self.wall = wall
        self.health = {}  # tag -> {"up", "misses", "passes", "since"}
        self.due = {}  # group -> clock time of its next test
        self.seen_hints = {}  # tag -> hint file mtime already acted on

    @staticmethod
    def watched(inventory):
        """{group: info} to watch, with "proxy" standing for the top level when its selection is failover."""
        groups = {g: dict(v) for g, v in (inventory.get("groups") or {}).items() if isinstance(v, dict)}
        if inventory.get("selection") == "failover":
            skip = set(inventory.get("excluded") or []) | set(inventory.get("disabled") or [])
            groups["proxy"] = {
                "strategy": "failover",
                "failback": True,
                "interval": "30s",
                "members": [t for t in inventory.get("top") or [] if t not in skip],
                "pinned": _s(inventory.get("pinned") or ""),
            }
        return groups

    @staticmethod
    def inner_first(groups):
        """Group names with every group they contain before them."""
        order = []

        def visit(name, path):
            if name in order or name in path:
                return
            for member in groups[name].get("members") or []:
                if member in groups:
                    visit(member, path + [name])
            order.append(name)

        for name in groups:
            visit(name, [])
        return order

    def test(self, tag, url):
        query = urllib.parse.urlencode({"url": url, "timeout": GROUP_TEST_TIMEOUT_MS})
        status, body = self.clash("GET", f"/proxies/{urllib.parse.quote(tag, safe='')}/delay?{query}", timeout=GROUP_TEST_TIMEOUT_MS / 1000 + 3)
        return status == 200 and isinstance(body, dict) and "delay" in body

    def record(self, tag, ok, hinted=False):
        h = self.health.setdefault(tag, {"up": True, "misses": 0, "passes": 0, "since": self.wall()})
        if ok:
            h["misses"], h["passes"] = 0, h["passes"] + 1
            if not h["up"] and h["passes"] >= GROUP_PASSES_UP:
                h["up"], h["since"] = True, self.wall()
        else:
            h["passes"], h["misses"] = 0, h["misses"] + 1
            if h["up"] and (hinted or h["misses"] >= GROUP_MISSES_DOWN):
                h["up"], h["since"] = False, self.wall()

    def up(self, tag):
        return self.health.get(tag, {}).get("up", True)

    def pick(self, info, now, disabled):
        """The member the group should use, or None to leave it where it is."""
        if info.get("pinned"):
            return None
        members = [m for m in info.get("members") or [] if m != "block" and m not in disabled]
        working = [m for m in members if self.up(m)]
        if not working:
            return None  # nothing works: moving would only flap
        if not info.get("failback", True) and now in working:
            return None
        return working[0] if working[0] != now else None

    def hints(self):
        """Tags whose hint file changed since the last look."""
        directory = os.path.join(_groups_dir(), "health")
        fresh = []
        try:
            names = os.listdir(directory)
        except OSError:
            return fresh
        seen = {}
        for name in names:
            try:
                mtime = os.lstat(os.path.join(directory, name)).st_mtime
            except OSError:
                continue
            if self.seen_hints.get(name) != mtime and name in self.seen_hints:
                fresh.append(name)
            seen[name] = mtime
        # Only what is there now: names removed since are forgotten, not kept for good.
        self.seen_hints = seen
        return fresh

    def step(self, inventory, hinted=()):
        """One pass: test what is due or hinted, move what should move. The switches made, as (group, member)."""
        groups = self.watched(inventory)
        if not groups:
            return []
        url = _s(inventory.get("url") or URL_TEST_DEFAULT)
        disabled = set(inventory.get("disabled") or [])
        now_clock = self.clock()
        # Anyone may leave a hint: only a watched member's is worth a test and a place in the state.
        hinted = set(hinted) & {m for info in groups.values() for m in info.get("members") or [] if m != "block"}
        results = {}
        # A hinted tag is tested at once, and so is everything around it.
        for tag in hinted:
            if tag not in results:
                results[tag] = self.test(tag, url)
                self.record(tag, results[tag], hinted=True)
        switches = []
        nows = None
        for name in self.inner_first(groups):
            info = groups[name]
            members = [m for m in info.get("members") or [] if m != "block"]
            touched = bool(hinted & set(members))
            if info.get("strategy") == "urltest":
                if touched:
                    query = urllib.parse.urlencode({"url": url, "timeout": GROUP_TEST_TIMEOUT_MS})
                    self.clash("GET", f"/group/{urllib.parse.quote(name, safe='')}/delay?{query}", timeout=GROUP_TEST_TIMEOUT_MS / 1000 + 3)
                continue
            if info.get("strategy") != "failover":
                continue
            if not touched and self.due.get(name, 0) > now_clock:
                continue
            self.due[name] = now_clock + _duration(info.get("interval"))
            for tag in members:
                if tag in disabled:
                    continue
                if tag not in results:
                    results[tag] = self.test(tag, url)
                    self.record(tag, results[tag])
            if nows is None:
                nows = _group_nows()
            target = self.pick(info, nows.get(name, ""), disabled)
            if target is None:
                continue
            status, _ = self.clash("PUT", f"/proxies/{urllib.parse.quote(name, safe='')}", {"name": target})
            if 200 <= status < 300:
                print(f"{name}: {nows.get(name) or '-'} -> {target}", file=sys.stderr)
                nows[name] = target
                switches.append((name, target))
        return switches

    def state(self, nows):
        return {
            "updated": self.wall(),
            "groups": {g: {"now": n} for g, n in nows.items()},
            "members": {t: {"up": h["up"], "since": h["since"]} for t, h in self.health.items()},
        }

    def write_state(self):
        path = os.path.join(_groups_dir(), "groups-state.json")
        try:
            fd, tmp = tempfile.mkstemp(dir=_groups_dir(), prefix=".groups-state.")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(self.state(_group_nows()), f)
                os.fchmod(f.fileno(), 0o644)
            os.replace(tmp, path)
        except OSError:
            pass

    def run(self):
        health = os.path.join(_groups_dir(), "health")
        # Watchdogs run as other users (the WARP tunnel as the service user). A hint only makes
        # this test sooner, so they may leave one; nobody may list or remove another's. As
        # root, the unit makes it first, for the service user's group alone.
        try:
            os.mkdir(health)
            os.chmod(health, 0o1733)
        except FileExistsError:
            pass
        self.hints()  # what is there already is no news
        last_state = 0.0
        while True:
            inventory = _outbound_inventory()
            fresh = self.hints()
            if inventory:
                self.step(inventory, fresh)
                if fresh or self.clock() - last_state >= 10:
                    self.write_state()
                    last_state = self.clock()
            time.sleep(1)


def _group_file(tag):
    return os.path.join(_runtime_dir("outbound"), f"{tag}.group")


def _read_group_file(tag):
    try:
        data = json.loads(read_shared_text(_group_file(tag), RUNTIME_APP_MAX_BYTES))
    except FileNotFoundError:
        die(f"'{tag}' is not a group added with proxy-ctl; declared groups change in the configuration.")
    except (OSError, ValueError):
        denied(_group_file(tag))
    return data if isinstance(data, dict) else {}


def _group_lock(tag):
    """_file_lock over a runtime group's file; dies first for a tag that is no such group."""
    _check_tag_shape("group", tag)
    if not os.path.lexists(_group_file(tag)):
        _read_group_file(tag)  # says why
    return _file_lock(_group_file(tag))


def _write_group_file(tag, data):
    path = _group_file(tag)
    try:
        _spool_write(path, json.dumps(data, indent=2) + "\n")
    except OSError:
        denied(path, "write")


def _group_contains(groups, outer, tag, seen=()):
    """Whether group outer holds tag, however deep."""
    for member in (groups.get(outer) or {}).get("members") or []:
        if member == tag or (member in groups and member not in seen and _group_contains(groups, member, tag, (*seen, outer))):
            return True
    return False


def _group_check_members(tag, members):
    groups = _outbound_groups()
    for member in members:
        if member == tag or (member in groups and _group_contains(groups, member, tag)):
            die(f"'{member}' contains '{tag}': a group cannot hold itself.")
        if member not in _outbound_tags() and member not in groups:
            print(f"warning: '{member}' is not an outbound or group right now; the group leaves it out until it is.", file=sys.stderr)


def _group_options(args, shape):
    """(positional, {strategy, failback, interval, subscriptions, match}) from group add flags."""
    rest, opts = [], {"subscriptions": [], "match": []}
    it = iter(args)
    for arg in it:
        if arg == "--strategy":
            opts["strategy"] = next(it, "")
            if opts["strategy"] not in GROUP_STRATEGIES:
                die(f"--strategy is one of: {', '.join(GROUP_STRATEGIES)}")
        elif arg == "--no-failback":
            opts["failback"] = False
        elif arg == "--interval":
            opts["interval"] = next(it, "")
            if not re.fullmatch(r"(\d+(\.\d+)?(ms|s|m|h))+", opts["interval"]):
                die("--interval is a Go duration: 30s, 1m, 1m30s.")
        elif arg == "--sub":
            opts["subscriptions"].append(next(it, ""))
        elif arg == "--match":
            opts["match"].append(next(it, ""))
        elif arg.startswith("-"):
            die(f"Unknown option: {arg}")
        else:
            rest.append(arg)
    if "" in opts["subscriptions"] + opts["match"]:
        usage(shape)
    return rest, opts


GROUP_ADD_SHAPE = "proxy groups add <tag> [member...] [--sub <subscription>]... [--match <pattern>]... [--strategy failover|urltest|selector] [--no-failback] [--interval <duration>]"


def _groups_list():
    _require_outbound_inventory()
    groups = _outbound_groups()
    if not groups:
        print("No groups. Add one: proxy-ctl proxy groups add <tag> <member...>")
        return
    nows = _group_nows()
    members_state = _group_state().get("members") or {}
    disabled = set(_outbound_disabled())
    for name, info in groups.items():
        strategy = _s(info.get("strategy") or "failover")
        notes = [strategy]
        if strategy == "failover" and info.get("failback") is False:
            notes.append("no failback")
        if info.get("pinned"):
            notes.append(f"pinned: {_s(info['pinned'])}")
        elif nows.get(name):
            notes.append(f"using {nows[name]}")
        if info.get("runtime"):
            notes.append("runtime")
        print(f"{name}  ({', '.join(notes)})")
        for member in info.get("members") or []:
            mark = "*" if member == info.get("pinned") else ">" if member == nows.get(name) else " "
            state = []
            if member in disabled:
                state.append("disabled")
            elif (members_state.get(member) or {}).get("up") is False:
                state.append("down")
            print(f" {mark} {member}{'  (' + ', '.join(state) + ')' if state else ''}")


def cmd_groups(verb="list", *args):
    if verb == "list":
        _groups_list()
    elif verb == "watch":
        # proxy-suite-outbound-groups' ExecStart.
        GroupWatch().run()
    elif verb == "add":
        rest, opts = _group_options(args, GROUP_ADD_SHAPE)
        if not rest:
            usage(GROUP_ADD_SHAPE)
        tag, members = rest[0], rest[1:]
        _check_runtime_tag("outbound", tag)
        if tag in _outbound_groups() or os.path.lexists(_group_file(tag)):
            die(f"A group named '{tag}' already exists.")
        if not members and not opts["subscriptions"] and not opts["match"]:
            die("A group needs members, a --sub or a --match.")
        _group_check_members(tag, members)
        with _file_lock(_group_file(tag)):
            if os.path.lexists(_group_file(tag)):
                die(f"A group named '{tag}' already exists.")
            _write_group_file(tag, {"outbounds": members, **opts})
        _runtime_reload()
        print(f"Added group: {tag}")
    elif verb == "rm":
        if len(args) != 1:
            usage("proxy groups rm <tag>")
        tag = args[0]
        # Locked: a members or strategy edit under way would write it back.
        with _group_lock(tag) as held:
            _read_group_file(tag)
            try:
                os.unlink(_group_file(tag))
            except OSError:
                denied(_group_file(tag), "remove")
            # Only the holder's: one waiting on it relocks the new one (_file_lock).
            if held:
                with contextlib.suppress(OSError):
                    os.unlink(_lock_path(_group_file(tag)))
        _runtime_reload()
        print(f"Removed group: {tag}")
    elif verb == "members":
        if len(args) < 3 or args[1] not in ("add", "rm"):
            usage("proxy groups members <tag> add|rm <member...>")
        tag, action, names = args[0], args[1], list(args[2:])
        with _group_lock(tag):
            data = _read_group_file(tag)
            members = [m for m in data.get("outbounds") or [] if isinstance(m, str)]
            if action == "add":
                _group_check_members(tag, names)
                members += [n for n in names if n not in members]
            else:
                missing = [n for n in names if n not in members]
                if missing:
                    die(f"Not listed in '{tag}': {', '.join(missing)}")
                members = [m for m in members if m not in names]
                if not members and not data.get("subscriptions") and not data.get("match"):
                    die(f"That would leave '{tag}' empty; remove the group instead: proxy-ctl proxy groups rm {tag}")
            data["outbounds"] = members
            _write_group_file(tag, data)
        _runtime_reload()
        print(f"{tag}: {', '.join(members) or '(members from --sub/--match only)'}")
    elif verb == "strategy":
        if len(args) != 2 or args[1] not in GROUP_STRATEGIES:
            usage(f"proxy groups strategy <tag> {'|'.join(GROUP_STRATEGIES)}")
        tag, strategy = args
        with _group_lock(tag):
            data = _read_group_file(tag)
            data["strategy"] = strategy
            _write_group_file(tag, data)
        _runtime_reload()
        print(f"{tag}: {strategy}")
    else:
        usage("proxy groups [list|add|rm|members|strategy]")


# --- priority -----------------------------------------------------------------
#
# proxy.priority, and runtime overrides in priority.json in the runtime outbound dir: lower
# goes first, for the top level and for group members pulled in by --sub or --match.


def _priority_file():
    return os.path.join(_runtime_dir("outbound"), "priority.json")


def _runtime_priority():
    return {k: v for k, v in _read_shared_json(_priority_file()).items() if isinstance(v, int)}


def cmd_priority(*args):
    if not args or args[0] == "list":
        _require_outbound_inventory()
        inventory = _outbound_inventory()
        priority = inventory.get("priority") or {}
        print("Top level, in order:")
        # An inventory from before groups has no "top": every tag is top level then.
        for tag in inventory.get("top") or inventory.get("tags") or []:
            rank = priority.get(tag)
            print(f"  {'-' if rank is None else rank:>6}  {tag}")
        return
    if len(args) != 2:
        usage("proxy priority [list] | <tag> <number>|up|down|--clear")
    tag, value = args
    if tag not in _outbound_tags() and tag not in _outbound_groups():
        die(f"Unknown outbound or group: {tag}")
    path = _priority_file()
    # Read to write under one lock: the GUI and a terminal at once would drop one's change.
    with _file_lock(path):
        data = _runtime_priority()
        if value == "--clear":
            data.pop(tag, None)
        elif value in ("up", "down"):
            # Every top-level entry numbered in the new order, 10 apart: room to slot one in by hand.
            top = [_s(t) for t in _outbound_inventory().get("top") or []]
            if tag not in top:
                die(f"'{tag}' is not at the top level; a group orders its members itself.")
            i = top.index(tag)
            j = i - 1 if value == "up" else i + 1
            if not 0 <= j < len(top):
                print(f"{tag} is already {'first' if value == 'up' else 'last'}.")
                return
            top[i], top[j] = top[j], top[i]
            data.update({t: 10 * (n + 1) for n, t in enumerate(top)})
        elif re.fullmatch(r"-?\d+", value):
            data[tag] = int(value)
        else:
            usage("proxy priority <tag> <number>|up|down|--clear")
        try:
            _spool_write(path, json.dumps(data, indent=2, sort_keys=True) + "\n")
        except OSError:
            denied(path, "write")
    _runtime_reload()
    print(f"{tag}: {'default order' if value == '--clear' else 'moved ' + value if value in ('up', 'down') else value}")


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
    exts = (".url", ".json", ".awg") if kind == "outbound" else (".url",)
    return sorted(os.path.splitext(n)[0] for n in names if n.endswith(exts))


def _runtime_path(kind, tag):
    """The file behind a runtime entry, or its .url spelling when there is none."""
    for ext in (".url", ".json", ".awg") if kind == "outbound" else (".url",):
        path = os.path.join(_runtime_dir(kind), tag + ext)
        if os.path.exists(path):
            return path
    return os.path.join(_runtime_dir(kind), f"{tag}.url")


def _local_file_keys(ob):
    """What in an outbound points the root backend at a local file or program.

    The start script ignores a runtime outbound that has any (localFileKeysJq there).
    """
    found = {"type: tor"} if ob.get("type") == "tor" else set()
    stack = [ob]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            for key, child in item.items():
                k = str(key).lower()
                # Non-ASCII: Go's JSON decoding folds "ſ" to s and "K" to k (localFileKeysJq).
                if (
                    not k.isascii()
                    or k.endswith(("file", "directory"))
                    or (k.endswith("path") and k != "path")
                    or k in ("masterkeylog", "torrc", "extra_args")
                ):
                    found.add(k)
                stack.append(child)
        elif isinstance(item, list):
            stack.extend(item)
    return sorted(found)


def _runtime_json_outbound(text):
    """One outbound object from `text`, the tag left to the entry's name."""
    try:
        ob = json.loads(text)
    except ValueError as e:
        die(f"Not a URL, and not valid JSON: {e}")
    if not isinstance(ob, dict) or not ("type" in ob or "protocol" in ob):
        die('JSON must be one outbound object: sing-box ("type") or XRay ("protocol").')
    if unsafe := _local_file_keys(ob):
        die(
            f"An outbound added at runtime cannot name local files or programs ({', '.join(unsafe)}): "
            "the backend runs them with its privileges. Declare it in proxy.outbounds instead."
        )
    ob.pop("tag", None)
    return json.dumps(ob, ensure_ascii=False)


RUNTIME_TAG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def _check_tag_shape(kind, tag):
    """What add accepts; rm and edits too, so a tag never walks out of the spool (../)."""
    if not RUNTIME_TAG.fullmatch(tag):
        die(f"Invalid {kind} tag '{tag}': letters, digits, dot, dash and underscore only.")


# As the start script skips them, with proxy-suite-*: "priority" would be priority.json in the
# outbounds spool, "tor" the Tor outbound (reserved here whether or not this host has one).
RUNTIME_RESERVED_TAGS = ("proxy", "direct", "block", "priority", "tor")


def _check_runtime_tag(kind, tag):
    if tag in RUNTIME_RESERVED_TAGS or tag.startswith("proxy-suite-"):
        die(f"'{tag}' is reserved; pick another {kind} tag.")
    _check_tag_shape(kind, tag)
    _check_runtime_unused(kind, tag)
    if kind == "outbound":
        if tag in _outbound_tags():
            die(f"An outbound named '{tag}' already exists.")
        if tag in _outbound_groups() or os.path.exists(os.path.join(_runtime_dir(kind), f"{tag}.group")):
            die(f"A group named '{tag}' already exists.")
    elif tag in _sub_tags():
        die(f"A subscription named '{tag}' is declared in the configuration.")


RUNTIME_TAG_MAX = 32


def _check_runtime_unused(kind, tag):
    if tag in _runtime_tags(kind):
        die(f"A runtime {kind} named '{tag}' already exists; remove it first.")


def _runtime_lock(kind):
    """Held over an add or rm in a runtime spool: two at once could take one tag, or AmneziaWG port."""
    return _file_lock(os.path.join(_runtime_dir(kind), "entries"))


def _runtime_source(kind, arg):
    """Whether an add argument is the entry itself rather than its tag."""
    if kind == "outbound" and (_awg_source(arg) or _awg_file(arg)):
        return True
    return "://" in arg or arg == "-" or (kind == "outbound" and arg.lstrip().startswith("{"))


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
    taken = {*RUNTIME_RESERVED_TAGS, *_runtime_tags(kind), *(_outbound_tags() if kind == "outbound" else _sub_tags())}
    tag, n = base, 1
    while tag in taken:
        n += 1
        suffix = f"-{n}"
        tag = base[: RUNTIME_TAG_MAX - len(suffix)] + suffix
    return tag


def _runtime_entry_add(kind, *args, detour="", container="", awg_kind=""):
    what = "<url|json|-> [--detour <tag>]" if kind == "outbound" else "<url|->"
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
    # "-": the link on stdin, out of argv, so out of ps, sudo's and pkexec's logs while it waits to come up.
    if url == "-":
        url = sys.stdin.read()
        if not url.strip():
            die(f"Nothing on stdin: pipe the {'link or JSON' if kind == 'outbound' else 'URL'} in.")
    if kind == "outbound" and _awg_file(url):
        url = _awg_input(url)
    if kind == "outbound" and _awg_source(url):
        _awg_outbound_add(tag, url, detour, container, awg_kind)
        return
    if container:
        die("--container only applies to an AmneziaWG vpn:// link.")
    if awg_kind:
        die(f"--{awg_kind} only applies to an AmneziaWG config.")
    # Over plain http anyone on the path could swap in their own servers.
    scheme = url.strip().split("://", 1)[0].lower()
    if kind == "subscription" and scheme != "https" and not (scheme == "http" and env("RUNTIME_SUBS_ALLOW_HTTP") == "1"):
        die(
            "A subscription must be an https:// URL: fetched over plain http, anyone on the path could rewrite its entries."
            + (" An admin may allow http:// with services.proxy-suite.proxy.runtimeSubscriptions.allowHttp." if scheme == "http" else "")
        )
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
    with _runtime_lock(kind):
        _check_runtime_unused(kind, tag)
        try:
            # The hop first: the entry is what the start script looks for.
            hop = os.path.join(_runtime_dir(kind), f"{tag}.detour")
            if detour:
                _spool_write(hop, f"{detour}\n")
            elif os.path.lexists(hop):
                os.unlink(hop)  # left from an earlier entry of this name: it would chain this one too
            # Root's alone to read: the link (or JSON) holds the server's credentials, which
            # other members of the group need the "secrets" scope to see (`link`).
            _spool_write(path, f"{url}\n", 0o600)
        except OSError:
            denied(path, "write")
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
    if not source and _awg_tunnel_hop(entry.get("outbound") or {}):
        die(f"'{tag}' is an AmneziaWG outbound: its tunnel dials the peer itself and cannot go through another outbound.")
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
    _check_tag_shape(kind, tag)
    with _runtime_lock(kind):
        path = _runtime_path(kind, tag)
        if not os.path.exists(path):
            # The dir may be root-only: an entry that is there looks absent from outside it.
            if _runtime_hidden(kind):
                die(f"Cannot see the entry for '{tag}' in {_runtime_dir(kind)} - {ask_group()}")
            die(f"No runtime {kind} named '{tag}'. Ones declared in the NixOS configuration are removed there.")
        try:
            os.unlink(path)
            # Its hop, and a disable left from it: a new entry of this name would inherit them.
            for extra in (".detour", ".disabled", ".port", ".iface") if kind == "outbound" else ():
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
    excluded = set(inventory.get("excluded") or [])
    # With none left to pick the proxy would not start, pinned or not: an unpin falls back to selection.
    if [t for t in _outbound_tags() if t not in excluded] == [tag]:
        die(f"'{tag}' is the only outbound selection can pick; enable or add another first.")
    try:
        _spool_write(marker)
    except OSError:
        denied(marker, "write")
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
    # A subscription's tags keep their letters (sub-Россия), which disable took: the running
    # proxy's list of disabled ones vouches for those. Never a path of its own.
    if "/" in tag or tag in (".", "..") or not (RUNTIME_TAG.fullmatch(tag) or tag in _outbound_disabled()):
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
    """Only the backend parses the entry, so confirm it actually came up.

    The reload's restart returns once the start script is forked, before it writes the
    inventory again, so this gives it a moment.
    """
    deadline = time.monotonic() + 15
    while True:
        if kind == "outbound":
            if tag in _outbound_tags():
                print(f"Added outbound: {tag}")
                return
        elif state := _subscription_state(tag):
            print(f"Added subscription: {tag} ({state[1]} proxies)")
            return
        if time.monotonic() >= deadline:
            break
        time.sleep(0.5)
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


def _subscription_state(tag):
    """(cache mtime, proxy count), None without a cache. The cache is root's without the
    "secrets" scope: then the running proxy's inventory counts them, and the mtime is None."""
    cache = _subscription_cache(tag)
    try:
        st = os.stat(cache)
    except PermissionError:
        st = None
    except OSError:
        return None
    if st is not None and not stat.S_ISREG(st.st_mode):
        return None
    if st is not None and os.access(cache, os.R_OK):
        return st.st_mtime, _subscription_proxy_count_text(cache)
    count = sum(1 for source in (_outbound_inventory().get("sources") or {}).values() if source == f"sub:{tag}")
    return (st and st.st_mtime, str(count)) if st or count else None


def _subscription_row(tag, source):
    state = _subscription_state(tag)
    if state:
        mtime, count = state
        age = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S") if mtime else "unknown"
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
        usage("proxy subs [list|update|add [tag] <url|->|rm <tag>|link <tag>]")


RULE_SETS_UNIT = "proxy-suite-rulesets"


def cmd_rulesets(verb="list", *_):
    rule_sets = read_json_or(env("RULE_SETS_FILE"), [])
    if verb == "update":
        if not rule_sets or not svc_exists(RULE_SETS_UNIT):
            die("No proxy.routing.ruleSets in this configuration.")
        # A oneshot: this returns once every rule set was tried.
        status, _ = systemctl("start", RULE_SETS_UNIT)
        print("Rule sets updated." if status == 0 else f"Some rule sets were not updated: {journal_hint(RULE_SETS_UNIT, 20)}")
        sys.exit(status)
    elif verb == "list":
        if not rule_sets:
            print("No rule sets configured.")
            return
        print(f"  {'NAME':<24} {'LAST UPDATED':<22} SIZE")
        for rs in rule_sets:
            try:
                stat = os.stat(rs["path"])
            except OSError:
                print(f"  {rs['name']:<24} {'(missing)':<22} -")
                continue
            updated = datetime.datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
            print(f"  {rs['name']:<24} {updated:<22} {stat.st_size}")
        next_run = _timer_next_run(f"{RULE_SETS_UNIT}.timer")
        if next_run:
            print()
            print(f"Next update: {datetime.datetime.fromtimestamp(next_run):%H:%M:%S}, {_in_time(next_run)}")
    else:
        usage("proxy rulesets [list|update]")


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
        # The listener's login through a file in this private directory: argv is public. A
        # probe listener's own (_probe_login), or the local proxy's when there are none.
        login = None
        if "--proxy" in selector:
            proxy_url = selector[selector.index("--proxy") + 1]
            local = proxy_url == env("LOCAL_PROXY_URL", "http://127.0.0.1:1080")
            login = _local_proxy_login() if local else _probe_login()
        auth = []
        if login:
            curlrc = os.path.join(tmp, "login.curlrc")
            quoted = ":".join(login).replace("\\", "\\\\").replace('"', '\\"')
            with open(os.open(curlrc, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as f:
                f.write(f'proxy-user = "{quoted}"\n')
            auth = ["-K", curlrc]
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
                    # After the first hop url is the server's Location: no globbing, no file: or other schemes.
                    "--globoff",
                    "--proto",
                    "=http,https",
                    *auth,
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
            if not url or _probe_site(url) != site or _probe_local_target(url):
                break
    return result


def _probe_local_target(url):
    """Whether a Location names this host or its LAN by literal (no DNS): never followed."""
    try:
        host = (urllib.parse.urlsplit(url).hostname or "").rstrip(".")
    except ValueError:
        return True
    if host == "localhost" or host.endswith(".localhost"):
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        try:
            # What curl's resolver also takes as IPv4: 127.1, 0x7f000001, 2130706433.
            ip = ipaddress.IPv4Address(socket.inet_aton(host))
        except (OSError, ValueError):
            return False
    ip = getattr(ip, "ipv4_mapped", None) or ip
    return ip.is_loopback or ip.is_link_local or ip.is_private or ip.is_unspecified


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
            "exits": [dict(zip(("tag", "path", "result", "judgement"), row, strict=False), block=_probe_field(row[2], 5)) for row in w["rows"]],
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


def _autoproxy_spool():
    """Where `proxy auto learn|forget|relearn|clear` queue for the prober: root's state dir is read-only to members."""
    return env("AUTOPROXY_SPOOL_DIR", f"{state_dir()}/autoproxy-requests")


def _require_autoproxy():
    require_enabled("AUTOPROXY_ENABLED", "proxy.autoProxy")


def _autoproxy_unreadable(path):
    """The path a refused read stops at, empty when the state is readable or simply not there yet.

    The state dir is root's, 0751, and group-owned by the autoProxy scope's group,
    and state.json inside it stays 0640: a member gets past the directory and a
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
    for line in [line for line in lines(_autoproxy_queued("requests")) if line] or ["(none)"]:
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
    """Queues a line for the prober's own unit, as a file of its own in the sticky spool, named
    to sort by time: no other member can rewrite it, and it lands whole."""
    spool = _autoproxy_spool()
    try:
        _spool_write(os.path.join(spool, f"{name}.{time.time_ns()}.{os.getpid()}"), f"{line}\n")
    except OSError:
        denied(spool, "write to")


def _autoproxy_queued(name):
    """The lines still queued as `name` in the spool, oldest first; empty where it cannot be read."""
    spool = _autoproxy_spool()
    try:
        names = sorted(n for n in os.listdir(spool) if n.startswith(f"{name}."))
    except OSError:
        return ""
    text = ""
    for n in names:
        try:
            # Capped: a request is a line, and a member's file may be anything.
            text += read_shared_text(os.path.join(spool, n), 64 * 1024).rstrip("\n") + "\n"
        except OSError:
            pass
    return text


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
        if env("PER_APP_ROUTING_ZAPRET_ENABLED") == "1" and not svc_exists("proxy-suite-zapret"):
            die("zapret runs per app only (zapret.global.enable = false): proxy-ctl apps run <zapret profile> -- <command>")
        _toggle("proxy-suite-zapret", "zapret", *args)


def _zapret_state_dir():
    return env("ZAPRET_STATE_DIR", f"{state_dir()}/zapret2")


def _zapret_cutoff_dir():
    """The cutoff probe's own directory, outside the one the group writes to."""
    return env("ZAPRET_CUTOFF_DIR", f"{state_dir()}/zapret2-cutoff")


def _zapret_auto_file(name):
    return os.path.join(_zapret_state_dir(), name)


def _replace_lines(path, keep, extra=()):
    """Rewrites path with the lines keep() accepts, plus extra.

    Via a temp file in the same directory, with the old file's owner and mode (a new one
    world-readable: unprivileged proxy-ctl reads these lists too). Locked against another
    proxy-ctl; what nfqws2 appended meanwhile, unlocked, is carried over before the rename.
    """
    with _file_lock(path):
        try:
            old = os.lstat(path) if os.path.lexists(path) else None
            text = read_shared_text(path) if old else ""
            fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=os.path.dirname(path) or ".")
        except OSError:
            denied(path, "write")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.writelines(f"{line}\n" for line in [*filter(keep, lines(text)), *extra])
                # By fd, not path: tmp's name could be swapped for a symlink in between.
                os.fchmod(f.fileno(), stat.S_IMODE(old.st_mode) & 0o777 if old else 0o644)
                if old and os.geteuid() == 0:
                    os.fchown(f.fileno(), old.st_uid, old.st_gid)
                # Newer than anything this edit means to drop: kept as they came.
                f.writelines(f"{line}\n" for line in _appended_since(path, text))
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            denied(path, "replace")


def _appended_since(path, text):
    """The lines added to path since it read as text, if it only grew since; else none."""
    try:
        now = read_shared_text(path) if os.path.lexists(path) else ""
    except OSError:
        return []
    return lines(now[len(text) :]) if len(now) > len(text) and now.startswith(text) else []


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

    with _z2k_state_lock(path):
        _replace_lines(path, keep)


Z2K_LOCK_STALE = 10


@contextlib.contextmanager
def _z2k_state_lock(path):
    """z2k-state-persist.lua's own lock on state.tsv (<path>.lock, made O_EXCL, stale after 10 s):
    nfqws2 rewrites the file whole, so an unlocked rename could undo a row it just wrote."""
    lock = f"{path}.lock"
    deadline = time.monotonic() + LOCK_WAIT
    while True:
        try:
            fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
            break
        except FileExistsError:
            if _z2k_lock_stale(lock):
                with contextlib.suppress(OSError):
                    os.unlink(lock)
            elif time.monotonic() >= deadline:
                die(f"zapret2 is still writing {path} (it holds {lock}); try again.")
            else:
                time.sleep(0.05)
        except OSError:
            fd = None
            break
    if fd is None:
        yield
        return
    try:
        with os.fdopen(fd, "w", encoding="ascii") as f:
            f.write(str(int(time.time())))
        yield
    finally:
        with contextlib.suppress(OSError):
            os.unlink(lock)


def _z2k_lock_stale(lock):
    now = time.time()
    try:
        fd = os.open(lock, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as f:
            made = os.fstat(f.fileno()).st_mtime
            content = f.read(32).strip()
    except FileNotFoundError:
        return False  # gone already: the next try takes it
    except OSError:
        return True  # no lock z2k made (a symlink, say)
    try:
        taken = int(content)
    except ValueError:
        # Made but not written yet, or its writer died in between: only the latter lasts.
        return now - made > 2
    # One from the future: the clock went back since.
    return taken > now + Z2K_LOCK_STALE or now - taken > Z2K_LOCK_STALE


def _zapret_strategy_rows():
    """state.tsv as (key, host, strategy, mode, sni): the strategy each profile's rotation
    settled on per domain. The host may carry a |4 or |6 address family."""
    rows = []
    for fields in _tsv(_zapret_auto_file("circular/state.tsv")):
        if len(fields) < 3 or fields[0].startswith("#") or not fields[2].isdigit():
            continue
        fields += [""] * (6 - len(fields))
        rows.append((fields[0], fields[1].split("|", 1)[0], fields[2], fields[4], fields[5]))
    return rows


def _zapret_strategies_for(domain, rows=None):
    """The rows for domain: circular keys them by the domain it rotates on, usually the apex."""
    return [r for r in (_zapret_strategy_rows() if rows is None else rows) if r[1] and (domain == r[1] or domain.endswith(f".{r[1]}"))]


def _zapret_strategy_map():
    """{key: {strategy: [desync instances]}} of the running global instance, or {}."""
    return read_json_or(env("ZAPRET_STRATEGIES_FILE"), {})


def _zapret_strategy_specs(row, strategies):
    specs = strategies.get(row[0])
    specs = specs.get(row[2]) if isinstance(specs, dict) else None
    return [s for s in specs if isinstance(s, str)] if isinstance(specs, list) else []


def _zapret_strategy_text(row, strategies):
    """"rkn_tcp #3 (fake + multisplit)": the profile's key, the strategy number, what it does."""
    key, _, n, mode, sni = row
    text = f"{key} #{n}"
    names = " + ".join(dict.fromkeys(s.split(":", 1)[0] for s in _zapret_strategy_specs(row, strategies)))
    if names:
        text += f" ({names})"
    if mode == "frozen":
        text += ", frozen"
    if sni:
        text += f", fake SNI {sni}"
    return text


def _zapret_strategy_summary(domain, rows=None, strategies=None):
    """Every strategy remembered for domain, "; "-joined, or ""."""
    strategies = _zapret_strategy_map() if strategies is None else strategies
    return "; ".join(_zapret_strategy_text(r, strategies) for r in _zapret_strategies_for(domain, rows))


# detect.lua's verdicts (zapret2/detect.lua): "kind<TAB>name<TAB>proto<TAB>note<TAB>time",
# the last per name and proto standing. What the proxy carries in zapret2's stead, and
# whether a learned site is seen working, which decides whether directSync sends it direct.
ZAPRET_PROXIED = {"tcp": "no strategy gets through", "udp": "its QUIC: no strategy gets through", "ip": "blocked by address"}


def _zapret_verdicts():
    """{(name, proto): kind}, the last verdict of each."""
    out = {}
    for fields in _tsv(_zapret_auto_file("verdicts.tsv")):
        if len(fields) >= 3 and fields[0] and fields[1]:
            out[(fields[1], fields[2])] = fields[0]
    return out


def _zapret_covers(host, name):
    """A host and a site key, either way round: www.notion.so and notion.so."""
    return host == name or host.endswith(f".{name}") or name.endswith(f".{host}")


def _zapret_status(host, verdicts=None):
    """What zapret2 made of host, "" before it decided anything."""
    verdicts = _zapret_verdicts() if verdicts is None else verdicts
    kinds = {}
    for (name, proto), kind in verdicts.items():
        if _zapret_covers(host, name):
            kinds[proto] = kind
    parts = []
    if kinds.get("tcp") == "unfixable":
        parts.append("via the proxy: no strategy gets through")
    elif kinds.get("cutoff") == "stalls":
        parts.append("cut off after 16 KB: keeps the proxy's route")
    elif kinds.get("tcp") == "works":
        parts.append("works")
    if kinds.get("udp") == "unfixable":
        parts.append("QUIC via the proxy")
    return ", ".join(parts)


def _zapret_proxied(verdicts=None):
    """[(name, why)] the proxy carries because zapret2 cannot fix them."""
    verdicts = _zapret_verdicts() if verdicts is None else verdicts
    return [
        (name, ZAPRET_PROXIED[proto])
        for (name, proto), kind in sorted(verdicts.items())
        if (kind, proto) in (("unfixable", "tcp"), ("unfixable", "udp"), ("blocked", "ip"))
    ]


def _zapret_verdicts_drop(host):
    """Forgets every verdict about host, so zapret2 judges it afresh."""
    path = _zapret_auto_file("verdicts.tsv")
    if not os.path.isfile(path):
        return

    def keep(line):
        fields = line.split("\t")
        return len(fields) < 2 or not _zapret_covers(host, fields[1])

    _replace_lines(path, keep)


def _zapret_retry(name):
    """The proxy carries name no longer: zapret2 tries it again, rotation unfrozen."""
    path = _zapret_auto_file("verdicts.tsv")
    retried = [proto for (n, proto), kind in _zapret_verdicts().items() if n == name and kind in ("unfixable", "blocked")]
    if not retried:
        die(f"zapret2 sends nothing for {name} through the proxy: proxy-ctl zapret auto lists what it does.")
    now = int(time.time())
    _replace_lines(path, lambda _: True, [f"retry\t{name}\t{proto}\tproxy-ctl\t{now}" for proto in retried])
    # nfqws2 keeps a site's rotation stopped, and its verdicts, until it restarts.
    if svc_active("proxy-suite-zapret"):
        cmd_zapret("restart")
    print(f"zapret2 tries {name} again; the proxy carries it no longer.")


def _truncate(path):
    _replace_lines(path, lambda _: False)


def _zapret_auto_host(host):
    """A hostname, or an IP literal: nfqws2 learns those from bare-IP requests."""
    if HOSTNAME.fullmatch(host):
        return True
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False
    return True


def cmd_zapret_auto(verb="list", domain="", *_):
    if env("ZAPRET_AUTO_ENABLED") != "1":
        die('Learned hostlists need zapret.engine = "zapret2" with zapret.global.enable.')
    auto = _zapret_auto_file("zapret-hosts-auto.txt")
    user = _zapret_auto_file("zapret-hosts-user.txt")
    exclude = _zapret_auto_file("zapret-hosts-user-exclude.txt")

    if verb in ("add", "forget", "exclude", "unpin", "include", "retry") and not _zapret_auto_host(domain):
        usage(f"zapret auto {verb} <domain>")
    if verb == "list":
        try:
            hosts = [h for h in lines(read_shared_text(auto)) if h] if os.path.lexists(auto) else []
        except OSError:
            denied(auto)
        if not hosts:
            print("No hostnames learned yet.")
        rows, strategies, verdicts = _zapret_strategy_rows(), _zapret_strategy_map(), _zapret_verdicts()
        width = max(map(len, hosts), default=0)
        for host in hosts:
            notes = [n for n in (_zapret_strategy_summary(host, rows, strategies), _zapret_status(host, verdicts)) if n]
            print(f"{host:<{width}}  {'; '.join(notes)}" if notes else host)
        proxied = _zapret_proxied(verdicts)
        if proxied:
            print("\nThrough the proxy, as zapret2 cannot fix them:")
            width = max(len(name) for name, _ in proxied)
            for name, why in proxied:
                print(f"  {name:<{width}}  {why}")
            sys.stdout.flush()
            print("Give one another try: proxy-ctl zapret auto retry <name>", file=sys.stderr)
    elif verb == "retry":
        _zapret_retry(domain)
    elif verb == "add":
        _zapret_auto_edit(user, domain, "add")
        print(f"Pinned {domain}: zapret treats it as blocked.")
    elif verb == "forget":
        _zapret_auto_edit(auto, domain, "drop")
        _zapret_strategy_drop(domain)
        _zapret_verdicts_drop(domain)
        print(f"Forgot {domain}. It is learned again if it keeps failing; 'exclude' prevents that.")
    elif verb == "exclude":
        _zapret_auto_edit(auto, domain, "drop")
        _zapret_strategy_drop(domain)
        _zapret_verdicts_drop(domain)
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
        for path in (_zapret_auto_file("circular/state.tsv"), _zapret_auto_file("verdicts.tsv")):
            if os.path.exists(path):
                with _z2k_state_lock(path) if path.endswith("state.tsv") else contextlib.nullcontext():
                    _truncate(path)
        print("Cleared learned hosts, remembered strategies and what zapret2 sent the proxy.")
    else:
        usage("zapret auto [list|add|forget|exclude|unpin|include|retry|clear]")


# --- zapret cutoff ------------------------------------------------------------
#
# The 16 KB cutoff probe's verdict: which networks this line cuts after the
# handshake, and the whitelisted name that gets each through. Networks without a
# name are what the proxy fallback routes.


def _tsv(path):
    try:
        return [line.split("\t") for line in lines(read_shared_text(path))]
    except OSError:
        return []


def cmd_zapret_cutoff(verb="status", *_):
    path = _zapret_cutoff_dir()
    if env("ZAPRET_CUTOFF_ENABLED") != "1":
        die('The cutoff probe needs zapret.engine = "zapret2" with zapret2.cutoff.enable.')
    if verb == "probe":
        # requests/: the only part of the probe's directory the group writes to.
        requests = os.path.join(path, "requests")
        try:
            _spool_write(os.path.join(requests, "force"))
        except OSError:
            denied(requests, "write")
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
        return _where_in(set(lines(read_shared_text(path))), domain)
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
        if os.path.exists(config_path) and not readable(config_path):
            _where_row("sing-box", f"routing is not readable - {ask_group()}")
        elif readable(config_path):
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
        if _autoproxy_unreadable(_autoproxy_dir()):
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
            _where_row("zapret", f"excluded ({excluded}) - never touched, never learned")
        elif pinned:
            _where_row("zapret", f"pinned ({pinned}) - treated as blocked")
            verdict = verdict or "direct, with the zapret bypass"
        elif learned:
            _where_row("zapret", f"learned ({learned}) - treated as blocked")
            verdict = verdict or "direct, with the zapret bypass"
        else:
            _where_row("zapret", "not learned, not pinned, not excluded")
        # Remembered for hosts a source's own lists cover too, learned or not.
        strategies = _zapret_strategy_map()
        for row in _zapret_strategies_for(domain):
            _where_row("strategy", _zapret_strategy_text(row, strategies))
            for spec in _zapret_strategy_specs(row, strategies):
                _where_row("", f"  --lua-desync={spec}")

    if local:
        zapret = verdict == "direct, with the zapret bypass"
        verdict = f"{local}, with the zapret bypass" if zapret and local == "direct" else local
        print(f"  -> {verdict}")
        return
    print(f"  -> {verdict or 'nothing runtime matches it; the configured routing decides'}")
    print("  The sing-box config is not readable here. Test what reaches it:")
    print(f"    proxy-ctl proxy auto probe {domain}")


# --- awg ----------------------------------------------------------------------


AWG_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}")


def _awg_service(profile):
    # Added with `awg add`: an instance of the template, which reads amneziawg.d/<name>.conf.
    if profile and _awg_added(profile):
        return f"proxy-suite-awg@{profile}"
    return f"proxy-suite-awg-{profile}"


# --- AmneziaWG configs added at runtime -----------------------------------------
#
# A .conf or vpn:// link becomes a global profile (`awg add`, amneziawg.d/<name>.conf) or an
# outbound (`proxy outbounds add`, outbounds.d/<tag>.awg with its tunnel's port in <tag>.port,
# or on an interface of its own, with its slot in <tag>.iface).
# amneziawg_config.py --import checks and normalizes it, hooks refused. The config always
# reaches it on stdin: keys in argv would show in ps.


def _awg_source(text):
    """Whether text is an AmneziaWG config itself: a vpn:// link, or .conf text."""
    t = (text or "").strip()
    return t.startswith("vpn://") or ("[interface]" in t.lower() and "[peer]" in t.lower())


def _awg_file(arg):
    """Whether an add argument names a .conf or vpn:// export on disk."""
    return bool(arg) and arg.endswith((".conf", ".vpn")) and os.path.isfile(os.path.expanduser(arg))


def _awg_input(arg):
    """The config an add argument stands for: stdin (-), the text itself, or a file's."""
    if arg == "-":
        return sys.stdin.read()
    if _awg_source(arg):
        return arg
    path = os.path.expanduser(arg)
    try:
        return read_text(path)
    except OSError as e:
        die(f"Cannot read {path}: {e.strerror or e}")


def _awg_import(text, *args):
    """amneziawg_config.py --import on text: its output, or its complaint as ours."""
    tool = env("AWG_CONFIG_TOOL")
    if not tool:
        die("AmneziaWG is not enabled in this configuration.")
    try:
        p = subprocess.run([sys.executable, tool, "--import", "-", *args], input=text, capture_output=True, text=True)
    except OSError as e:
        die(f"Cannot run {tool}: {e}")
    if p.returncode:
        message = p.stderr.strip().removeprefix("amneziawg-config: ") or f"{tool} exited with {p.returncode}"
        die(message.replace("set vpnContainer", "pick one with --container <name>"))
    return p.stdout


def _awg_describe(text, container=""):
    """What the config says of itself: {"name", "endpoint"}. Dies when it is not one."""
    out = _awg_import(text, "--describe", *(["--container", container] if container else []))
    try:
        described = json.loads(out)
    except ValueError:
        described = {}
    return described if isinstance(described, dict) else {}


def _awg_label(described, fallback):
    """A name for an entry added without one: the export's description, else awg-<its host>."""
    name = _s(described.get("name") or "")
    host = _s(described.get("endpoint") or "").rsplit(":", 1)[0].strip("[]")
    if name and name == host:
        return f"awg-{_host_label(host)}"
    return name or fallback


def _awg_write(text, path, container=""):
    """The normalized config at path, 0600; the directory must let us in."""
    directory = os.path.dirname(path)
    if not os.access(directory, os.W_OK | os.X_OK):
        denied(directory, "write to")
    _awg_import(text, "--output", path, *(["--container", container] if container else []))


def _awg_tunnel_ports():
    return range(int(env("AWG_TUNNEL_BASE_PORT", "18800")), int(env("AWG_TUNNEL_BASE_PORT", "18800")) + int(env("AWG_TUNNEL_SLOTS", "32")))


def _awg_tunnel_hop(ob):
    """Whether a backend outbound is the SOCKS hop to a runtime AmneziaWG tunnel."""
    port = ob.get("server_port") or (ob.get("settings") or {}).get("port")
    server = ob.get("server") or (ob.get("settings") or {}).get("address")
    return server == "127.0.0.1" and isinstance(port, int) and port in _awg_tunnel_ports()


def _awg_free_port():
    taken = set()
    directory = _runtime_dir("outbound")
    try:
        names = os.listdir(directory)
    except OSError:
        names = []
    for name in names:
        if name.endswith(".port"):
            try:
                taken.add(int(read_shared_text(os.path.join(directory, name), 64).split()[0]))
            except (OSError, ValueError, IndexError):
                pass
    port = next((p for p in _awg_tunnel_ports() if p not in taken), None)
    if port is None:
        die(f"No free port for another AmneziaWG outbound: all {len(_awg_tunnel_ports())} are taken. Remove one first.")
    return port


def _awg_iface_slots():
    return range(int(env("AWG_IFACE_SLOTS", "16")))


def _awg_free_iface_slot():
    """A slot no <tag>.iface holds: the interface psawgr<slot>, and its table and marks."""
    taken = set()
    directory = _runtime_dir("outbound")
    try:
        names = os.listdir(directory)
    except OSError:
        names = []
    for name in names:
        if name.endswith(".iface"):
            try:
                taken.add(int(read_shared_text(os.path.join(directory, name), 64).split()[0]))
            except (OSError, ValueError, IndexError):
                pass
    slot = next((n for n in _awg_iface_slots() if n not in taken), None)
    if slot is None:
        die(f"No free slot for another AmneziaWG interface: all {len(_awg_iface_slots())} are taken. Remove one first.")
    return slot


def _awg_outbound_add(tag, text, detour, container, kind=""):
    require_enabled("AWG_RUNTIME_OUTBOUNDS", "Adding AmneziaWG outbounds at runtime")
    kind = kind or env("AWG_RUNTIME_OUTBOUND_KIND", "userspace")
    if kind == "interface":
        require_enabled("AWG_RUNTIME_IFACE_OUTBOUNDS", "An AmneziaWG outbound on an interface of its own (root hosts only)")
    if detour:
        die("An AmneziaWG outbound cannot chain through another: its tunnel dials the peer itself.")
    described = _awg_describe(text, container)
    if not tag:
        tag = _unique_runtime_tag("outbound", _awg_label(described, "awg"), "awg")
        _check_runtime_tag("outbound", tag)
        print(f"Tag: {tag} (none given; pass one first to choose it)")
    directory = _runtime_dir("outbound")
    if not os.access(directory, os.W_OK | os.X_OK):
        denied(directory, "write to")
    with _runtime_lock("outbound"):
        _check_runtime_unused("outbound", tag)
        # The port, or the interface's slot, first: the config is what the start script and the
        # sync unit look for.
        if kind == "interface":
            extra, value, stale = ".iface", _awg_free_iface_slot(), ".port"
        else:
            extra, value, stale = ".port", _awg_free_port(), ".iface"
        try:
            for leftover in (".detour", ".disabled", stale):
                if os.path.lexists(os.path.join(directory, tag + leftover)):
                    os.unlink(os.path.join(directory, tag + leftover))  # left from an earlier entry of this name
            _spool_write(os.path.join(directory, tag + extra), f"{value}\n")
        except OSError:
            denied(directory, "write to")
        _awg_write(text, os.path.join(directory, f"{tag}.awg"), container)
    _runtime_reload()
    _runtime_entry_verify("outbound", tag)


def _awg_add(*args):
    shape = "awg add [name] <vpn://…|file.conf|-> [--container <name>]"
    args = list(args)
    container = ""
    if "--container" in args:
        i = args.index("--container")
        container = args[i + 1] if i + 1 < len(args) else ""
        del args[i : i + 2]
        if not container:
            usage(shape)
    require_enabled("AWG_RUNTIME_GLOBAL", "Adding AmneziaWG profiles at runtime")
    if len(args) == 1:
        name, source = "", args[0]
    elif len(args) == 2 and (_awg_source(args[0]) or args[0] == "-"):
        die(f"The name goes first, the config after it: proxy-ctl {shape}")
    elif len(args) == 2:
        name, source = args
    else:
        usage(shape)
    # "warp" and the WARP devices name WARP's own AmneziaWG units (_warp_devices).
    reserved = {"warp", *(t for t, _ in _warp_devices())}
    taken = {*_awg_profiles(), *reserved}
    if name in reserved:
        die(f"'{name}' is reserved for WARP; pick another name.")
    if name:
        if not AWG_NAME.fullmatch(name):
            die(f"Invalid profile name '{name}': up to 32 letters, digits, dashes and underscores, starting with a letter or digit.")
        if name in taken:
            die(f"An AmneziaWG profile named '{name}' already exists." + ("" if name in _awg_runtime_profiles() else " It is declared in the NixOS configuration."))
    text = _awg_input(source)
    described = _awg_describe(text, container)
    if not name:
        base = re.sub(r"[^A-Za-z0-9_-]+", "-", _awg_label(described, "awg")).strip("-_")[:32].strip("-_") or "awg"
        name, n = base, 1
        while name in taken:
            n += 1
            name = f"{base[: 32 - len(str(n)) - 1]}-{n}"
        print(f"Name: {name} (none given; pass one first to choose it)")
    _awg_write(text, os.path.join(_awg_runtime_dir(), f"{name}.conf"), container)
    print(f"Added AmneziaWG profile: {name} - start it with: proxy-ctl awg on {name}")


def _awg_rm(name="", *_):
    if not name:
        usage("awg rm <profile>")
    if name not in _awg_runtime_profiles():
        if name in _awg_profiles():
            die(f"'{name}' is declared in the NixOS configuration; remove it there.")
        die(f"No AmneziaWG profile named '{name}' was added with awg add.")
    directory = _awg_runtime_dir()
    if not os.access(directory, os.W_OK | os.X_OK):
        denied(directory, "write to")
    unit = _awg_service(name)
    if svc_active(unit) or svc_state(unit) == "failed":
        must("stop", unit)
        # As `awg off`: the kill switch would otherwise hold with no tunnel to guard.
        _lift_kill_switch()
    try:
        os.unlink(os.path.join(directory, f"{name}.conf"))
    except FileNotFoundError:
        pass
    except OSError:
        denied(os.path.join(directory, f"{name}.conf"), "remove")
    print(f"Removed AmneziaWG profile: {name}")


def _active_awg_profiles():
    return [p for p in _awg_profiles() if svc_active(_awg_service(p))]


def cmd_awg(verb="list", *args):
    if verb == "add":
        _awg_add(*args)
        return
    if verb in ("rm", "remove", "del"):
        _awg_rm(*args)
        return
    profiles = _awg_profiles()
    if args and args[0] not in profiles:
        die(f"Unknown AmneziaWG profile: {args[0]}")
    if verb == "toggle":
        # Without a profile there is only something to stop: which one to start is not known.
        if args:
            verb = _flip(_awg_service(args[0]), verb)
        elif _active_awg_profiles():
            verb = "off"
        else:
            usage("awg toggle <profile>")
    if verb in ("list", "status"):
        if not profiles:
            print("No AmneziaWG profiles configured." + (" Add one with: proxy-ctl awg add <vpn://…|file.conf>" if env("AWG_RUNTIME_GLOBAL") == "1" else ""))
            return
        print(f"  {'PROFILE':<24} {'STATUS':<12} SOURCE")
        for profile in profiles:
            print(f"  {profile:<24} {svc_state(_awg_service(profile)) or 'unknown':<12} {'runtime' if _awg_added(profile) else 'declared'}")
    elif verb == "on":
        if not args:
            usage("awg on <profile>")
        must("start", _awg_service(args[0]))
    elif verb in ("off", "restart"):
        targets = list(args[:1]) or _active_awg_profiles()
        if not targets and verb == "restart":
            die("No AmneziaWG profile is active.")
        for profile in targets:
            must("stop" if verb == "off" else "restart", _awg_service(profile))
        # Also after a profile that already failed: off is how its kill switch is lifted.
        if verb == "off":
            _lift_kill_switch()
    else:
        usage("awg [list] | on <profile> | off [profile] | toggle [profile] | restart [profile] | add [name] <config> | rm <profile>")


# --- wl -----------------------------------------------------------------------


def _wl():
    """whitelist-bypass creators and joiners: [{name, role, platform}]."""
    return read_json_or(env("WL_FILE"), [])


def _wl_unit(w):
    return f"proxy-suite-wb-{w['role']}-{w['name']}"


def _wl_path(name, suffix):
    return os.path.join(state_dir(), "whitelist-bypass", name + suffix)


def _wl_link(name):
    """The call a creator made and keeps rejoining: the last line it wrote."""
    path = _wl_path(name, ".link")
    try:
        links = [line.strip() for line in lines(read_shared_text(path)) if line.strip()]
    except FileNotFoundError:
        links = []
    except OSError:
        denied(path)
    if not links:
        die(f"{name} has no call yet: {journal_hint(_wl_unit({'role': 'creator', 'name': name}))}")
    return links[-1]


def _wl_input(source, what):
    """The text of source: a file, or - for stdin."""
    try:
        return sys.stdin.read() if source == "-" else read_text(source)
    except OSError as e:
        die(f"Cannot read the {what} from {source}: {e.strerror}")


# DION and Bitrix creators log in on their own from these, and save the session back.
WL_PASSWORD_LOGIN = {"dion": ("email", "password"), "bitrix": ("email", "password", "portal")}


def _wl_login(w, source):
    """The creator's login: a cookies export from source (a file or -), or asked for."""
    if source:
        text = _wl_input(source, "cookies")
        try:
            json.loads(text)
        except ValueError as e:
            die(f"Not a cookies export, not valid JSON: {e}")
        return text
    fields = WL_PASSWORD_LOGIN.get(w["platform"])
    if not fields:
        die(f"{w['platform']} logs in only in a browser: export its cookies from the desktop Creator, then: proxy-ctl wl auth {w['name']} <file>")
    login = {k: getpass.getpass("Password: ") if k == "password" else input(f"{k.capitalize()}: ").strip() for k in fields}
    if "portal" in login:
        portal = login["portal"].rstrip("/")
        login["portal"] = portal if "://" in portal else f"https://{portal}"
    return json.dumps(login)


def _wl_write(w, suffix, text):
    """Replaces a file the unit reads from its state directory, and restarts it on it.

    The file takes the directory's group, and its owner too when root writes it: the
    daemon reads it, and DION and Bitrix creators rotate their tokens into it.
    """
    path = _wl_path(w["name"], suffix)
    tmp = ""
    try:
        os.makedirs(os.path.dirname(path), 0o700, exist_ok=True)
        st = os.stat(os.path.dirname(path))
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=os.path.dirname(path))
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            # By fd: the group may write here, so tmp's name could become a symlink first.
            os.fchown(f.fileno(), st.st_uid if os.geteuid() == 0 else -1, st.st_gid)
            os.fchmod(f.fileno(), 0o600 | (st.st_mode & 0o060))
        os.replace(tmp, path)
    except OSError:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        denied(path, "write")
    must("restart", _wl_unit(w))


def _wl_join(w, source):
    link = (_wl_input(source, "link") if source == "-" else source).strip()
    if not link or re.search(r"\s", link):
        die("A call link is one word: a room id, a slug or a URL.")
    _wl_write(w, ".join", f"{link}\n")


def _wl_new(w):
    """Drops the call a creator rejoins: it makes a new one when it starts."""
    if w.get("fixedLink"):
        die(f"{w['name']} rejoins the call its linkFile sets: change that instead.")
    path = _wl_path(w["name"], ".link")
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    except OSError:
        denied(path, "remove")
    must("restart", _wl_unit(w))
    print(f"Its joiner needs the new call: proxy-ctl wl link {w['name']}")


def _wl_one(named, role, shape):
    """The one creator or joiner a verb takes."""
    if not named or len(named) > 1 or named[0]["role"] != role:
        usage(f"wl {shape}")
    return named[0]


def cmd_wl(verb="list", *args):
    entries = _wl()
    named = [w for w in entries if w["name"] == args[0]] if args else []
    if args and not named:
        die(f"Unknown whitelist-bypass creator or joiner: {args[0]}")
    if verb in ("list", "status"):
        if not entries:
            print("No whitelist-bypass creators or joiners configured.")
            return
        print(f"  {'NAME':<16} {'ROLE':<8} {'PLATFORM':<10} STATUS")
        for w in entries:
            print(f"  {w['name']:<16} {w['role']:<8} {w['platform']:<10} {svc_state(_wl_unit(w)) or 'unknown'}")
    elif verb == "link":
        _emit(_wl_link(_wl_one(named, "creator", "link <creator> [--qr]")["name"]), "--qr" in args)
    elif verb == "auth" and len(args) <= 2:
        w = _wl_one(named, "creator", "auth <creator> [file|-]")
        _wl_write(w, ".cookies.json", _wl_login(w, args[1] if len(args) > 1 else ""))
    elif verb == "join" and len(args) == 2:
        _wl_join(_wl_one(named, "joiner", "join <joiner> <link|->"), args[1])
    elif verb == "new" and len(args) == 1:
        _wl_new(_wl_one(named, "creator", "new <creator>"))
    elif verb in ("on", "off", "toggle", "restart"):
        for w in named or entries:
            action = {"on": "start", "off": "stop", "restart": "restart"}[_flip(_wl_unit(w), verb)]
            must(action, _wl_unit(w))
    else:
        usage("wl [list] | link <creator> [--qr] | auth <creator> [file|-] | join <joiner> <link|-> | new <creator> | on|off|toggle|restart [name]")


# --- apps ---------------------------------------------------------------------

SLICE_ROUTES = {
    "tun": ("proxy-suite-per-app-tun", "PER_APP_ROUTING_TUN_ENABLED", "perAppRouting.tun.enable"),
    "tproxy": ("proxy-suite-per-app-tproxy", "PER_APP_ROUTING_TPROXY_ENABLED", "perAppRouting.tproxy.enable"),
    "zapret": ("proxy-suite-per-app-zapret", "PER_APP_ROUTING_ZAPRET_ENABLED", "perAppRouting.zapret.enable"),
}


APP_NAME = re.compile(r"[a-z0-9][a-z0-9-]*")
APP_ROUTES = ("direct", "proxychains", "tun", "tproxy", "zapret")
RUNTIME_APP_MAX_BYTES = 64 * 1024


def _read_shared_json(path):
    """The JSON object at path (read_shared_text), {} for anything else."""
    try:
        value = json.loads(read_shared_text(path, RUNTIME_APP_MAX_BYTES))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _runtime_apps():
    """Profiles `apps add` added, <name>.json in RUNTIME_APPS_DIR, each marked "runtime"."""
    directory = env("RUNTIME_APPS_DIR")
    try:
        names = sorted(os.listdir(directory)) if directory else []
    except OSError:
        names = []
    apps = []
    for file in names:
        name = file.removesuffix(".json")
        entry = _read_shared_json(os.path.join(directory, file)) if file.endswith(".json") else {}
        if APP_NAME.fullmatch(name) and _s(entry.get("route")) in APP_ROUTES:
            apps.append({"name": name, "route": _s(entry["route"]), "outbound": _s(entry.get("outbound") or "") or None, "runtime": True})
    return apps


def _per_app_profiles():
    """The declared profiles, then those added at runtime under a name none of them has."""
    try:
        declared = read_json(env("PER_APP_ROUTING_PROFILES_FILE"))
    except (OSError, ValueError):
        die(f"Cannot read perAppRouting profiles: {env('PER_APP_ROUTING_PROFILES_FILE')}")
    names = {p.get("name") for p in declared}
    return declared + [p for p in _runtime_apps() if p["name"] not in names]


APPS_ADD_USAGE = "add <name> [--route direct|proxychains|tun|tproxy|zapret] [--via <outbound>]"


def _apps_add(*args):
    args, route, via = list(args), "", ""
    for flag in ("--route", "--via"):
        if flag in args:
            i = args.index(flag)
            value = args[i + 1] if i + 1 < len(args) else ""
            del args[i : i + 2]
            if not value:
                usage(f"apps {APPS_ADD_USAGE}")
            route, via = (value, via) if flag == "--route" else (route, value)
    if len(args) != 1 or not (route or via):
        usage(f"apps {APPS_ADD_USAGE}")
    name = args[0]
    if not APP_NAME.fullmatch(name):
        die(f"Invalid profile name '{name}': lowercase letters, digits and dashes.")
    if any(p.get("name") == name and not p.get("runtime") for p in _per_app_profiles()):
        die(f"Profile '{name}' is declared in the NixOS configuration; pick another name.")
    if route and route not in APP_ROUTES:
        die(f"--route is one of {', '.join(APP_ROUTES)}, not '{route}'.")
    # An "interface" outbound or a global profile takes the app directly; `apps run` sorts out
    # a name that is both.
    direct = via in _via_outbounds() or via.startswith("awg:") or (env("PER_APP_VIA_PROFILES") == "1" and via in _awg_profiles())
    if via and not direct:
        # Any other outbound goes through a pin slot of the route.
        route = route or next(iter(_pin_routes()), "")
        if route not in _pin_routes():
            die(f"--via '{via}' needs --route tun or tproxy with pin slots here, or an \"interface\" AmneziaWG outbound.")
    directory = env("RUNTIME_APPS_DIR")
    if not directory or not os.access(directory, os.W_OK | os.X_OK):
        denied(directory or "RUNTIME_APPS_DIR", "write to")
    try:
        # Readable by everyone: whoever runs apps reads the profiles.
        _spool_write(os.path.join(directory, f"{name}.json"), json.dumps({"route": route or "direct", "outbound": via or None}) + "\n", 0o644)
    except OSError:
        denied(directory, "write to")
    print(f"Added app profile: {name}")


def _apps_rm(name="", *_):
    if not name:
        usage("apps rm <name>")
    path = os.path.join(env("RUNTIME_APPS_DIR"), f"{name}.json")
    if not APP_NAME.fullmatch(name) or not os.path.exists(path):
        if any(p.get("name") == name for p in _per_app_profiles()):
            die(f"Profile '{name}' is declared in the NixOS configuration; remove it there.")
        die(f"No app profile added at runtime named '{name}'.")
    try:
        os.unlink(path)
    except OSError:
        denied(path, "remove")
    print(f"Removed app profile: {name}")


def _ensure_app_routing():
    require_enabled("PER_APP_ROUTING_ENABLED", "perAppRouting")


def _active_global_proxy(route=""):
    """The global unit up that carries the app's traffic already (TUN, TProxy; for zapret an
    AmneziaWG profile too): the per-app units refuse to start under it."""
    units = ["proxy-suite-tun", "proxy-suite-tproxy"]
    if route == "zapret":
        units += [_awg_service(profile) for profile in _awg_profiles()]
    return next((svc for svc in units if svc_active(f"{svc}.service")), "")


def _has_units(*args):
    return bool(re.search(".", systemctl(*args, capture=True)[1]))


def _slice_lock(slice_base):
    """This user's shared lock on the slice, from before its units start until the app exits:
    a run ending must not stop the marking under one whose scope is not registered yet. None if unavailable."""
    directory = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    try:
        fd = os.open(
            os.path.join(directory, f"proxy-suite-{slice_base}.lock"),
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
        )
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_SH)
    except OSError:
        os.close(fd)
        return None
    return fd


def _cleanup_slice_if_idle(slice_base, anchor_unit, user_svc, lock=None):
    """Stops this user's marking once none of their apps runs in the slice (the shared backend
    stops by itself). Only the last holder of _slice_lock's lock may stop anything."""
    if lock is not None:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(lock)
            return
    try:
        _stop_slice_if_idle(slice_base, anchor_unit, user_svc)
    finally:
        if lock is not None:
            os.close(lock)


def _stop_slice_if_idle(slice_base, anchor_unit, user_svc):
    # Still the backstop for runs that were killed and never let go of the lock.
    if _has_units("--user", "list-units", "--type=scope", "--state=running", "--plain", "--no-legend", f"{slice_base}-*"):
        return
    systemctl("stop", user_svc)
    systemctl("--user", "stop", anchor_unit)


def _warn_nscd(route):
    """nscd (NixOS's default) resolves from its own cgroup, outside the wrapped app's route; a
    resolver the app asks itself goes through the route's DNS forwarder."""
    if os.path.exists(env("NSCD_SOCKET", "/run/nscd/socket")):
        print(
            "warning: nscd answers this host's lookups from outside the wrapped app's cgroup, so "
            f"names resolve outside route={route}. Apps that ask a resolver themselves (Go "
            "programs, a browser's own resolver or DNS-over-HTTPS) resolve through the route.",
            file=sys.stderr,
        )


def _wrap_slice(slice_base, profile, cmd, units=None, before=()):
    """Runs cmd in a user scope inside the route's slice, then stops what went idle.

    units: (anchor, this user's marking unit) when they are not named after the slice.
    before: units to have up first, in order, that the marking unit does not bring up.
    """
    uid = os.getuid()
    scope_unit = f"{slice_base}-{profile}-{os.getpid()}"
    anchor_unit, user_svc = units or (f"{slice_base}-anchor.service", f"{slice_base}-user@{uid}.service")
    # SIGTERM still cleans up, as it did behind bash's EXIT trap.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    lock = _slice_lock(slice_base)
    try:
        status = systemctl("--user", "start", anchor_unit)[0]
        for unit in before:
            status = status or systemctl("start", unit)[0]
        # A slice route's marking brings its backend up (Requires=): started alone first,
        # the backend would go again at once, needed by nothing (StopWhenUnneeded=).
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
        _cleanup_slice_if_idle(slice_base, anchor_unit, user_svc, lock)
    sys.exit(status)


def _via_outbounds():
    """What `apps run --via` takes: {tag: {...}}, the "interface" AmneziaWG outbounds, which
    the app's packets enter directly: declared ones, and those added at runtime."""
    outbounds = read_json_or(env("PER_APP_VIA_FILE"), {})
    if env("PER_APP_VIA_RUNTIME") == "1":
        try:
            names = os.listdir(_runtime_dir("outbound"))
        except OSError:
            names = []
        for name in names:
            if name.endswith(".iface"):
                outbounds.setdefault(name[: -len(".iface")], {"runtime": True})
    return outbounds


def _via_key(tag):
    """The units' instance for tag. In hex: a "-" in a tag would nest one slice in another's."""
    return "awg-" + tag.encode().hex()


# Routes that take any outbound through a pin slot, and the flag that says this host has them.
PIN_ROUTES = {"tun": "PER_APP_PIN_TUN", "tproxy": "PER_APP_PIN_TPROXY"}


def _pin_routes():
    return [route for route, flag in PIN_ROUTES.items() if env(flag) == "1"]


def _run_via(tag, label, cmd, route=""):
    """Runs cmd with all its traffic through tag, past the routing rules: into an "interface"
    AmneziaWG outbound's interface directly, with its DNS; else through a pin slot of per-app
    TUN or TProxy (route; TUN when both are there), whose selector sends it to tag. A global
    AmneziaWG profile is brought up apart for the apps (proxy-suite-awg-app@), as an
    "interface" outbound has it, unless it is up globally already.

    tag may say which it is, "awg:<profile>" or "outbound:<tag>"; a bare name that is both
    is refused. Neither a tag nor a profile name has a colon."""
    kind, name = tag.split(":", 1) if ":" in tag else ("", tag)
    if kind not in ("", "awg", "outbound") or not name:
        die(f"--via takes an outbound, awg:<profile> or outbound:<tag>, not '{tag}'.")
    label = name if label == tag else label
    profiles = _awg_profiles() if env("PER_APP_VIA_PROFILES") == "1" else []
    is_profile = kind != "outbound" and name in profiles
    if kind == "awg" and not is_profile:
        die(f"No global AmneziaWG profile '{name}' to run apps through. See: proxy-ctl awg")
    if not kind and is_profile and (name in _via_outbounds() or name in _outbound_tags()):
        die(f"'{name}' is both a global AmneziaWG profile and an outbound: say --via awg:{name} or --via outbound:{name}.")
    tag = name
    before = ()
    if not is_profile and tag in _via_outbounds():
        key = _via_key(tag)
        unit, global_units = f"proxy-suite-per-app-via@{key}.service", ("proxy-suite-tun",)
    elif is_profile:
        key = f"app-{tag.encode().hex()}"
        unit = f"proxy-suite-per-app-via@{key}.service"
        # Up globally, it carries the app already.
        global_units = ("proxy-suite-tun", _awg_service(tag))
        before = (f"proxy-suite-awg-app@{tag}.service",)
    else:
        routes = _pin_routes()
        route = route or next(iter(routes), "")
        if route not in routes:
            interfaces = ", ".join(sorted(_via_outbounds())) or "none"
            why = (
                f"no pin slots of per-app {route} here (perAppRouting.{route}.enable, the sing-box or hybrid backend)"
                if route
                else "this configuration has no pin slots: per-app TUN or TProxy, with the sing-box or hybrid backend"
            )
            die(f"Cannot run via '{tag}': {why}. \"interface\" AmneziaWG outbounds: {interfaces}.")
        tags = _outbound_tags()
        if tags and tag not in {*tags, *_outbound_groups(), "proxy", "direct", "block"}:
            die(f"Unknown outbound: {tag}. See: proxy-ctl proxy outbounds")
        key = f"{route}-{tag.encode().hex()}"
        unit = f"proxy-suite-per-app-via-{route}@{tag.encode().hex()}.service"
        global_units = ("proxy-suite-tun", "proxy-suite-tproxy")
    # A global mode takes the app past the per-app rules; run it as it is rather than refuse,
    # like the other per-app routes.
    active = next((u for u in global_units if svc_active(f"{u}.service")), "")
    if active:
        print(f"warning: {active}.service is active and carries the app already; running it without --via {tag}.", file=sys.stderr)
        _exec(list(cmd))
    uid = os.getuid()
    # The via unit, which the marking unit cannot name; it goes after the last user's
    # marking (per-app-routing/via.nix), with the profile brought up for it.
    _wrap_slice(
        f"proxy-suite-per-app-via-{key}",
        label,
        list(cmd),
        (
            f"proxy-suite-per-app-via-anchor@{key}.service",
            f"proxy-suite-per-app-via-user@{uid}-{key}.service",
        ),
        before=(*before, unit),
    )


def cmd_apps(verb="list", *args):
    _ensure_app_routing()
    if verb == "list":
        profiles = _per_app_profiles()
        if not profiles:
            print("No perAppRouting profiles configured.")
            return
        print(f"  {'PROFILE':<24} {'ROUTE':<12} {'VIA':<16} SOURCE")
        for p in profiles:
            source = "runtime" if p.get("runtime") else "declared"
            print(f"  {_s(p.get('name')):<24} {_s(p.get('route')):<12} {_s(p.get('outbound') or '-'):<16} {source}")
    elif verb == "run":
        cmd_apps_run(*args)
    elif verb == "add":
        _apps_add(*args)
    elif verb in ("rm", "remove", "del"):
        _apps_rm(*args)
    else:
        usage(f"apps [list] | {APPS_RUN_USAGE} | {APPS_ADD_USAGE} | rm <name>")


APPS_RUN_USAGE = "run <profile> -- <cmd> [args] | run --via <outbound> [--route tun|tproxy] -- <cmd> [args]"


def cmd_apps_run(*args):
    profile, via, route = "", "", ""
    args = list(args)
    # --via <outbound> [--route tun|tproxy], before the command.
    while args[:1] in (["--via"], ["--route"]):
        if len(args) < 2 or not args[1]:
            usage(f"apps {APPS_RUN_USAGE}")
        if args[0] == "--via":
            via = args[1]
        else:
            route = args[1]
        del args[:2]
    if route and route not in PIN_ROUTES:
        die(f"--route is tun or tproxy, not '{route}'.")
    if not via:
        profile, args = (args[0], args[1:]) if args and not route else ("", args)
    cmd = args[1:] if args[:1] == ["--"] else args
    if not (profile or via) or not cmd:
        usage(f"apps {APPS_RUN_USAGE}")
    if via:
        _run_via(via, via, cmd, route)

    entry = next((p for p in _per_app_profiles() if p.get("name") == profile), None)
    if entry is None:
        die(f"Unknown perAppRouting profile: {profile}")
    route = _s(entry.get("route"))
    if entry.get("outbound"):
        _run_via(_s(entry["outbound"]), profile, cmd, route if route in PIN_ROUTES else "")

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
        # The global mode already carries the app's traffic, and wrapPerApp launchers must
        # still start the app: run it as it is rather than refuse.
        global_svc = _active_global_proxy(route)
        if global_svc:
            print(f"warning: {global_svc}.service is active and carries the app already; running it without route={route}.", file=sys.stderr)
            _exec(list(cmd))
        if env(enabled) != "1":
            die(f"Profile '{profile}' uses route={route}, but {option} is false.")
        # zapret's route sends the app direct anyway: its lookups go the same way.
        if route != "zapret":
            _warn_nscd(route)
        _wrap_slice(slice_base, profile, list(cmd))
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
    """variant "onion": the link to the listener through the onion service; any other: the
    listener's share variant of that name."""
    matches = [
        x
        for x in _inbound_links()
        if x.get("tag") == tag and (not user or x.get("user") == user) and (x.get("variant") or "") == variant
    ]
    if not matches:
        if variant == "onion":
            die(f"No onion link for {tag}: is it in tor.onionService.listeners, and has Tor written its address?")
        if variant:
            die(f"No share variant '{variant}' for {tag}: see its shareVariants, or `proxy-ctl inbounds list`.")
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
# How old the collector's reading of who is online may be: two of its timer's runs.
ONLINE_READING_SECONDS = 600


def _inbound_presence():
    """(user -> (state, addresses), links readable): "online", "seen <time>" or "never seen".

    Who is online and from where is as private as the traffic stats, so it takes the
    same read access; dies without it, or when the stats API is silent. Who cannot reach the
    API (it may reset the counters) gets the collector's last reading, refreshed first.
    """
    stats_path = env("INBOUNDS_STATS_FILE", f"{state_dir()}/inbound-stats.json")
    if os.path.exists(stats_path) and not readable(stats_path):
        denied(stats_path)
    api = env("INBOUNDS_API", f"unix://{runtime_dir()}/proxy-suite-inbounds/api/stats.sock")
    # Users nobody has seen yet, when the links say who exists.
    path = env("INBOUNDS_LINKS_FILE")
    links = read_json(path) if readable(path) else []
    known = {_s(x.get("user")) for x in links if x.get("user")}
    sock = api.removeprefix("unix://")
    try:
        os.stat(sock)
        reachable = os.access(sock, os.W_OK)
    except FileNotFoundError:
        die("The inbounds' stats API is not answering - is proxy-suite-inbounds running?")
    except OSError:
        reachable = False  # its directory is the daemon's alone
    if reachable:
        status, out = _run(
            [env("INBOUNDS_XRAY", "xray"), "api", "statsonlineiplist", f"--server={api}", "-all"],
            capture=True,
            quiet=True,
        )
        if status != 0:
            die("The inbounds' stats API is not answering - is proxy-suite-inbounds running?")
        try:
            users = json.loads(out or "{}").get("users") or []
        except (ValueError, AttributeError):
            die("Unexpected answer from the inbounds' stats API.")
        # AmneziaWG peers are only known by their last handshake, which the collector reads;
        # the XRay API already told who else is online now.
        if any(x.get("type") == "amneziawg" for x in links):
            systemctl("--no-ask-password", "start", "proxy-suite-inbound-stats.service", quiet=True)
        stats = read_json(stats_path) if readable(stats_path) else {}
    else:
        systemctl("--no-ask-password", "start", "proxy-suite-inbound-stats.service", quiet=True)
        stats = read_json(stats_path) if readable(stats_path) else {}
        # The collector writes only when the API answered: an old reading means it did not.
        at = stats.get("at") or 0
        if "online" not in stats or time.time() - at > ONLINE_READING_SECONDS:
            die("The inbounds' stats API is not answering - is proxy-suite-inbounds running?")
        users = stats.get("online") or []
        if time.time() - at > 60:
            print(f"Online as of {datetime.datetime.fromtimestamp(at):%H:%M}, the collector's last reading.", file=sys.stderr)
    try:
        online = {_s(u.get("email")): u.get("ips") or [] for u in users}
    except (TypeError, AttributeError):
        die("Unexpected answer from the inbounds' stats API.")
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
    return presence, not path or readable(path)


def _inbound_online():
    """Users connected right now with their addresses, then when the others were last seen."""
    row = "  {:<20} {:<24} {}"
    presence, links_read = _inbound_presence()
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
    if not links_read:
        print(f"Users never seen are left out: the share links name them - {ask_group()}.", file=sys.stderr)


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


# --- runtime inbound users and listeners ---------------------------------------
#
# inbounds.runtime: users/<name>.json and listeners/<tag>.json in a spool the "inbounds" scope
# may write. scripts/inbound_runtime.py checks and writes them, with what the spec allows;
# the reload unit restarts the inbounds, which merge them in when they start.

def _inbound_runtime(*args, stdin=None, quiet=False, listing=False):
    """scripts/inbound_runtime.py with the spec: its output, or its complaint as ours.

    listing: a read, which works without inbounds.runtime (the declared users and listeners).
    """
    if not (listing and env("INBOUNDS_ENABLED") == "1") and env("INBOUNDS_RUNTIME_ENABLED") != "1":
        die("Runtime inbound users and listeners are not enabled in this configuration (inbounds.runtime.enable).")
    argv = [sys.executable, env("INBOUNDS_RUNTIME_TOOL"), "--spec", env("INBOUNDS_SPEC_FILE"), "--xray", env("INBOUNDS_XRAY", "xray"), *args]
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    except OSError as e:
        die(f"Cannot run {argv[1]}: {e}")
    if p.returncode and not quiet:
        message = p.stderr.strip() or f"{argv[1]} exited with {p.returncode}"
        die(f"{message} - {ask_group()}." if p.returncode == 77 else message)
    if not quiet and p.stderr:
        sys.stderr.write(p.stderr)
    return p.returncode, p.stdout


def _inbound_runtime_rows(kind):
    """Users or listeners, declared and runtime, as the tool lists them; [] when it cannot."""
    if env("INBOUNDS_ENABLED") != "1":
        return []
    status, out = _inbound_runtime(kind, "--json", quiet=True, listing=True)
    try:
        rows = json.loads(out) if not status else []
    except ValueError:
        rows = []
    return rows if isinstance(rows, list) else []


def _inbound_runtime_names(kind, source=""):
    key = "name" if kind == "users" else "tag"
    return {_s(r[key]): _s(r.get("source") or "") for r in _inbound_runtime_rows(kind) if not source or r.get("source") == source}


def _inbound_runtime_change(*args, stdin=None):
    """A change to the spool, then the reload that applies it, then what it left out."""
    _, out = _inbound_runtime(*args, stdin=stdin)
    sys.stdout.write(out)
    if systemctl("start", "proxy-suite-inbounds-reload.service")[0]:
        die("Saved, but applying it failed - see: proxy-ctl logs proxy-suite-inbounds-reload")
    p = subprocess.run(
        [sys.executable, env("INBOUNDS_RUNTIME_TOOL"), "--spec", env("INBOUNDS_SPEC_FILE"), "check"],
        capture_output=True,
        text=True,
    )
    for line in lines(p.stderr):
        print(f"warning: {line}", file=sys.stderr)


def _inbound_users(verb="list", *args):
    if verb in ("list", "--json"):
        sys.stdout.write(_inbound_runtime("users", *(["--json"] if "--json" in (verb, *args) else []), listing=True)[1])
    elif verb == "add" and args:
        _inbound_runtime_change("users", "add", *args)
    elif verb == "rm" and len(args) == 1:
        _inbound_runtime_change("users", "rm", *args)
    elif verb == "order" and len(args) == 2:
        _inbound_runtime_change("users", "order", *args)
    else:
        usage("inbounds users [list] | add <name> [--order N] [--listener <tag>]... | rm <name> | order <name> <N>")


def cmd_inbounds(verb="list", *args):
    require_enabled("INBOUNDS_ENABLED", "inbounds")
    if verb == "users":
        _inbound_users(*args)
        return
    if verb in ("bind", "unbind"):
        if len(args) != 2:
            usage(f"inbounds {verb} <user> <tag>")
        _inbound_runtime_change(verb, *args)
        return
    if verb == "add":
        if "--help" in args or "-h" in args:
            sys.stdout.write(_inbound_runtime("add", "--help")[1])
            return
        if len(args) < 2:
            usage("inbounds add <tag> <type> [flags] | <tag> <file.json|->")
        _inbound_runtime_change("add", *args, stdin=sys.stdin.read() if args[1:2] == ("-",) else None)
        return
    if verb == "rm":
        if len(args) != 1:
            usage("inbounds rm <tag>")
        _inbound_runtime_change("rm", *args)
        return
    if verb == "show":
        if len(args) != 1:
            usage("inbounds show <tag>")
        sys.stdout.write(_inbound_runtime("show", *args)[1])
        return
    if verb == "list":
        state = svc_state("proxy-suite-inbounds")
        # Which listeners were added at runtime, when they can be.
        sources = _inbound_runtime_names("listeners") if env("INBOUNDS_RUNTIME_ENABLED") == "1" else {}
        row = "  {:<24} {:<16} {:<14} {:<8} {:<8}" + (" {}" if sources else "")
        print(row.format("TAG", "USER", "TYPE", "PORT", "STATE", "SOURCE").rstrip())
        for x in _inbound_links():
            kind = _s(x.get("type")) + (f" ({_s(x.get('variant'))})" if x.get("variant") else "")
            tag = _s(x.get("tag"))
            print(row.format(tag, _s(x.get("user")), kind, _s(x.get("port")), state, sources.get(tag, "nix")).rstrip())
    elif verb in ("link", "qr"):
        rest = [a for a in args if not a.startswith("--")]
        if not rest:
            usage("inbounds link <tag> [user] [--onion|--variant=<name>] [--qr|--json|--config|--server-json]")
        qr = verb == "qr" or "--qr" in args
        variant = "onion" if "--onion" in args else ""
        for a in args:
            if a.startswith("--variant="):
                variant = a[len("--variant=") :]
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


LOGS_BACKLOG = 1000


def cmd_logs(*units):
    # One --unit per unit: a bare second name would be taken as a journal match. journalctl
    # takes unit globs, so the default needs no unit list of its own.
    argv = _manager_argv(
        "journalctl",
        ["-f", "-n", str(LOGS_BACKLOG), *(f"--unit={u}" for u in units or ["proxy-suite-*"])],
    )
    viewer = _log_viewer()
    if not (viewer and sys.stdin.isatty() and sys.stdout.isatty()):
        _exec(argv)
    sys.exit(_follow_in_pager(argv, viewer))


def _log_viewer():
    """The argv that follows logs on its stdin in a terminal: lnav, or less where it is missing.

    lnav follows while at the bottom: scrolling back pauses it, G follows again, q or Ctrl-C
    quits. less starts following (+F): Ctrl-C stops to scroll back, F follows again, q quits.
    """
    lnav = shutil.which("lnav")
    if lnav:
        return [lnav, "-q"]
    less = shutil.which("less")
    return [less, "-R", "-M", "+F"] if less else None


def _follow_in_pager(argv, viewer):
    """argv's output in viewer, the argv of a pager that reads its stdin.

    argv runs in a session of its own, so Ctrl-C reaches the viewer alone.
    """
    sys.stdout.flush()
    old = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        source = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            # journalctl colors only a terminal; lnav and less -R show them.
            env={**os.environ, "SYSTEMD_COLORS": "1"},
        )
    except OSError as e:
        signal.signal(signal.SIGINT, old)
        die(f"proxy-ctl: {argv[0]}: {e.strerror}", 127)
    try:
        return subprocess.call(viewer, stdin=source.stdout)
    finally:
        source.stdout.close()
        source.terminate()
        source.wait()
        signal.signal(signal.SIGINT, old)


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
    "killswitch": lambda *args: _toggle(KILL_SWITCH, "killswitch", *args),
    "ssh": lambda *args: _toggle("proxy-suite-ssh-proxy", "ssh", *args),
    "warp": cmd_warp,
    "tor": cmd_tor,
    "tg": lambda *args: _toggle("proxy-suite-tg-ws-proxy", "tg", *args),
    "wl": cmd_wl,
    "apps": cmd_apps,
    "inbounds": cmd_inbounds,
    "where": cmd_where,
    "__complete": cmd_complete,
}


# Control characters but tab and newline: C0, DEL and C1.
_UNPRINTABLE = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f]")


class _TerminalSafe:
    """A terminal stream that shows control characters rather than obeying them.

    Much of what proxy-ctl prints comes from elsewhere: share links a subscription served,
    entries the userControl group wrote. An escape sequence among them could set the
    clipboard or rewrite the screen of whoever reads it, root included. proxy-ctl prints
    none of its own.
    """

    def __init__(self, stream):
        self._stream = stream

    def write(self, text):
        return self._stream.write(_UNPRINTABLE.sub(lambda m: f"\\x{ord(m.group()):02x}", text))

    def __getattr__(self, name):
        return getattr(self._stream, name)


def main(argv):
    # Die quietly on a closed pipe (`proxy-ctl help | head`), as a shell tool does.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    for name in ("stdout", "stderr"):
        stream = getattr(sys, name)
        if stream.isatty():
            setattr(sys, name, _TerminalSafe(stream))
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
