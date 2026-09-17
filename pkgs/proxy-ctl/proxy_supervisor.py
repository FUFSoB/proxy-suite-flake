#!/usr/bin/env python3
"""proxy-suitectl: a service supervisor for hosts without systemd (nix-on-droid).

It runs the units the Nix module renders for a user manager, read from a JSON manifest
({"services": {name: {"Unit", "Service", "Install"}}, "timers": ..., "paths": ...,
"tmpfiles": [...]}), and answers the subset of systemctl and journalctl that proxy-ctl
and the suite's own scripts use, so both only swap the binary:

    proxy-suitectl ensure | boot | reload | shutdown | daemon
    proxy-suitectl start|stop|restart|try-restart|is-active|show|cat|status|list-timers ...
    proxy-suitectl journal [-u UNIT]... [-f] [-n N] [--since TIME] [-o cat]

One daemon per user owns the processes: it starts on the first command that needs it,
restarts services after Restart=, fires timers and path units, and writes each unit's
output to its own log. Nothing here needs root.
"""

import datetime
import fcntl
import fnmatch
import json
import os
import random
import re
import resource
import shlex
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time

SUPERVISOR_DIR = os.environ.get("PROXY_SUITE_SUPERVISOR_DIR") or os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or os.path.expanduser("~/.cache"), "proxy-suite-supervisor"
)
MANIFEST = os.environ.get("PROXY_SUITE_MANIFEST", "")
SOCKET = os.path.join(SUPERVISOR_DIR, "control.sock")
LOCK = os.path.join(SUPERVISOR_DIR, "daemon.lock")
LOG_DIR = os.path.join(SUPERVISOR_DIR, "logs")
CREDENTIALS_DIR = os.path.join(SUPERVISOR_DIR, "credentials")
LOG_LIMIT = 1024 * 1024
STOP_TIMEOUT = 15
# Stand-ins for the targets a user manager reaches at login.
BOOT_TARGETS = {"default.target", "multi-user.target", "timers.target", "paths.target"}
ACTIVE, ACTIVATING, DEACTIVATING, INACTIVE, FAILED = "active", "activating", "deactivating", "inactive", "failed"
AUTO_RESTART = "auto-restart"


# --- manifest -------------------------------------------------------------------


def load_manifest(path=None):
    path = path or MANIFEST
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return {
        "services": data.get("services") or {},
        "timers": data.get("timers") or {},
        "paths": data.get("paths") or {},
        "tmpfiles": data.get("tmpfiles") or [],
    }


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def split_name(name):
    """(kind, base, instance): 'x@a.service' -> ('service', 'x@', 'a')."""
    kind = "service"
    for suffix in ("service", "timer", "path", "target"):
        if name.endswith("." + suffix):
            kind, name = suffix, name[: -len(suffix) - 1]
            break
    if "@" in name and not name.endswith("@"):
        base, instance = name.split("@", 1)
        return kind, base + "@", instance
    return kind, name, None


def full_name(name, kind="service"):
    _, base, instance = split_name(name)
    return f"{base}{instance or ''}.{kind}"


def unescape(text):
    """systemd-escape --unescape: '-' is '/', \\xNN a byte."""
    raw = text.replace("-", "/").encode()
    return re.sub(rb"\\x([0-9a-fA-F]{2})", lambda m: bytes([int(m.group(1), 16)]), raw).decode(errors="replace")


TIMESPAN_UNITS = {
    "us": 1e-6, "usec": 1e-6, "ms": 1e-3, "msec": 1e-3,
    "s": 1, "sec": 1, "second": 1, "seconds": 1,
    "m": 60, "min": 60, "minute": 60, "minutes": 60,
    "h": 3600, "hr": 3600, "hour": 3600, "hours": 3600,
    "d": 86400, "day": 86400, "days": 86400,
    "w": 604800, "week": 604800, "weeks": 604800,
    "M": 2629800, "month": 2629800, "months": 2629800,
    "y": 31557600, "year": 31557600, "years": 31557600,
}


def timespan(value):
    """Seconds in a systemd time span ("5m", "1h 30min", 90)."""
    if isinstance(value, (int, float)):
        return float(value)
    total, matched = 0.0, False
    for number, unit in re.findall(r"(\d+(?:\.\d+)?)\s*([a-zA-Z]*)", str(value)):
        total += float(number) * TIMESPAN_UNITS.get(unit or "s", 1)
        matched = True
    if not matched:
        raise ValueError(f"not a time span: {value}")
    return total


# --- logs -----------------------------------------------------------------------

_log_locks = {}
_log_locks_guard = threading.Lock()


def log_path(unit):
    """A unit's log; services go by their bare name, as journalctl -u takes it."""
    if unit.endswith(".service"):
        unit = unit[: -len(".service")]
    return os.path.join(LOG_DIR, f"{unit}.log")


def append_log(unit, text):
    with _log_locks_guard:
        lock = _log_locks.setdefault(unit, threading.Lock())
    path = log_path(unit)
    with lock:
        try:
            if os.path.getsize(path) > LOG_LIMIT:
                os.replace(path, path + ".1")
        except OSError:
            pass
        with open(path, "a", encoding="utf-8") as f:
            for line in text.splitlines() or [""]:
                f.write(f"{time.time():.6f}\t{line}\n")


