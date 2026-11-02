import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SUPERVISOR = os.path.join(HERE, "proxy_supervisor.py")


def stat(pid):
    """/proc/<pid>/stat from its third field (state, ppid, pgrp, ...), or None once it is gone or a zombie."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().rsplit(")", 1)[1].split()
    except OSError:
        return None
    return None if fields[0] == "Z" else fields


def wait_for(predicate, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("timed out")


class SupervisorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="proxy-supervisor-")
        self.run_dir = os.path.join(self.tmp, "run")
        self.manifest = os.path.join(self.tmp, "manifest.json")
        self.empty_rule_set = os.path.join(self.tmp, "empty.srs")
        self.env = dict(
            os.environ,
            # Deeper than a socket address holds.
            PROXY_SUITE_SUPERVISOR_DIR=os.path.join(self.tmp, "x" * 100, "supervisor"),
            PROXY_SUITE_MANIFEST=self.manifest,
            HOME=self.tmp,
        )
        self.write_manifest()

    def tearDown(self):
        subprocess.run([sys.executable, SUPERVISOR, "shutdown"], env=self.env, capture_output=True)
        # The daemon removes its socket once every unit is down.
        try:
            wait_for(lambda: not self.daemon_running(), timeout=30)
        finally:
            shutil.rmtree(self.tmp, ignore_errors=True)

    def daemon_running(self):
        return os.path.exists(os.path.join(self.env["PROXY_SUITE_SUPERVISOR_DIR"], "control.sock"))

    def write_manifest(self, crash_times=1, marker="one"):
        out = os.path.join(self.tmp, "out")
        sh = lambda text: ["/bin/sh -c " + json.dumps(text)]
        manifest = {
            "services": {
                # Fails the first crash_times starts, then stays up.
                "proxy-suite-counter": {
                    "Unit": {"Description": "counter"},
                    "Service": {
                        "Type": "simple",
                        "Restart": "on-failure",
                        "RestartSec": "100ms",
                        "Environment": [json.dumps(f"MARKER={marker}")],
                        "ExecStartPre": [f'/bin/sh -c "mkdir -p {out}"'],
                        "ExecStart": sh(
                            f'n=$(cat {out}/starts 2>/dev/null || echo 0); n=$((n+1)); echo $n > {out}/starts; '
                            f'echo "start $n $MARKER"; [ $n -gt {crash_times} ] || exit 3; exec sleep 1000'
                        ),
                        "ExecStopPost": sh(f"echo stopped >> {out}/stops"),
                    },
                    "Install": {"WantedBy": ["default.target"]},
                },
                # Its ExecStartPost fails: a failed start, not a crash to restart.
                "proxy-suite-post": {
                    "Unit": {"Description": "failing ExecStartPost"},
                    "Service": {
                        "Type": "simple",
                        "Restart": "on-failure",
                        "RestartSec": "100ms",
                        "ExecStartPre": [f'/bin/sh -c "mkdir -p {out}"'],
                        "ExecStart": sh("exec sleep 1000"),
                        "ExecStartPost": sh("exit 1"),
                        "ExecStopPost": sh(f"echo stopped >> {out}/post-stops"),
                    },
                },
                "proxy-suite-once": {
                    "Unit": {"Description": "oneshot", "After": ["proxy-suite-counter.service"]},
                    "Service": {
                        "Type": "oneshot",
                        "RemainAfterExit": True,
                        "ExecStart": sh(f"echo ran >> {out}/once"),
                    },
                    "Install": {"WantedBy": ["default.target"]},
                },
                "proxy-suite-tick": {
                    "Unit": {"Description": "timer job"},
                    "Service": {"Type": "oneshot", "ExecStart": sh(f"echo tick >> {out}/ticks")},
                },
                "proxy-suite-watched": {
                    "Unit": {"Description": "path job"},
                    "Service": {"Type": "oneshot", "ExecStart": sh(f"echo changed >> {out}/watched")},
                },
                "proxy-suite-pin@": {
                    "Unit": {"Description": "template"},
                    "Service": {"Type": "oneshot", "ExecStart": sh(f"echo '%I' >> {out}/pins")},
                },
            },
            "timers": {
                "proxy-suite-tick": {
                    "Unit": {"Description": "tick"},
                    "Timer": {"OnActiveSec": "1s", "OnUnitActiveSec": "1s"},
                    "Install": {"WantedBy": ["timers.target"]},
                },
            },
            "paths": {
                "proxy-suite-watched": {
                    "Unit": {"Description": "watch a file"},
                    "Path": {"PathChanged": [os.path.join(self.tmp, "trigger")]},
                    "Install": {"WantedBy": ["paths.target"]},
                },
            },
            "tmpfiles": [
                f"d {self.run_dir} 0700 - - -",
                # An empty rule set, copied where none is yet (rulesets.nix).
                f"C {os.path.join(self.tmp, 'rule-sets', 'geo.srs')} - - - - {self.empty_rule_set}",
            ],
        }
        with open(self.manifest + ".tmp", "w") as f:
            json.dump(manifest, f)
        with open(self.empty_rule_set, "w") as f:
            f.write("{}")
        os.replace(self.manifest + ".tmp", self.manifest)

    def ctl(self, *args):
        p = subprocess.run([sys.executable, SUPERVISOR, *args], env=self.env, capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout

    def read(self, name):
        try:
            with open(os.path.join(self.tmp, "out", name)) as f:
                return f.read().split()
        except FileNotFoundError:
            return []

    def test_without_daemon(self):
        self.assertEqual(self.ctl("is-active", "--quiet", "proxy-suite-counter"), (3, ""))
        status, out = self.ctl("show", "--property=Id,LoadState,ActiveState", "--", "proxy-suite-counter", "nope")
        self.assertEqual(status, 0)
        self.assertEqual(
            out.split("\n\n"),
            ["Id=proxy-suite-counter.service\nLoadState=loaded\nActiveState=inactive", "Id=nope.service\nLoadState=not-found\nActiveState=inactive\n"],
        )
        self.assertEqual(self.ctl("stop", "proxy-suite-counter")[0], 0)
        # inbound_apply.py's verb: nothing runs, so nothing to do (and no daemon to start).
        self.assertEqual(self.ctl("try-reload-or-restart", "proxy-suite-counter")[0], 0)
        self.assertFalse(self.daemon_running())

    def test_boot_restart_timers_and_stop(self):
        self.assertEqual(self.ctl("boot")[0], 0)
        with open(os.path.join(self.tmp, "rule-sets", "geo.srs")) as f:
            self.assertEqual(f.read(), "{}")
        self.assertTrue(os.path.isdir(self.run_dir))
        # Crashed once, restarted, then up.
        wait_for(lambda: self.ctl("show", "-p", "SubState", "--value", "proxy-suite-counter")[1].strip() == "running")
        self.assertEqual(self.read("starts"), ["2"])
        self.assertEqual(self.read("stops"), ["stopped"])
        self.assertEqual(self.read("once"), ["ran"])
        self.assertEqual(self.ctl("is-active", "proxy-suite-once"), (0, "active\n"))

        status, out = self.ctl("list-timers", "-o", "json", "proxy-suite-tick.timer")
        timers = json.loads(out)
        self.assertEqual([t["activates"] for t in timers], ["proxy-suite-tick.service"])
        self.assertGreater(timers[0]["next"], (time.time() - 5) * 1e6)
        wait_for(lambda: len(self.read("ticks")) >= 2)

        # Template instances get %I unescaped.
        self.assertEqual(self.ctl("start", "proxy-suite-pin@de\\x2dfra.service")[0], 0)
        self.assertEqual(self.read("pins"), ["de-fra"])

        status, out = self.ctl("journal", "-u", "proxy-suite-count*", "-o", "cat", "--since", "-1h", "--no-pager")
        self.assertEqual([l for l in out.splitlines() if l.startswith("start")][:2], ["start 1 one", "start 2 one"])
        self.assertIn("proxy-suitectl: exited with status 3; restarting", out)
        self.assertEqual(self.ctl("journal", "-u", "proxy-suite-counter", "-n", "1", "-o", "cat")[1], "start 2 one\n")

        self.assertEqual(self.ctl("stop", "proxy-suite-counter")[0], 0)
        self.assertEqual(self.ctl("is-active", "proxy-suite-counter"), (3, "inactive\n"))
        self.assertEqual(self.read("stops"), ["stopped", "stopped"])
        # try-restart leaves a stopped unit stopped.
        self.assertEqual(self.ctl("try-restart", "proxy-suite-counter")[0], 0)
        self.assertEqual(self.ctl("is-active", "proxy-suite-counter")[0], 3)

    def test_boot_again_restarts_changed_units(self):
        self.write_manifest(crash_times=0)
        self.ctl("boot")
        wait_for(lambda: self.ctl("is-active", "proxy-suite-counter")[0] == 0)
        pid = self.ctl("show", "-p", "MainPID", "--value", "proxy-suite-counter")[1].strip()
        self.write_manifest(crash_times=0, marker="two")
        self.assertEqual(self.ctl("boot")[0], 0)
        wait_for(lambda: self.ctl("is-active", "proxy-suite-counter")[0] == 0)
        self.assertNotEqual(self.ctl("show", "-p", "MainPID", "--value", "proxy-suite-counter")[1].strip(), pid)
        self.assertIn("start 2 two", self.ctl("journal", "-u", "proxy-suite-counter", "-o", "cat")[1])
        # The unchanged oneshot is not run again.
        self.assertEqual(self.read("once"), ["ran"])


    def test_failed_start_post_stays_failed(self):
        self.assertNotEqual(self.ctl("start", "proxy-suite-post")[0], 0)
        time.sleep(1)  # time enough for a restart, were the main process's exit taken for a crash
        self.assertEqual(self.ctl("is-active", "proxy-suite-post")[1], "failed\n")
        self.assertEqual(self.read("post-stops"), ["stopped"])

    def test_a_killed_daemon_leaves_nothing_running(self):
        """Android may kill the daemon outright: what it ran is ended, not started again beside it."""
        self.write_manifest(crash_times=0)
        main_pid = lambda: int(self.ctl("show", "-p", "MainPID", "--value", "proxy-suite-counter")[1])

        def kill_daemon(main):
            daemon = int(stat(main)[1])  # the main process's parent
            os.kill(daemon, signal.SIGKILL)
            wait_for(lambda: stat(daemon) is None)
            self.assertIsNotNone(stat(main))  # left running, in a session of its own

        self.assertEqual(self.ctl("start", "proxy-suite-counter")[0], 0)
        old = main_pid()
        kill_daemon(old)
        # The next daemon ends it before it starts anything.
        self.assertEqual(self.ctl("start", "proxy-suite-counter")[0], 0)
        self.assertIsNone(stat(old))
        new = main_pid()
        self.assertNotEqual(new, old)
        self.assertEqual(self.read("starts"), ["2"])
        self.assertIn("left running by a supervisor that died", self.ctl("journal", "-u", "proxy-suite-counter", "-o", "cat")[1])

        # With no daemon at all, stop still reaches it.
        kill_daemon(new)
        self.assertEqual(self.ctl("stop", "proxy-suite-counter")[0], 0)
        self.assertIsNone(stat(new))
        os.unlink(os.path.join(self.env["PROXY_SUITE_SUPERVISOR_DIR"], "control.sock"))  # the killed daemon's

    def test_path_unit_starts_its_service_when_the_file_changes(self):
        trigger = os.path.join(self.tmp, "trigger")
        # boot brings up the .path unit with the rest of paths.target.
        self.assertEqual(self.ctl("boot")[0], 0)
        # A .path unit is active itself, and quiet until the file it watches appears.
        self.assertEqual(self.ctl("is-active", "--quiet", "proxy-suite-watched.path")[0], 0)
        self.assertEqual(self.read("watched"), [])

        with open(trigger, "w") as f:
            f.write("one")
        wait_for(lambda: self.read("watched") == ["changed"])

        # Stopped, further changes are ignored.
        self.assertEqual(self.ctl("stop", "proxy-suite-watched.path")[0], 0)
        with open(trigger, "w") as f:
            f.write("two")
        time.sleep(1)
        self.assertEqual(self.read("watched"), ["changed"])

    def test_daemon_dirs_are_private_and_stale_credentials_go(self):
        base = self.env["PROXY_SUITE_SUPERVISOR_DIR"]
        stale = os.path.join(base, "credentials", "proxy-suite-gone.service")
        os.makedirs(stale)  # 0755, as makedirs left them before
        with open(os.path.join(stale, "key"), "w") as f:
            f.write("secret")
        self.assertEqual(self.ctl("start", "proxy-suite-tick.timer")[0], 0)
        self.assertFalse(os.path.exists(stale))
        for path in (base, os.path.join(base, "logs"), os.path.join(base, "credentials")):
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o700, path)


class InProcessTest(unittest.TestCase):
    """The Supervisor itself, driven from here, for races a client cannot time."""

    def setUp(self):
        sys.path.insert(0, HERE)
        import proxy_supervisor

        self.ps = proxy_supervisor
        self.tmp = tempfile.mkdtemp(prefix="proxy-supervisor-")
        self.saved = {k: getattr(self.ps, k) for k in ("LOG_DIR", "CREDENTIALS_DIR")}
        self.ps.LOG_DIR = os.path.join(self.tmp, "logs")
        self.ps.CREDENTIALS_DIR = os.path.join(self.tmp, "credentials")
        os.makedirs(self.ps.LOG_DIR)
        self.sup = None

    def tearDown(self):
        if self.sup:
            self.sup.shutdown()
        for k, v in self.saved.items():
            setattr(self.ps, k, v)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def supervisor(self, services):
        path = os.path.join(self.tmp, "manifest.json")
        with open(path, "w") as f:
            json.dump({"services": services}, f)
        self.sup = self.ps.Supervisor(path)
        self.sup.groups = self.ps.Groups(os.path.join(self.tmp, "groups.json"))
        return self.sup

    def path(self, name):
        return os.path.join(self.tmp, name)

    def pid(self, name):
        def read():
            try:
                with open(self.path(name)) as f:
                    return int(f.read())
            except (OSError, ValueError):
                return None

        return wait_for(read)

    def test_main_exiting_during_stop_leaves_nothing_and_its_pid_unsignalled(self):
        """The main process exits while stop() is still stopping what is bound to it."""
        sup = self.supervisor({
            "main": {"Service": {"ExecStart": "/bin/sh -c " + json.dumps(
                f"sleep 1000 & echo $! > {self.path('left')}; echo $$ > {self.path('main')}; wait")}},
            # Its own stop ends main's process, then takes a while.
            "bound": {
                "Unit": {"PartOf": "main.service"},
                "Service": {
                    "ExecStart": "sleep 1000",
                    "ExecStop": "/bin/sh -c " + json.dumps(f"kill $(cat {self.path('main')}); sleep 0.5"),
                },
            },
        })
        self.assertEqual(sup.start("main"), 0)
        self.assertEqual(sup.start("bound"), 0)
        left = self.pid("left")
        signalled_reaped = []
        kill_group = sup.kill_group

        def recording(proc, sig):
            if proc is not None and proc.returncode is not None:
                signalled_reaped.append((proc.pid, sig))
            kill_group(proc, sig)

        sup.kill_group = recording
        self.assertEqual(sup.stop("main"), 0)
        self.assertEqual(sup.units["main.service"].state, self.ps.INACTIVE)
        self.assertIsNone(sup.units["main.service"].main)
        wait_for(lambda: stat(left) is None)
        self.assertEqual(signalled_reaped, [])

    def test_an_exception_while_activating_fails_the_unit(self):
        sup = self.supervisor({"svc": {"Service": {"ExecStart": "sleep 1000"}}})
        spawned, spawn = [], sup.spawn
        sup.spawn = lambda *a: spawned.append(spawn(*a)[0]) or (spawned[-1], False)
        real = threading.Thread

        class NoWatch(real):
            def start(self):
                if getattr(self, "_target", None) == sup.watch:
                    raise RuntimeError("can't start new thread")
                super().start()

        self.ps.threading.Thread = NoWatch
        try:
            self.assertEqual(sup.start("svc"), 1)
        finally:
            self.ps.threading.Thread = real
        unit = sup.units["svc.service"]
        self.assertEqual((unit.state, unit.result, unit.main), (self.ps.FAILED, "resources", None))
        self.assertIsNotNone(spawned[0].returncode)  # ended and reaped
        # Not stuck activating: the next start runs.
        self.assertEqual(sup.start("svc"), 0)
        self.assertEqual(unit.state, self.ps.ACTIVE)

    def test_an_unparsable_command_fails_the_start(self):
        sup = self.supervisor({"svc": {"Service": {"ExecStartPre": "/bin/sh -c 'unbalanced", "ExecStart": "sleep 1000"}}})
        self.assertEqual(sup.start("svc"), 1)
        self.assertEqual(sup.units["svc.service"].state, self.ps.FAILED)

    def test_start_while_waiting_to_restart_starts_now(self):
        sup = self.supervisor({"svc": {"Service": {
            "Restart": "on-failure",
            "RestartSec": "1h",
            "ExecStart": "/bin/sh -c " + json.dumps(
                f"[ -e {self.path('ran')} ] && exec sleep 1000; touch {self.path('ran')}; exit 3"),
        }}})
        self.assertEqual(sup.start("svc"), 0)
        unit = sup.units["svc.service"]
        wait_for(lambda: unit.state == self.ps.AUTO_RESTART)
        self.assertEqual(sup.start("svc"), 0)
        self.assertEqual(unit.state, self.ps.ACTIVE)
        self.assertIsNotNone(stat(unit.main.pid))

    def test_restart_brings_back_what_is_bound_to_it(self):
        """systemd restarts PartOf= and BindsTo= units along: a stop alone left them down."""
        sup = self.supervisor({
            "main": {"Service": {"ExecStart": "sleep 1000"}},
            "part": {"Unit": {"PartOf": "main.service", "After": "main.service"}, "Service": {"ExecStart": "sleep 1000"}},
            "bound": {"Unit": {"BindsTo": "main.service"}, "Service": {"ExecStart": "sleep 1000"}},
            # Bound to one bound to main: comes back too.
            "deeper": {"Unit": {"PartOf": "part.service"}, "Service": {"ExecStart": "sleep 1000"}},
            "requires": {"Unit": {"Requires": "main.service"}, "Service": {"ExecStart": "sleep 1000"}},
            # Not running: stays down.
            "idle": {"Unit": {"PartOf": "main.service"}, "Service": {"ExecStart": "sleep 1000"}},
        })
        names = ("main", "part", "bound", "deeper", "requires", "idle")
        for name in names:
            self.assertEqual(sup.start(name), 0)
        self.assertEqual(sup.stop("idle"), 0)
        units = {name: sup.units[f"{name}.service"] for name in names}
        before = {name: unit.main.pid for name, unit in units.items() if unit.main}
        for only_if_active in (False, True):
            self.assertEqual(sup.restart("main", only_if_active=only_if_active), 0)
            for name in names[:-1]:
                self.assertEqual(units[name].state, self.ps.ACTIVE, name)
                self.assertNotEqual(units[name].main.pid, before[name], name)
                self.assertIsNone(stat(before[name]), name)
                before[name] = units[name].main.pid
            self.assertEqual(units["idle"].state, self.ps.INACTIVE)

    def test_stop_reaches_what_requires_it(self):
        """Requires= both ways: each stops once."""
        sup = self.supervisor({
            "a": {"Unit": {"Requires": "b.service"}, "Service": {"ExecStart": "sleep 1000"}},
            "b": {"Unit": {"Requires": "a.service"}, "Service": {"ExecStart": "sleep 1000"}},
        })
        self.assertEqual(sup.start("a"), 0)
        a, b = sup.units["a.service"], sup.units["b.service"]
        pids = [a.main.pid, b.main.pid]
        self.assertEqual(sup.stop("a"), 0)
        self.assertEqual((a.state, b.state), (self.ps.INACTIVE, self.ps.INACTIVE))
        self.assertEqual([stat(pid) for pid in pids], [None, None])
        self.assertEqual(sup.restart("b"), 0)
        self.assertEqual((a.state, b.state), (self.ps.ACTIVE, self.ps.ACTIVE))

    def test_stop_lets_stop_commands_finish(self):
        """ExecStopPost= already running when a stop comes: run to the end, not SIGTERMed."""
        cleanup = lambda name: "/bin/sh -c " + json.dumps(f"touch {self.path(name + '-began')}; sleep 0.5; touch {self.path(name + '-done')}")
        sup = self.supervisor({
            # A oneshot's own, as its start ends; a main process's, as watch() handles its exit.
            "oneshot": {"Service": {"Type": "oneshot", "ExecStart": "true", "ExecStopPost": cleanup("oneshot")}},
            "exits": {"Service": {"ExecStart": "true", "ExecStopPost": cleanup("exits")}},
        })

        def stopped_while_cleaning_up(name):
            starting = threading.Thread(target=sup.start, args=(name,))
            starting.start()
            wait_for(lambda: os.path.exists(self.path(name + "-began")))
            self.assertEqual(sup.stop(name), 0)
            starting.join()
            self.assertTrue(os.path.exists(self.path(name + "-done")), name)
            self.assertEqual(sup.units[f"{name}.service"].state, self.ps.INACTIVE, name)

        stopped_while_cleaning_up("oneshot")
        stopped_while_cleaning_up("exits")

    def test_hanging_stop_command_is_ended(self):
        """An ExecStopPost= that never ends is killed after the stop-command timeout, as systemd's TimeoutStopSec=."""
        hang = "/bin/sh -c " + json.dumps(f"echo $$ > {self.path('hang-pid')}; exec sleep 1000")
        sup = self.supervisor({"hangs": {"Service": {"ExecStart": "sleep 1000", "ExecStopPost": hang}}})
        self.assertEqual(sup.start("hangs"), 0)
        saved, self.ps.STOP_COMMAND_TIMEOUT = self.ps.STOP_COMMAND_TIMEOUT, 0.3
        try:
            began = time.monotonic()
            sup.stop("hangs")
            self.assertLess(time.monotonic() - began, 10)
        finally:
            self.ps.STOP_COMMAND_TIMEOUT = saved
        self.assertIsNone(stat(int(open(self.path("hang-pid")).read())))
        self.assertNotEqual(sup.units["hangs.service"].state, self.ps.ACTIVE)

    def test_auto_restart_pulls_its_dependencies_in_again(self):
        """Restart= starts the unit as start() does: Wants= and WantedBy= come back, a failing Requires= fails it."""
        crash = lambda name: "/bin/sh -c " + json.dumps(
            f"echo x >> {self.path(name + '-runs')}; while [ ! -e {self.path(name + '-crash')} ]; do sleep 0.05; done;"
            f" rm {self.path(name + '-crash')}; exit 3")
        restarts = {"Restart": "on-failure", "RestartSec": "0.1"}
        flag = self.path("fail")
        sup = self.supervisor({
            "main": {"Unit": {"Wants": "wanted.service"}, "Service": dict(restarts, ExecStart=crash("main"))},
            "wanted": {"Service": {"ExecStart": "sleep 1000"}},
            "follower": {"Unit": {"After": "main.service"}, "Service": {"ExecStart": "sleep 1000"}, "Install": {"WantedBy": ["main.service"]}},
            "needs": {"Unit": {"Requires": "dep.service"}, "Service": dict(restarts, ExecStart=crash("needs"))},
            "dep": {"Service": {"Type": "oneshot", "ExecStart": "/bin/sh -c " + json.dumps(f"[ ! -e {flag} ]")}},
        })
        self.assertEqual(sup.start("main"), 0)
        main, wanted, follower = (sup.units[f"{n}.service"] for n in ("main", "wanted", "follower"))
        self.assertEqual((wanted.state, follower.state), (self.ps.ACTIVE, self.ps.ACTIVE))
        for unit in (wanted, follower):
            self.assertEqual(sup.stop(unit.name), 0)
        pid = main.main.pid
        open(self.path("main-crash"), "w").close()
        wait_for(lambda: main.main is not None and main.main.pid != pid and main.state == self.ps.ACTIVE)
        wait_for(lambda: wanted.state == self.ps.ACTIVE and follower.state == self.ps.ACTIVE)

        self.assertEqual(sup.start("needs"), 0)
        needs = sup.units["needs.service"]
        wait_for(lambda: os.path.exists(self.path("needs-runs")))
        open(flag, "w").close()
        open(self.path("needs-crash"), "w").close()
        wait_for(lambda: needs.state == self.ps.FAILED)
        self.assertEqual(needs.result, "dependency")
        with open(self.path("needs-runs")) as f:
            self.assertEqual(f.read().split(), ["x"])

    def test_try_reload_or_restart(self):
        hups = self.path("hups")
        sup = self.supervisor({
            "reloads": {"Service": {
                "ExecStart": "/bin/sh -c " + json.dumps(
                    f"trap 'echo hup >> {hups}' HUP; touch {self.path('ready')}; while :; do sleep 0.05; done"),
                "ExecReload": "/bin/sh -c " + json.dumps('kill -HUP "$1"') + " sh $MAINPID",
            }},
            "plain": {"Service": {"ExecStart": "sleep 1000"}},
        })
        handle = lambda verb, *names: self.ps.handle(sup, {"verb": verb, "units": list(names)})
        # Not running: try- leaves it so, the other starts it.
        self.assertEqual(handle("try-reload-or-restart", "reloads", "plain"), (0, ""))
        self.assertNotIn("reloads.service", sup.units)
        self.assertEqual(handle("reload-or-restart", "plain"), (0, ""))
        plain = sup.units["plain.service"]
        self.assertEqual(plain.state, self.ps.ACTIVE)
        self.assertEqual(sup.start("reloads"), 0)
        reloads = sup.units["reloads.service"]
        pid = reloads.main.pid
        wait_for(lambda: os.path.exists(self.path("ready")))  # the trap set
        # ExecReload, with $MAINPID, and the process stays.
        self.assertEqual(handle("try-reload-or-restart", "reloads"), (0, ""))
        wait_for(lambda: os.path.exists(hups))
        self.assertEqual(reloads.main.pid, pid)
        # No ExecReload: restarted.
        pid = plain.main.pid
        self.assertEqual(handle("try-reload-or-restart", "plain"), (0, ""))
        self.assertEqual(plain.state, self.ps.ACTIVE)
        self.assertNotEqual(plain.main.pid, pid)

    def test_command_variables(self):
        env = {"MAINPID": "42", "TWO": "a  b"}
        self.assertEqual(
            self.ps.expand_variables(["$MAINPID", "$TWO", "${TWO}", "x${MAINPID}y", "$UNSET", "${UNSET}", "$$", "a$MAINPID"], env),
            ["42", "a", "b", "a  b", "x42y", "", "$$", "a$MAINPID"],
        )

    def test_wanted_by_a_service_starts_with_it(self):
        """WantedBy=<service>: a Wants= of that service, started once it is up."""
        sup = self.supervisor({
            "main": {"Service": {"ExecStart": "sleep 1000"}},
            "wanted": {
                "Unit": {"After": "main.service", "BindsTo": "main.service"},
                "Service": {"ExecStart": "sleep 1000"},
                "Install": {"WantedBy": ["main.service"]},
            },
            "booted": {"Service": {"ExecStart": "sleep 1000"}, "Install": {"WantedBy": ["default.target"]}},
        })
        self.assertEqual(sup.start("main"), 0)
        main, wanted = sup.units["main.service"], sup.units["wanted.service"]
        self.assertEqual(wanted.state, self.ps.ACTIVE)
        self.assertGreaterEqual(wanted.last_activated, main.last_activated)
        self.assertNotIn("booted.service", sup.units)
        # And again with a restart of main, which took it down.
        pid = wanted.main.pid
        self.assertEqual(sup.restart("main"), 0)
        self.assertEqual(wanted.state, self.ps.ACTIVE)
        self.assertNotEqual(wanted.main.pid, pid)

        # One a switch adds comes up beside the running service it names.
        with open(self.sup.manifest_path, "w") as f:
            json.dump({"services": dict(sup.manifest["services"], added={
                "Service": {"ExecStart": "sleep 1000"}, "Install": {"WantedBy": ["main.service"]},
            })}, f)
        sup.booted = True
        pid = main.main.pid
        self.assertEqual(sup.reload(restart_changed=True), 0)
        self.assertEqual(sup.units["added.service"].state, self.ps.ACTIVE)
        self.assertEqual(main.main.pid, pid)

    def test_conditions_skip_a_start(self):
        here, missing = self.path("here"), self.path("missing")
        with open(here, "w"):
            pass
        unit = lambda conditions: {
            "Unit": {"ConditionPathExists": conditions},
            "Service": {"Type": "oneshot", "RemainAfterExit": True, "ExecStart": "true"},
        }
        sup = self.supervisor({
            "unmet": unit(missing),
            "met": unit([here, "!" + missing]),
            "negated": unit("!" + here),
            "any": unit(["|" + missing, "|" + here]),
            "none": unit(["|" + missing, "| " + missing + "2"]),
            "both": unit([here, "|" + missing]),
            # Started once, then gone with its file: a restart does not come either.
            "loses": {
                "Unit": {"ConditionPathExists": self.path("flag")},
                "Service": {
                    "Restart": "always",
                    "RestartSec": 0,
                    "ExecStart": "/bin/sh -c " + json.dumps(f"echo x >> {self.path('runs')}; rm {self.path('flag')}; exit 1"),
                },
            },
        })
        expected = {"unmet": False, "met": True, "negated": False, "any": True, "none": False, "both": False}
        for name, starts in expected.items():
            # Skipped is no failure.
            self.assertEqual(sup.start(name), 0, name)
            self.assertEqual(sup.units[f"{name}.service"].state, self.ps.ACTIVE if starts else self.ps.INACTIVE, name)
        self.assertIn("ConditionPathExists=", self.ps.journal_lines(["unmet"], fmt="cat")[-1])

        with open(self.path("flag"), "w"):
            pass
        self.assertEqual(sup.start("loses"), 0)
        loses = sup.units["loses.service"]
        wait_for(lambda: loses.state == self.ps.INACTIVE and "not met" in self.ps.journal_lines(["loses"], fmt="cat")[-1])
        time.sleep(0.3)
        self.assertEqual(loses.state, self.ps.INACTIVE)
        with open(self.path("runs")) as f:
            self.assertEqual(f.read().split(), ["x"])

    def test_start_limit(self):
        runs = self.path("runs")
        crash = "/bin/sh -c " + json.dumps(f"echo x >> {runs}; [ $(wc -l < {runs}) -gt 7 ] && exec sleep 1000; exit 3")
        sup = self.supervisor({
            # systemd's default: 5 starts in 10 s, Restart='s too.
            "limited": {"Service": {"Restart": "always", "RestartSec": 0, "ExecStart": crash}},
            "unlimited": {
                "Unit": {"StartLimitIntervalSec": 0},
                "Service": {"Restart": "always", "RestartSec": 0, "ExecStart": crash},
            },
        })
        def count():
            try:
                with open(runs) as f:
                    return len(f.read().split())
            except FileNotFoundError:
                return 0

        self.assertEqual(sup.start("limited"), 0)
        limited = sup.units["limited.service"]
        wait_for(lambda: limited.state == self.ps.FAILED)
        self.assertEqual((limited.result, count()), ("start-limit-hit", 5))
        # Refused until reset-failed.
        self.assertEqual(sup.start("limited"), 1)
        self.assertEqual(count(), 5)
        self.assertEqual(self.ps.handle(sup, {"verb": "reset-failed", "units": ["limited"]}), (0, ""))
        self.assertEqual(sup.start("limited"), 0)
        wait_for(lambda: count() >= 6)
        sup.stop("limited")

        os.unlink(runs)
        self.assertEqual(sup.start("unlimited"), 0)
        unlimited = sup.units["unlimited.service"]
        wait_for(lambda: count() == 8 and unlimited.state == self.ps.ACTIVE)

    def test_restart_steps(self):
        # whitelist-bypass's: 5 s, up to 2 min over 5 restarts.
        unit = self.ps.Unit("x.service", {"Service": {"RestartSec": 5, "RestartSteps": 5, "RestartMaxDelaySec": 120}})
        delays = []
        for restarts in range(1, 8):
            unit.restarts = restarts
            delays.append(round(self.ps.Supervisor.restart_delay(unit), 1))
        self.assertEqual(delays, [5, 9.4, 17.8, 33.7, 63.6, 120, 120])
        unit = self.ps.Unit("x.service", {"Service": {"RestartSec": "5s"}})
        unit.restarts = 9
        self.assertEqual(self.ps.Supervisor.restart_delay(unit), 5)

    def test_a_failing_dependency_leaves_a_running_unit_alone(self):
        """Marked failed, a running unit was skipped by stop(): its process ran on."""
        flag = self.path("fail")
        sup = self.supervisor({
            "dep": {"Service": {"Type": "oneshot", "ExecStart": "/bin/sh -c " + json.dumps(f"[ ! -e {flag} ]")}},
            "main": {"Unit": {"Requires": "dep.service"}, "Service": {"ExecStart": "sleep 1000"}},
        })
        self.assertEqual(sup.start("main"), 0)
        main = sup.units["main.service"]
        pid = main.main.pid
        with open(flag, "w"):
            pass
        self.assertEqual(sup.start("main"), 1)
        self.assertEqual((main.state, main.main.pid), (self.ps.ACTIVE, pid))
        self.assertEqual(sup.stop("main"), 0)
        self.assertIsNone(stat(pid))
        # Not running, the dependency's failure is its own.
        self.assertEqual(sup.start("main"), 1)
        self.assertEqual((main.state, main.result), (self.ps.FAILED, "dependency"))

        # And stop() ends a process left in any state.
        os.unlink(flag)
        self.assertEqual(sup.start("main"), 0)
        pid = main.main.pid
        main.set_state(self.ps.FAILED)
        self.assertEqual(sup.stop("main"), 0)
        self.assertIsNone(stat(pid))
        self.assertEqual(main.state, self.ps.INACTIVE)


class EnvironmentTest(unittest.TestCase):
    def test_services_get_no_shell_proxy_or_preload(self):
        # An exported https_proxy would send a subscription fetch through the proxy it is
        # starting; LD_PRELOAD would ride into every daemon.
        sys.path.insert(0, HERE)
        import proxy_supervisor

        for key in ("https_proxy", "ALL_PROXY", "LD_PRELOAD", "PYTHONPATH", "SECRET_TOKEN"):
            self.assertFalse(proxy_supervisor._inherited(key), key)
        for key in ("HOME", "PATH", "LANG", "LC_ALL", "TZ", "SSL_CERT_FILE", "ANDROID_ROOT", "PROOT_TMP_DIR"):
            self.assertTrue(proxy_supervisor._inherited(key), key)


if __name__ == "__main__":
    unittest.main()
