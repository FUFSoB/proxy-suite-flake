import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SUPERVISOR = os.path.join(HERE, "proxy_supervisor.py")


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
            "tmpfiles": [f"d {self.run_dir} 0700 - - -"],
        }
        with open(self.manifest + ".tmp", "w") as f:
            json.dump(manifest, f)
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


if __name__ == "__main__":
    unittest.main()