def pump(unit, stream):
    for raw in iter(stream.readline, b""):
        append_log(unit, raw.decode(errors="replace").rstrip("\n"))
    stream.close()


# --- units ----------------------------------------------------------------------


class Unit:
    """One service instance and what the daemon knows of it."""

    def __init__(self, name, definition):
        self.name = name  # full name: x.service, x@a.service
        self.definition = definition
        self.state = INACTIVE
        self.result = "success"
        self.main = None
        self.current = None
        self.stopping = False
        self.cancel = threading.Event()
        self.job = threading.RLock()
        self.done = threading.Condition()
        self.last_activated = None

    @property
    def unit(self):
        return self.definition.get("Unit") or {}

    @property
    def service(self):
        return self.definition.get("Service") or {}

    def public_state(self):
        return ACTIVATING if self.state == AUTO_RESTART else self.state

    def set_state(self, state):
        with self.done:
            self.state = state
            self.done.notify_all()


class Timer:
    def __init__(self, name, definition):
        self.name = name
        self.definition = definition
        self.active = False
        self.activated = None
        self.fired = set()
        self.last = None
        self.jitter = 0.0

    @property
    def config(self):
        return self.definition.get("Timer") or {}

    def target(self):
        return (self.definition.get("Timer") or {}).get("Unit") or self.name.replace(".timer", ".service")


class PathWatch:
    def __init__(self, name, definition):
        self.name = name
        self.definition = definition
        self.active = False
        self.seen = {}

    @property
    def config(self):
        return self.definition.get("Path") or {}

    def target(self):
        return self.config.get("Unit") or self.name.replace(".path", ".service")


def signature(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_ino, st.st_size, st.st_mtime_ns)


