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
