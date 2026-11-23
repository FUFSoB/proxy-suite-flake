#!/usr/bin/env python3
"""Tests for the HOME/WHITELIST auto-group classifier.

The classification itself is Nix (modules/proxy-suite/autogroups.nix). This script checks it
twice: against a Python transcription of the same rules, and, when nix-instantiate and
<nixpkgs> are available, against the real Nix code. It also evaluates mkAutoGroups and checks
that the generated whitelist globs match whitelist tags and no home tags.
"""

import functools
import json
import re
import shutil
import subprocess
import unicodedata
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parent.parent
AUTOGROUPS_NIX = REPOSITORY / "modules" / "proxy-suite" / "autogroups.nix"

WHITELIST_TOKENS = ["WL", "WLTE", "LTE", "\U0001F3F3\uFE0F"]
TOKEN_SEPARATORS = re.compile(r"[-_ .|/\s]+")

# Tag -> expected classifyTag. At least ten cases, including every false-positive trap.
CASES = {
    "sub-WL": "whitelist",
    "sub-wl": "whitelist",
    "sub-Wlte": "whitelist",
    "sub-lte": "whitelist",
    "sub-\U0001F3F3\uFE0F": "whitelist",
    "sub-\U0001F3F3": "whitelist",
    "sub-complete": "home",
    "sub-welt": "home",
    "sub-WLTE-2": "whitelist",
    "sub-foo_lte_bar": "whitelist",
    "sub-LTEplus": "home",
    "sub-WhiteList": "home",
    "sub-wl.edge": "whitelist",
    "sub-x-\U0001F3F3\uFE0F-y": "whitelist",
}

# Tags whose generated globs are expected to match. The dot-separated one is handled
# separately: it is a known glob limitation, not a classifier failure.
GLOB_WHITELIST_TAGS = [
    tag for tag, kind in CASES.items() if kind == "whitelist" and "." not in tag
]
GLOB_HOME_TAGS = [tag for tag, kind in CASES.items() if kind == "home"]


def tokenize(tag):
    return [token for token in TOKEN_SEPARATORS.split(tag) if token]


def fold(text):
    # Python can do the full Unicode job; Nix folds ASCII only, which the cases above avoid.
    return unicodedata.normalize("NFKC", text).replace("\ufe0f", "").casefold()


def is_whitelist(tag, tokens=WHITELIST_TOKENS):
    wanted = {fold(token) for token in tokens}
    return any(fold(token) in wanted for token in tokenize(tag))


def classify(tag):
    return "whitelist" if is_whitelist(tag) else "home"


def glob_to_regex(pattern):
    # The same translation as glob_regex in modules/proxy-suite/outbound-groups.jq.
    return "^" + "".join(
        ".*" if ch == "*" else "." if ch == "?" else re.escape(ch) for ch in pattern
    ) + r"\Z"


def glob_matches(pattern, tag):
    return re.match(glob_to_regex(pattern), tag) is not None


def nix_string(value):
    return json.dumps(value, ensure_ascii=False)


def nix_list(values):
    return "[ " + " ".join(nix_string(value) for value in values) + " ]"


@functools.lru_cache(maxsize=1)
def nix_available():
    if not shutil.which("nix-instantiate"):
        return False
    try:
        subprocess.run(
            ["nix-instantiate", "--eval", "--strict", "--expr", "(import <nixpkgs> {}).lib.version"],
            check=True,
            capture_output=True,
            text=True,
            timeout=180,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def nix_eval(expression):
    completed = subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression],
        check=True,
        capture_output=True,
        text=True,
        timeout=180,
    )
    return json.loads(completed.stdout)


def nix_preamble():
    return (
        "let\n"
        "  lib = (import <nixpkgs> {}).lib;\n"
        "  autogroups = import " + nix_string(str(AUTOGROUPS_NIX)) + " { inherit lib; };\n"
    )


@functools.lru_cache(maxsize=1)
def nix_classes():
    tags = list(CASES)
    expression = (
        nix_preamble()
        + "  config = { whitelistTokens = " + nix_list(WHITELIST_TOKENS) + "; };\n"
        + "in map (tag: autogroups.classifyTag config tag) " + nix_list(tags) + "\n"
    )
    return nix_eval(expression)


@functools.lru_cache(maxsize=1)
def nix_whitelist_globs():
    expression = (
        nix_preamble()
        + "in (autogroups.mkAutoGroups {\n"
        + "  config = { enable = true; whitelistTokens = " + nix_list(WHITELIST_TOKENS) + "; };\n"
        + "  subscriptions = [ { tag = \"sub\"; } { tag = \"mobile-wl\"; } ];\n"
        + "}).groups.whitelist.match\n"
    )
    return nix_eval(expression)


class ClassifyTests(unittest.TestCase):
    def test_python_transcription(self):
        for tag, expected in CASES.items():
            with self.subTest(tag=tag):
                self.assertEqual(classify(tag), expected)

    def test_token_boundaries(self):
        self.assertEqual(tokenize("sub-foo_lte_bar"), ["sub", "foo", "lte", "bar"])
        self.assertEqual(tokenize("sub-wl.edge"), ["sub", "wl", "edge"])
        self.assertNotIn("lte", tokenize("sub-complete"))
        self.assertNotIn("wl", tokenize("sub-welt"))

    def test_nix_matches_cases(self):
        if not nix_available():
            self.skipTest("nix-instantiate or <nixpkgs> is unavailable")
        expected = [CASES[tag] for tag in CASES]
        self.assertEqual(nix_classes(), expected)


class GlobTests(unittest.TestCase):
    def setUp(self):
        if not nix_available():
            self.skipTest("nix-instantiate or <nixpkgs> is unavailable")
        self.globs = nix_whitelist_globs()

    def test_globs_are_subscription_scoped(self):
        self.assertTrue(all(glob.startswith(("sub-", "mobile-wl-")) for glob in self.globs))
        self.assertTrue(len(self.globs) > len(WHITELIST_TOKENS))

    def test_globs_match_whitelist_tags(self):
        for tag in GLOB_WHITELIST_TAGS:
            with self.subTest(tag=tag):
                self.assertTrue(
                    any(glob_matches(glob, tag) for glob in self.globs),
                    "no generated glob matches " + tag,
                )

    def test_globs_do_not_match_home_tags(self):
        for tag in GLOB_HOME_TAGS:
            with self.subTest(tag=tag):
                self.assertFalse(
                    any(glob_matches(glob, tag) for glob in self.globs),
                    "a generated glob wrongly matches " + tag,
                )

    def test_case_insensitive_glob(self):
        self.assertTrue(any(glob_matches(glob, "sub-wLtE-2") for glob in self.globs))

    def test_emoji_vs16_glob(self):
        self.assertTrue(any(glob_matches(glob, "sub-\U0001F3F3\uFE0F") for glob in self.globs))
        self.assertTrue(any(glob_matches(glob, "sub-\U0001F3F3") for glob in self.globs))

    def test_dot_separator_needs_extra_glob(self):
        # classifyTag handles ".", but a generated glob cannot: the glob language has no
        # character class and only "-"/"_" are emitted. Documented in autogroups-draft.md.
        self.assertEqual(classify("sub-wl.edge"), "whitelist")
        self.assertFalse(any(glob_matches(glob, "sub-wl.edge") for glob in self.globs))


if __name__ == "__main__":
    unittest.main()