class Supervisor:
    def __init__(self, manifest_path=None):
        self.manifest_path = manifest_path or MANIFEST
        self.manifest = load_manifest(self.manifest_path)
        self.units = {}
        self.timers = {}
        self.paths = {}
        self.guard = threading.RLock()
        self.started_at = time.time()
        self.booted = False
        self.quit = threading.Event()

    # lookups

    def definition(self, name):
        kind, base, _ = split_name(name)
        return self.manifest[kind + "s"].get(base) if kind in ("service", "timer", "path") else None

    def instance(self, name):
        """The Unit for a service name, created on first use; None when the manifest lacks it."""
        name = full_name(name)
        with self.guard:
            unit = self.units.get(name)
            if unit is None:
                definition = self.definition(name)
                if definition is None:
                    return None
                unit = self.units[name] = Unit(name, definition)
            return unit

    # specifiers and commands

    def specifiers(self, unit, text):
        _, base, instance = split_name(unit.name)
        prefix = base.rstrip("@")
        table = {
            "i": instance or "",
            "I": unescape(instance or ""),
            "n": unit.name,
            "N": unit.name.rsplit(".", 1)[0],
            "p": prefix,
            "P": unescape(prefix),
            "h": os.path.expanduser("~"),
            "u": os.environ.get("USER", ""),
            "t": os.environ.get("PROXY_SUITE_RUNTIME_BASE", SUPERVISOR_DIR),
            "S": os.environ.get("PROXY_SUITE_STATE_BASE", os.path.expanduser("~/.local/state")),
            "%": "%",
        }
        return re.sub(r"%(.)", lambda m: table.get(m.group(1), m.group(0)), text)

    def environment(self, unit):
        env = dict(os.environ)
        for key in ("PROXY_SUITE_SUPERVISOR_DIR", "PROXY_SUITE_MANIFEST", "NOTIFY_SOCKET"):
            env.pop(key, None)
        for entry in as_list(unit.service.get("Environment")):
            for item in shlex.split(str(entry)):
                if "=" in item:
                    key, value = item.split("=", 1)
                    env[key] = self.specifiers(unit, value)
        if as_list(unit.service.get("LoadCredential")):
            env["CREDENTIALS_DIRECTORY"] = self.credentials_dir(unit)
        return env

    def credentials_dir(self, unit):
        return os.path.join(CREDENTIALS_DIR, unit.name)

    def load_credentials(self, unit):
        entries = as_list(unit.service.get("LoadCredential"))
        if not entries:
            return
        target = self.credentials_dir(unit)
        os.makedirs(target, mode=0o700, exist_ok=True)
        for entry in entries:
            ident, _, source = str(entry).partition(":")
            source = self.specifiers(unit, source or ident)
            with open(source, "rb") as f:
                data = f.read()
            path = os.path.join(target, ident)
            if os.path.exists(path):
                os.chmod(path, 0o600)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o400)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.chmod(path, 0o400)

    def drop_credentials(self, unit):
        target = self.credentials_dir(unit)
        if not os.path.isdir(target):
            return
        for entry in os.listdir(target):
            try:
                os.chmod(os.path.join(target, entry), 0o600)
                os.unlink(os.path.join(target, entry))
            except OSError:
                pass
        try:
            os.rmdir(target)
        except OSError:
            pass

    def spawn(self, unit, command, extra_env=None):
        """Popen for one Exec line, or (None, ignore_failure) when it is empty."""
        argv = [self.specifiers(unit, arg) for arg in shlex.split(str(command))]
        ignore = False
        while argv and argv[0][:1] in "-+!:@|" and argv[0]:
            ignore = ignore or argv[0][0] == "-"
            argv[0] = argv[0][1:]
            if not argv[0]:
                argv.pop(0)
        if not argv:
            return None, ignore
        env = self.environment(unit)
        env.update(extra_env or {})
        workdir = unit.service.get("WorkingDirectory")
        cwd = os.path.expanduser("~")
        if workdir:
            workdir = self.specifiers(unit, str(workdir))
            optional = workdir.startswith("-")
            workdir = workdir.lstrip("-")
            if os.path.isdir(workdir):
                cwd = workdir
            elif not optional:
                raise OSError(f"WorkingDirectory {workdir} does not exist")
        umask = unit.service.get("UMask")
        proc = subprocess.Popen(
            argv,
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            umask=int(str(umask), 8) if umask is not None else -1,
        )
        threading.Thread(target=pump, args=(unit.name, proc.stdout), daemon=True).start()
        return proc, ignore

    def run_commands(self, unit, key, extra_env=None):
        """Runs a unit's Exec lines in order; False when one fails (and does not ignore it)."""
        for command in as_list(unit.service.get(key)):
            try:
                proc, ignore = self.spawn(unit, command, extra_env)
            except OSError as e:
                append_log(unit.name, f"proxy-suitectl: {key}: {e}")
                return False
            if proc is None:
                continue
            unit.current = proc
            status = proc.wait()
            unit.current = None
            if status and not ignore:
                append_log(unit.name, f"proxy-suitectl: {key} exited with status {status}")
                return False
        return True

    @staticmethod
    def kill_group(proc, sig):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def terminate(self, proc):
        if proc is None:
            return
        self.kill_group(proc, signal.SIGTERM)
        try:
            proc.wait(STOP_TIMEOUT)
        except subprocess.TimeoutExpired:
            self.kill_group(proc, signal.SIGKILL)
            proc.wait()
        # What the main process left behind in its group.
        self.kill_group(proc, signal.SIGKILL)

    # jobs

    def deps(self, unit, *keys):
        return [d for key in keys for d in as_list(unit.unit.get(key)) if self.definition(d) is not None]

    def start(self, name, seen=None):
        """Starts a service (or timer/path unit) and what it pulls in: 0, or a systemctl status."""
        kind, _, _ = split_name(name)
        if kind == "timer":
            return self.start_timer(name)
        if kind == "path":
            return self.start_path(name)
        unit = self.instance(name)
        if unit is None:
            return 5
        seen = seen if seen is not None else set()
        if unit.name in seen:
            return 0
        seen.add(unit.name)
        for other in as_list(unit.unit.get("Conflicts")):
            if self.definition(other) is not None:
                self.stop(other)
        for dep in self.deps(unit, "Requires", "BindsTo"):
            if self.start(dep, seen):
                unit.result = "dependency"
                unit.set_state(FAILED)
                return 1
        for dep in self.deps(unit, "Wants"):
            self.start(dep, seen)
        return self.activate(unit)

    def activate(self, unit, restarting=False):
        with unit.job:
            if restarting and (unit.state != AUTO_RESTART or unit.cancel.is_set()):
                return 0
            if unit.state in (ACTIVE, ACTIVATING) or (unit.state == AUTO_RESTART and not restarting):
                return 0 if unit.state != ACTIVATING else self.wait_settled(unit)
            unit.stopping = False
            unit.cancel.clear()
            unit.last_activated = time.time()
            unit.set_state(ACTIVATING)
            service = unit.service
            kind = service.get("Type", "simple")
            try:
                self.load_credentials(unit)
            except OSError as e:
                append_log(unit.name, f"proxy-suitectl: LoadCredential: {e}")
                return self.fail(unit, "resources")
            if not self.run_commands(unit, "ExecStartPre"):
                return self.fail(unit, "exit-code")
            if kind in ("oneshot", "forking"):
                if not self.run_commands(unit, "ExecStart"):
                    return self.fail(unit, "exit-code")
                if unit.stopping:
                    return 0
                if not self.run_commands(unit, "ExecStartPost"):
                    return self.fail(unit, "exit-code")
                unit.result = "success"
                if service.get("RemainAfterExit") or kind == "forking":
                    unit.set_state(ACTIVE)
                else:
                    self.run_commands(unit, "ExecStopPost")
                    self.drop_credentials(unit)
                    unit.set_state(INACTIVE)
                return 0
            commands = as_list(service.get("ExecStart"))
            try:
                proc, _ = self.spawn(unit, commands[0]) if commands else (None, False)
            except OSError as e:
                append_log(unit.name, f"proxy-suitectl: ExecStart: {e}")
                return self.fail(unit, "exit-code")
            if proc is None:
                return self.fail(unit, "resources")
            unit.main = proc
            threading.Thread(target=self.watch, args=(unit, proc), daemon=True).start()
            if not self.run_commands(unit, "ExecStartPost", {"MAINPID": str(proc.pid)}):
                self.terminate(proc)
                return self.fail(unit, "exit-code")
            unit.result = "success"
            unit.set_state(ACTIVE)
            return 0

    def wait_settled(self, unit):
        with unit.done:
            unit.done.wait_for(lambda: unit.state != ACTIVATING)
        return 0 if unit.state == ACTIVE or unit.result == "success" else 1

    def fail(self, unit, result):
        unit.result = result
        self.run_commands(unit, "ExecStopPost", {"SERVICE_RESULT": result})
        self.drop_credentials(unit)
        unit.set_state(FAILED)
        return 1

    def watch(self, unit, proc):
        """After the main process exits on its own: stop commands, then Restart=."""
        status = proc.wait()
        with unit.job:
            if unit.stopping or unit.main is not proc:
                return
            service = unit.service
            unit.main = None
            if status == 0 and service.get("RemainAfterExit"):
                return
            env = {"SERVICE_RESULT": "success" if status == 0 else "exit-code", "EXIT_STATUS": str(status)}
            self.run_commands(unit, "ExecStop", env)
            self.kill_group(proc, signal.SIGKILL)
            self.run_commands(unit, "ExecStopPost", env)
            restart = service.get("Restart", "no")
            again = restart == "always" or (restart in ("on-failure", "on-abnormal", "on-abort") and status != 0)
            unit.result = "success" if status == 0 else "exit-code"
            if not again:
                self.drop_credentials(unit)
                unit.set_state(INACTIVE if status == 0 else FAILED)
                return
            append_log(unit.name, f"proxy-suitectl: exited with status {status}; restarting")
            unit.set_state(AUTO_RESTART)
        if unit.cancel.wait(timespan(service.get("RestartSec", 0.1))):
            return
        self.activate(unit, restarting=True)

    def stop(self, name):
        kind, _, _ = split_name(name)
        if kind == "timer":
            return self.stop_timer(name)
        if kind == "path":
            return self.stop_path(name)
        unit = self.units.get(full_name(name))
        if unit is None:
            return 0 if self.definition(name) is not None else 5
        unit.stopping = True
        unit.cancel.set()
        # Bound to this one: they go first.
        for other in list(self.units.values()):
            if other is not unit and other.state != INACTIVE:
                if unit.name in map(full_name, as_list(other.unit.get("PartOf")) + as_list(other.unit.get("BindsTo"))):
                    self.stop(other.name)
        if unit.current is not None:
            self.kill_group(unit.current, signal.SIGTERM)
        with unit.job:
            unit.stopping = True
            if unit.state in (INACTIVE, FAILED, AUTO_RESTART):
                unit.set_state(INACTIVE)
                return 0
            unit.set_state(DEACTIVATING)
            main, unit.main = unit.main, None
            env = {"MAINPID": str(main.pid)} if main else {}
            self.run_commands(unit, "ExecStop", env)
            self.terminate(main)
            self.run_commands(unit, "ExecStopPost", {"SERVICE_RESULT": "success"})
            self.drop_credentials(unit)
            unit.set_state(INACTIVE)
            unit.stopping = False
            return 0

    def restart(self, name, only_if_active=False):
        kind, _, _ = split_name(name)
        if kind != "service":
            return self.stop(name) or self.start(name)
        unit = self.units.get(full_name(name))
        if only_if_active and (unit is None or unit.state not in (ACTIVE, ACTIVATING, AUTO_RESTART)):
            return 0 if self.definition(name) is not None else 5
        status = self.stop(name)
        return status or self.start(name)

    # timers and paths

    def start_timer(self, name):
        name = full_name(name, "timer")
        definition = self.definition(name)
        if definition is None:
            return 5
        with self.guard:
            timer = self.timers.get(name)
            if timer is None or timer.definition is not definition:
                timer = self.timers[name] = Timer(name, definition)
            if not timer.active:
                timer.active, timer.activated, timer.fired = True, time.time(), set()
                timer.jitter = self.jitter(timer)
        return 0

    def stop_timer(self, name):
        timer = self.timers.get(full_name(name, "timer"))
        if timer:
            timer.active = False
        return 0

    @staticmethod
    def jitter(timer):
        spread = timer.config.get("RandomizedDelaySec")
        return random.uniform(0, timespan(spread)) if spread else 0.0

    def next_elapse(self, timer):
        config, candidates = timer.config, []
        if config.get("OnActiveSec") is not None and "active" not in timer.fired:
            candidates.append(("active", timer.activated + timespan(config["OnActiveSec"])))
        for key in ("OnBootSec", "OnStartupSec"):
            if config.get(key) is not None and "boot" not in timer.fired:
                candidates.append(("boot", self.started_at + timespan(config[key])))
        unit = self.units.get(full_name(timer.target()))
        if config.get("OnUnitActiveSec") is not None and unit and unit.last_activated:
            candidates.append(("unit", unit.last_activated + timespan(config["OnUnitActiveSec"])))
        if not candidates:
            return None, set()
        at = min(when for _, when in candidates)
        return at + timer.jitter, {base for base, when in candidates if when <= at}

    def start_path(self, name):
        name = full_name(name, "path")
        definition = self.definition(name)
        if definition is None:
            return 5
        with self.guard:
            watch = self.paths.get(name)
            if watch is None or watch.definition is not definition:
                watch = self.paths[name] = PathWatch(name, definition)
            if not watch.active:
                watch.active = True
                watch.seen = {p: signature(p) for key in ("PathChanged", "PathModified") for p in as_list(watch.config.get(key))}
        return 0

    def stop_path(self, name):
        watch = self.paths.get(full_name(name, "path"))
        if watch:
            watch.active = False
        return 0

    def in_background(self, fn, *args):
        threading.Thread(target=fn, args=args, daemon=True).start()

    def tick(self):
        now = time.time()
        for timer in list(self.timers.values()):
            if not timer.active:
                continue
            at, bases = self.next_elapse(timer)
            if at is None or at > now:
                continue
            timer.fired |= bases
            timer.last = now
            timer.jitter = self.jitter(timer)
            target = self.instance(timer.target())
            if target is not None:
                target.last_activated = now
                if target.state not in (ACTIVATING, AUTO_RESTART):
                    self.in_background(self.activate_fresh, target)
        for watch in list(self.paths.values()):
            if not watch.active:
                continue
            changed = False
            for path, before in list(watch.seen.items()):
                after = signature(path)
                if after != before:
                    watch.seen[path] = after
                    changed = True
            exists = any(os.path.exists(p) for p in as_list(watch.config.get("PathExists")))
            target = self.instance(watch.target())
            if target is not None and (changed or (exists and target.state == INACTIVE)):
                self.in_background(self.start, target.name)

    def activate_fresh(self, unit):
        """A timer's run: a oneshot left active by RemainAfterExit runs again."""
        if unit.state == ACTIVE and unit.service.get("Type") == "oneshot":
            self.stop(unit.name)
        self.start(unit.name)

    # boot, reload, shutdown

    def make_tmpfiles(self):
        for line in self.manifest["tmpfiles"]:
            fields = str(line).split()
            if len(fields) >= 2 and fields[0] in ("d", "D"):
                mode = int(fields[2], 8) if len(fields) > 2 and fields[2] != "-" else 0o755
                try:
                    os.makedirs(fields[1], exist_ok=True)
                    os.chmod(fields[1], mode)
                except OSError as e:
                    print(f"proxy-suitectl: tmpfiles: {fields[1]}: {e}", file=sys.stderr)

    def boot_units(self):
        """The units a login would start, services ordered by After=."""
        wanted = []
        for kind in ("services", "timers", "paths"):
            for base, definition in self.manifest[kind].items():
                if base.endswith("@"):
                    continue
                if BOOT_TARGETS & set(as_list((definition.get("Install") or {}).get("WantedBy"))):
                    wanted.append(f"{base}.{kind[:-1]}")
        order, visiting = [], set()

        def visit(name):
            if name in order or name in visiting:
                return
            visiting.add(name)
            definition = self.definition(name) or {}
            for dep in as_list((definition.get("Unit") or {}).get("After")):
                if full_name(dep) in wanted:
                    visit(full_name(dep))
            order.append(name)

        for name in wanted:
            visit(name)
        return order

    def boot(self):
        self.make_tmpfiles()
        self.booted = True
        return max([self.start(name) for name in self.boot_units()] or [0])

    def reload(self, restart_changed=False):
        old = self.manifest
        self.manifest = load_manifest(self.manifest_path)
        if not restart_changed:
            for unit in self.units.values():
                unit.definition = self.definition(unit.name) or unit.definition
            return 0
        self.make_tmpfiles()
        status = 0
        for unit in list(self.units.values()):
            new = self.definition(unit.name)
            running = unit.state not in (INACTIVE, FAILED)
            if new is None:
                if running:
                    self.stop(unit.name)
                del self.units[unit.name]
            elif new != unit.definition:
                unit.definition = new
                if running:
                    status = self.restart(unit.name) or status
        for table, kind in ((self.timers, "timers"), (self.paths, "paths")):
            for name, item in list(table.items()):
                base = split_name(name)[1]
                if base not in self.manifest[kind]:
                    del table[name]
                elif self.manifest[kind][base] != old[kind].get(base) and item.active:
                    table[name].active = False
                    self.start(name)
        if self.booted:
            for name in self.boot_units():
                kind = split_name(name)[0]
                if kind == "service":
                    unit = self.instance(name)
                    if unit.state == INACTIVE and unit.last_activated is None:
                        status = self.start(name) or status
                else:
                    status = self.start(name) or status
        return status

    def shutdown(self):
        for timer in self.timers.values():
            timer.active = False
        for watch in self.paths.values():
            watch.active = False
        active = [u for u in self.units.values() if u.state not in (INACTIVE, FAILED)]
        for unit in sorted(active, key=lambda u: u.last_activated or 0, reverse=True):
            self.stop(unit.name)
        self.quit.set()

    # queries

    def state_of(self, name):
        kind, _, _ = split_name(name)
        if self.definition(name) is None:
            return "not-found", INACTIVE, "dead"
        if kind == "timer":
            timer = self.timers.get(full_name(name, "timer"))
            return ("loaded", ACTIVE, "waiting") if timer and timer.active else ("loaded", INACTIVE, "dead")
        if kind == "path":
            watch = self.paths.get(full_name(name, "path"))
            return ("loaded", ACTIVE, "waiting") if watch and watch.active else ("loaded", INACTIVE, "dead")
        unit = self.units.get(full_name(name))
        if unit is None:
            return "loaded", INACTIVE, "dead"
        sub = {ACTIVE: "running" if unit.main else "exited", AUTO_RESTART: "auto-restart", ACTIVATING: "start"}
        return "loaded", unit.public_state(), sub.get(unit.state, "dead" if unit.state == INACTIVE else unit.state)

    def properties(self, name):
        kind = split_name(name)[0]
        load, active, sub = self.state_of(name)
        definition = self.definition(name) or {}
        unit = self.units.get(full_name(name)) if kind == "service" else None
        return {
            "Id": full_name(name, kind),
            "Description": (definition.get("Unit") or {}).get("Description", ""),
            "LoadState": load,
            "ActiveState": active,
            "SubState": sub,
            "Result": unit.result if unit else "success",
            "MainPID": str(unit.main.pid if unit and unit.main else 0),
        }

    def list_timers(self, names):
        rows = []
        for name, timer in sorted(self.timers.items()):
            if names and name not in map(lambda n: full_name(n, "timer"), names):
                continue
            if not timer.active:
                continue
            at, _ = self.next_elapse(timer)
            rows.append({
                "next": int(at * 1e6) if at else None,
                "left": int(max(0, at - time.time()) * 1e6) if at else None,
                "last": int(timer.last * 1e6) if timer.last else None,
                "passed": int((time.time() - timer.last) * 1e6) if timer.last else None,
                "unit": name,
                "activates": full_name(timer.target()),
            })
        return rows


