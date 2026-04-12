#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path

BUILTIN_ACTIVATION_FALLBACKS = {
    "list-instagram.txt": "general",
    "list-soundcloud.txt": "general",
    "list-twitter.txt": "general",
}

FAMILY_PATTERNS = {
    "general": {
        "match": ["list-general.txt", "list-general-user.txt"],
        "remove": [
            r'\s+--hostlist=(?:"[^"]*/hostlists/list-general\.txt"|[^ ]*/hostlists/list-general\.txt)',
            r'\s+--hostlist=(?:"[^"]*/hostlists/list-general-user\.txt"|[^ ]*/hostlists/list-general-user\.txt)',
        ],
    },
    "google": {
        "match": ["list-google.txt"],
        "remove": [
            r'\s+--hostlist=(?:"[^"]*/hostlists/list-google\.txt"|[^ ]*/hostlists/list-google\.txt)',
        ],
    },
    "instagram": {
        "match": ["list-instagram.txt"],
        "remove": [
            r'\s+--hostlist=(?:"[^"]*/hostlists/list-instagram\.txt"|[^ ]*/hostlists/list-instagram\.txt)',
        ],
    },
    "soundcloud": {
        "match": ["list-soundcloud.txt"],
        "remove": [
            r'\s+--hostlist=(?:"[^"]*/hostlists/list-soundcloud\.txt"|[^ ]*/hostlists/list-soundcloud\.txt)',
        ],
    },
    "twitter": {
        "match": ["list-twitter.txt"],
        "remove": [
            r'\s+--hostlist=(?:"[^"]*/hostlists/list-twitter\.txt"|[^ ]*/hostlists/list-twitter\.txt)',
        ],
    },
}


def locate_nfqws_block(lines: list[str]) -> tuple[int, int]:
    start = None
    for index, line in enumerate(lines):
        if line.startswith('NFQWS_OPT="'):
            start = index
            break
    if start is None:
        raise ValueError("Could not find NFQWS_OPT block in zapret config")

    for index in range(start + 1, len(lines)):
        if lines[index] == '"':
            return start, index

    raise ValueError("Could not find the end of the NFQWS_OPT block in zapret config")


def strip_trailing_new(line: str) -> str:
    return re.sub(r"(?:\s+--new)+\s*$", "", line.strip())


def normalize_spaces(line: str) -> str:
    return re.sub(r"\s+", " ", line).strip()


def add_standard_excludes(line: str, standard_excludes: list[str]) -> str:
    for arg in standard_excludes:
        if arg not in line:
            line = f"{line} {arg}"
    return line


def render_preset_clone(
    line: str,
    family: str,
    hostlist_path: str,
    standard_excludes: list[str],
) -> str:
    rendered = strip_trailing_new(line)
    for pattern in FAMILY_PATTERNS[family]["remove"]:
        rendered = re.sub(pattern, "", rendered)
    rendered = normalize_spaces(rendered)
    rendered = f'{rendered} --hostlist="{hostlist_path}"'
    rendered = add_standard_excludes(rendered, standard_excludes)
    return f"{normalize_spaces(rendered)} --new"


def render_custom_args(
    fragment: str,
    hostlist_path: str,
    standard_excludes: list[str],
) -> str:
    rendered = strip_trailing_new(fragment)
    rendered = re.sub(r'\s+--hostlist=(?:"[^"]+"|\S+)', "", rendered)
    rendered = normalize_spaces(rendered)
    rendered = f'{rendered} --hostlist="{hostlist_path}"'
    rendered = add_standard_excludes(rendered, standard_excludes)
    return f"{normalize_spaces(rendered)} --new"


def clone_family_lines(
    existing_lines: list[str],
    family: str,
    hostlist_path: str,
    standard_excludes: list[str],
) -> list[str]:
    matches = [
        line
        for line in existing_lines
        if any(marker in line for marker in FAMILY_PATTERNS[family]["match"])
    ]
    if not matches:
        raise ValueError(f"Preset family '{family}' is not present in the selected zapret config")
    return [render_preset_clone(line, family, hostlist_path, standard_excludes) for line in matches]


def activate_builtin_hostlists(
    existing_lines: list[str],
    hostlists_dir: Path,
    standard_excludes: list[str],
) -> list[str]:
    generated_lines: list[str] = []
    full_text = "\n".join(existing_lines)

    for filename, family in BUILTIN_ACTIVATION_FALLBACKS.items():
        marker = str(hostlists_dir / filename)
        if marker in full_text:
            continue
        generated_lines.extend(
            clone_family_lines(existing_lines, family, marker, standard_excludes)
        )

    return generated_lines


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Append proxy-suite custom hostlist rules to a zapret config."
    )
    parser.add_argument("--config", required=True, help="Path to the selected zapret config file")
    parser.add_argument("--spec", required=True, help="JSON file describing custom hostlist rules")
    args = parser.parse_args()

    config_path = Path(args.config)
    spec_path = Path(args.spec)
    hostlists_dir = config_path.parent / "hostlists"
    standard_excludes = [
        f'--hostlist-exclude="{hostlists_dir / "list-exclude.txt"}"',
        f'--hostlist-exclude="{hostlists_dir / "list-exclude-user.txt"}"',
        f'--ipset-exclude="{hostlists_dir / "ipset-exclude.txt"}"',
        f'--ipset-exclude="{hostlists_dir / "ipset-exclude-user.txt"}"',
    ]

    lines = config_path.read_text(encoding="utf-8").splitlines()
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    entries = spec.get("entries", [])
    include_extra_upstream_lists = spec.get("includeExtraUpstreamLists", True)

    start, end = locate_nfqws_block(lines)
    nfqws_lines = lines[start + 1 : end]
    generated_lines: list[str] = (
        activate_builtin_hostlists(nfqws_lines, hostlists_dir, standard_excludes)
        if include_extra_upstream_lists
        else []
    )

    for entry in entries:
        hostlist_path = str(hostlists_dir / f'list-{entry["name"]}.txt')
        preset = entry.get("preset")
        if preset:
            generated_lines.extend(
                clone_family_lines(nfqws_lines, preset, hostlist_path, standard_excludes)
            )
        for fragment in entry.get("nfqwsArgs", []):
            generated_lines.append(render_custom_args(fragment, hostlist_path, standard_excludes))

    updated_lines = lines[:end] + generated_lines + lines[end:]
    config_path.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
