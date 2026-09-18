#!/usr/bin/env python3
"""patch-zapret-config.py: the NFQWS_OPT rewrites, on strings only."""

import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "patch_zapret_config", Path(__file__).with_name("patch-zapret-config.py")
)
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)

HOSTLISTS = "/opt/zapret/hostlists"
EXCLUDES = [
    f'--hostlist-exclude="{HOSTLISTS}/list-exclude.txt"',
    f'--ipset-exclude="{HOSTLISTS}/ipset-exclude.txt"',
]
GENERAL = (
    f'--filter-tcp=443 --hostlist="{HOSTLISTS}/list-general.txt" '
    "--dpi-desync=fake --dpi-desync-ttl=6 --new"
)
IPSET_ALL = f'--filter-udp=443 --ipset="{HOSTLISTS}/ipset-all.txt" --dpi-desync=fake --new'
DISCORD = "--filter-l7=discord,stun --dpi-desync=fake --new"


class CloneTests(unittest.TestCase):
    def test_family_clone_repoints_the_hostlist_and_keeps_the_strategy(self):
        (line,) = patch.clone_family_lines([GENERAL], "general", "/run/mine.txt", EXCLUDES)
        self.assertIn('--hostlist="/run/mine.txt"', line)
        self.assertNotIn("list-general.txt", line)
        self.assertIn("--dpi-desync=fake", line)
        self.assertIn("--dpi-desync-ttl=6", line)
        self.assertTrue(line.endswith("--new"))
        self.assertEqual(line.count("--new"), 1)
        for exclude in EXCLUDES:
            self.assertIn(exclude, line)

    def test_ipset_clone_repoints_the_ipset(self):
        (line,) = patch.clone_ipset_lines([IPSET_ALL], "all", "/run/mine-ips.txt", EXCLUDES)
        self.assertIn('--ipset="/run/mine-ips.txt"', line)
        self.assertNotIn("ipset-all.txt", line)
        self.assertNotIn("--hostlist=", line)
        self.assertTrue(line.endswith("--new"))

    def test_protocol_clone_keeps_the_line_as_is(self):
        (line,) = patch.clone_protocol_lines([DISCORD], "discord-voice")
        self.assertEqual(line, DISCORD)

    def test_a_missing_family_is_an_error(self):
        for call in (
            lambda: patch.clone_family_lines([IPSET_ALL], "google", "/run/x.txt", EXCLUDES),
            lambda: patch.clone_ipset_lines([GENERAL], "all", "/run/x.txt", EXCLUDES),
            lambda: patch.clone_protocol_lines([GENERAL], "discord-voice"),
        ):
            with self.assertRaises(ValueError):
                call()

    def test_custom_args_get_one_hostlist_and_one_ipset_form(self):
        fragment = "--filter-tcp=80 --dpi-desync=split2"
        host = patch.render_custom_args(fragment, "/run/mine.txt", EXCLUDES)
        ips = patch.render_custom_ipset_args(fragment, "/run/mine-ips.txt", EXCLUDES)
        self.assertIn('--hostlist="/run/mine.txt"', host)
        self.assertNotIn("--ipset=", host)
        self.assertIn('--ipset="/run/mine-ips.txt"', ips)
        self.assertNotIn("--hostlist=", ips)

    def test_builtin_activation_only_adds_missing_lists(self):
        instagram = f'--filter-tcp=443 --hostlist="{HOSTLISTS}/list-instagram.txt" --new'
        added = patch.activate_builtin_hostlists(
            [GENERAL, instagram], Path(HOSTLISTS), EXCLUDES
        )
        joined = "\n".join(added)
        self.assertNotIn("list-instagram.txt", joined)
        self.assertIn("list-soundcloud.txt", joined)
        self.assertIn("list-twitter.txt", joined)


class BlockTests(unittest.TestCase):
    def test_locate_nfqws_block(self):
        lines = ['OTHER=1', 'NFQWS_OPT="', GENERAL, '"', "TAIL=2"]
        start, end = patch.locate_nfqws_block(lines)
        self.assertEqual((start, end), (1, 3))

    def test_a_config_without_the_block_is_an_error(self):
        with self.assertRaises(ValueError):
            patch.locate_nfqws_block(["OTHER=1"])


if __name__ == "__main__":
    unittest.main()