# --- daemon ---------------------------------------------------------------------


class short_socket_path:
    """SOCKET, reached through a descriptor of its directory when the whole path is longer
    than a socket address holds (108 bytes; a deep home directory gets there)."""

    def __enter__(self):
        self.fd = None
        if len(os.fsencode(SOCKET)) < 100:
            return SOCKET
        self.fd = os.open(SUPERVISOR_DIR, os.O_RDONLY | os.O_DIRECTORY)
        return f"/proc/self/fd/{self.fd}/{os.path.basename(SOCKET)}"

    def __exit__(self, *_):
        if self.fd is not None:
            os.close(self.fd)


def handle(supervisor, request):
    """(status, output) for one client request."""
    verb, units, opts = request["verb"], request.get("units", []), request.get("options", {})
    out = []
    if verb == "start":
        if opts.get("no_block"):
            for name in units:
                supervisor.in_background(supervisor.start, name)
            return 0, ""
        status = 0
        for name in units:
            result = supervisor.start(name)
            if result == 5:
                out.append(f"Failed to start {full_name(name, split_name(name)[0])}: Unit not found.")
            elif result:
                out.append(f"Job for {full_name(name, split_name(name)[0])} failed. See \"proxy-ctl logs {split_name(name)[1]}\".")
            status = status or result
        return status, "\n".join(out)
    if verb in ("stop", "restart", "try-restart"):
        status = 0
        for name in units:
            if verb == "stop":
                result = supervisor.stop(name)
            else:
                result = supervisor.restart(name, only_if_active=verb == "try-restart")
            status = status or result
        return status, ""
    if verb == "reset-failed":
        for unit in supervisor.units.values():
            if unit.state == FAILED and (not units or unit.name in map(full_name, units)):
                unit.set_state(INACTIVE)
        return 0, ""
    if verb == "is-active":
        states = [supervisor.state_of(name)[1] for name in units]
        return (0 if ACTIVE in states else 3), "\n".join(states)
    if verb == "is-failed":
        states = [supervisor.state_of(name)[1] for name in units]
        return (0 if FAILED in states else 1), "\n".join(states)
    if verb == "show":
        wanted = opts.get("properties") or ["Id", "Description", "LoadState", "ActiveState", "SubState", "Result", "MainPID"]
        blocks = []
        for name in units:
            props = supervisor.properties(name)
            lines = [props.get(p, "") if opts.get("value") else f"{p}={props.get(p, '')}" for p in wanted]
            blocks.append("\n".join(lines))
        return 0, "\n\n".join(blocks)
    if verb == "list-timers":
        return 0, json.dumps(supervisor.list_timers(units))
    if verb == "status":
        names = units or [u.name for u in supervisor.units.values()]
        status = 0
        for name in names:
            props = supervisor.properties(name)
            if props["LoadState"] == "not-found":
                out.append(f"Unit {props['Id']} could not be found.")
                status = 4
                continue
            out.append(f"* {props['Id']} - {props['Description']}")
            out.append(f"     Active: {props['ActiveState']} ({props['SubState']})")
            if props["MainPID"] != "0":
                out.append(f"   Main PID: {props['MainPID']}")
            out.extend(f"  {line}" for line in journal_lines([props["Id"].rsplit(".", 1)[0]], count=10, fmt="short"))
            if props["ActiveState"] != ACTIVE:
                status = status or 3
        return status, "\n".join(out)
    if verb == "daemon-reload":
        return supervisor.reload(), ""
    if verb == "reload":
        return supervisor.reload(restart_changed=True), ""
    if verb == "boot":
        # Again (a switch): what changed restarts, what is new starts.
        if supervisor.booted:
            return supervisor.reload(restart_changed=True), ""
        return supervisor.reload() or supervisor.boot(), ""
    if verb == "shutdown":
        supervisor.in_background(supervisor.shutdown)
        return 0, ""
    if verb == "ping":
        return 0, "pong"
    return 1, f"proxy-suitectl: unknown verb {verb}"


def serve(manifest_path=None):
    os.makedirs(SUPERVISOR_DIR, mode=0o700, exist_ok=True)
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    lock = open(LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("proxy-suitectl: the supervisor is already running", file=sys.stderr)
        return 0
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
    except (ValueError, OSError):
        pass
    supervisor = Supervisor(manifest_path)
    try:
        os.unlink(SOCKET)
    except FileNotFoundError:
        pass

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            try:
                request = json.loads(self.rfile.readline())
                status, output = handle(supervisor, request)
            except Exception as e:  # a bad request must not take the daemon down
                status, output = 1, f"proxy-suitectl: {e}"
            try:
                self.wfile.write((json.dumps({"status": status, "output": output}) + "\n").encode())
            except OSError:
                pass

    class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True

    old_umask = os.umask(0o077)
    with short_socket_path() as address:
        server = Server(address, Handler)
    os.umask(old_umask)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: supervisor.in_background(supervisor.shutdown))
    signal.signal(signal.SIGINT, lambda *_: supervisor.in_background(supervisor.shutdown))
    signal.signal(signal.SIGHUP, lambda *_: supervisor.in_background(supervisor.reload))
    print(f"proxy-suitectl: supervising {supervisor.manifest_path}", file=sys.stderr)
    while not supervisor.quit.wait(1):
        try:
            supervisor.tick()
        except Exception as e:
            print(f"proxy-suitectl: {e}", file=sys.stderr)
    server.shutdown()
    try:
        os.unlink(SOCKET)
    except FileNotFoundError:
        pass
    return 0


# --- client ---------------------------------------------------------------------


def request(verb, units=(), options=None, spawn=False):
    """(status, output) from the daemon; None when it is not running (and not spawned)."""
    message = json.dumps({"verb": verb, "units": list(units), "options": options or {}}) + "\n"
    for attempt in range(100):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                with short_socket_path() as address:
                    sock.connect(address)
                sock.sendall(message.encode())
                with sock.makefile("rb") as f:
                    reply = json.loads(f.readline())
                return reply["status"], reply["output"]
        except (FileNotFoundError, ConnectionRefusedError, NotADirectoryError):
            if not spawn:
                return None
            if attempt == 0:
                start_daemon()
            time.sleep(0.1)
    print(f"proxy-suitectl: the supervisor did not come up; see {log_path('supervisor')}", file=sys.stderr)
    return 1, ""


def start_daemon():
    if not MANIFEST or not os.path.exists(MANIFEST):
        print(f"proxy-suitectl: no manifest at {MANIFEST or '(unset)'}: switch the configuration first", file=sys.stderr)
        sys.exit(1)
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    with open(log_path("supervisor"), "a") as log:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "daemon"],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
            cwd=os.path.expanduser("~"),
        )


def parse_systemctl(args):
    options, units, verb = {}, [], None
    it = iter(args)
    for arg in it:
        if arg == "--":
            units.extend(it)
            break
        if arg in ("--user", "--system", "--no-ask-password", "--no-pager", "--all", "-a", "--full", "-l"):
            continue
        if arg in ("-q", "--quiet"):
            options["quiet"] = True
        elif arg == "--no-block":
            options["no_block"] = True
        elif arg == "--value":
            options["value"] = True
        elif arg.startswith("--property=") or arg.startswith("-p") and len(arg) > 2:
            options.setdefault("properties", []).extend(arg.split("=", 1)[1].split(",") if arg.startswith("--") else arg[2:].split(","))
        elif arg in ("-p", "--property"):
            options.setdefault("properties", []).extend(next(it, "").split(","))
        elif arg in ("-o", "--output"):
            options["output"] = next(it, "")
        elif arg.startswith("--output="):
            options["output"] = arg.split("=", 1)[1]
        elif arg.startswith("-") and arg != "-":
            continue
        elif verb is None:
            verb = arg
        else:
            units.append(arg)
    return verb, units, options


def cat(units):
    try:
        manifest = load_manifest()
    except (OSError, ValueError):
        manifest = None
    status = 0
    for name in units:
        kind, base, _ = split_name(name)
        definition = (manifest or {}).get(kind + "s", {}).get(base)
        if definition is None:
            print(f"No files found for {full_name(name, kind)}.", file=sys.stderr)
            status = 1
            continue
        print(f"# {MANIFEST}: {full_name(name, kind)}")
        for section, values in definition.items():
            print(f"[{section}]")
            for key, value in values.items():
                for item in as_list(value):
                    print(f"{key}={str(item).lower() if isinstance(item, bool) else item}")
            print()
    return status


def offline(verb, units, options):
    """Answers for a daemon that is not running: nothing is active."""
    try:
        supervisor = Supervisor()
    except (OSError, ValueError):
        supervisor = None
    if verb in ("stop", "try-restart", "reset-failed", "daemon-reload", "shutdown", "reload"):
        return 0, ""
    if supervisor is None:
        return (3 if verb == "is-active" else 1), "\n".join(INACTIVE for _ in units)
    return handle(supervisor, {"verb": verb, "units": units, "options": options})


def systemctl_main(args):
    verb, units, options = parse_systemctl(args)
    if verb is None:
        verb = "status"
    if verb == "cat":
        return cat(units)
    if verb == "daemon":
        return serve()
    if verb == "ensure":
        # A new session: boot unless the daemon already runs.
        if request("ping") is not None:
            return 0
        verb = "boot"
    spawn = verb in ("start", "restart", "boot")
    reply = request(verb, units, options, spawn=spawn)
    if reply is None:
        reply = offline(verb, units, options)
    status, output = reply
    if output and not options.get("quiet"):
        print(output, file=sys.stderr if verb in ("start",) and status else sys.stdout)
    return status


# --- journal --------------------------------------------------------------------


def parse_since(value):
    value = value.strip()
    now = time.time()
    if value.startswith("@"):
        return float(value[1:])
    if value in ("now",):
        return now
    if value in ("today", "yesterday"):
        midnight = datetime.datetime.combine(datetime.date.today(), datetime.time())
        return midnight.timestamp() - (86400 if value == "yesterday" else 0)
    if value[:1] in "-+":
        return now + (1 if value[0] == "+" else -1) * timespan(value[1:])
    if value.endswith(" ago"):
        return now - timespan(value[:-4])
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d", "%H:%M:%S", "%H:%M"):
        try:
            parsed = datetime.datetime.strptime(value, fmt)
        except ValueError:
            continue
        if fmt.startswith("%H"):
            parsed = datetime.datetime.combine(datetime.date.today(), parsed.time())
        return parsed.timestamp()
    raise ValueError(f"cannot parse time {value!r}")


def log_units(patterns):
    try:
        names = sorted(f[:-4] for f in os.listdir(LOG_DIR) if f.endswith(".log"))
    except OSError:
        names = []
    names = [n for n in names if n != "supervisor"]
    if not patterns:
        return names
    wanted = [p[: -len(".service")] if p.endswith(".service") else p for p in patterns]
    return [n for n in names if any(fnmatch.fnmatchcase(n, p) for p in wanted)] + [
        p for p in wanted if p == "supervisor"
    ]


def read_entries(unit, since=None):
    entries = []
    for path in (log_path(unit) + ".1", log_path(unit)):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    stamp, _, text = line.rstrip("\n").partition("\t")
                    try:
                        at = float(stamp)
                    except ValueError:
                        continue
                    if since is None or at >= since:
                        entries.append((at, unit, text))
        except OSError:
            pass
    return entries


def format_entry(entry, fmt):
    at, unit, text = entry
    if fmt == "cat":
        return text
    stamp = datetime.datetime.fromtimestamp(at).strftime("%b %d %H:%M:%S")
    return f"{stamp} {unit}: {text}"


def journal_lines(patterns, count=None, since=None, fmt="short"):
    entries = sorted(e for unit in log_units(patterns) for e in read_entries(unit, since))
    if count is not None:
        entries = entries[-count:] if count else []
    return [format_entry(e, fmt) for e in entries]


def journal_main(args):
    patterns, follow, count, since, fmt = [], False, None, None, "short"
    it = iter(args)
    for arg in it:
        if arg in ("-u", "--unit"):
            patterns.append(next(it, ""))
        elif arg.startswith("--unit="):
            patterns.append(arg.split("=", 1)[1])
        elif arg.startswith("-u") and len(arg) > 2:
            patterns.append(arg[2:])
        elif arg in ("-f", "--follow"):
            follow = True
        elif arg in ("-n", "--lines"):
            count = int(next(it, "10"))
        elif arg.startswith("--lines="):
            count = int(arg.split("=", 1)[1])
        elif arg.startswith("-n") and len(arg) > 2:
            count = int(arg[2:])
        elif arg in ("-S", "--since"):
            since = parse_since(next(it, ""))
        elif arg.startswith("--since="):
            since = parse_since(arg.split("=", 1)[1])
        elif arg in ("-o", "--output"):
            fmt = next(it, "short")
        elif arg.startswith("--output="):
            fmt = arg.split("=", 1)[1]
    if follow and count is None:
        count = 10
    for line in journal_lines(patterns, count, since, fmt):
        print(line)
    if not follow:
        return 0
    sys.stdout.flush()
    offsets = {}
    for unit in log_units(patterns):
        try:
            offsets[unit] = (os.stat(log_path(unit)).st_ino, os.path.getsize(log_path(unit)))
        except OSError:
            pass
    try:
        while True:
            time.sleep(0.5)
            for unit in log_units(patterns):
                path = log_path(unit)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                inode, offset = offsets.get(unit, (st.st_ino, 0))
                if inode != st.st_ino or st.st_size < offset:
                    offset = 0
                if st.st_size == offset:
                    offsets[unit] = (st.st_ino, offset)
                    continue
                with open(path, encoding="utf-8", errors="replace") as f:
                    f.seek(offset)
                    chunk = f.read()
                    offset = f.tell()
                offsets[unit] = (st.st_ino, offset)
                for line in chunk.splitlines():
                    stamp, _, text = line.partition("\t")
                    try:
                        print(format_entry((float(stamp), unit, text), fmt), flush=True)
                    except ValueError:
                        continue
    except KeyboardInterrupt:
        return 0


def main(argv):
    args = argv[1:]
    if args[:1] == ["journal"]:
        return journal_main(args[1:])
    if args[:1] in (["-h"], ["--help"], ["help"]):
        print(__doc__.strip())
        return 0
    return systemctl_main(args)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        sys.exit(0)
