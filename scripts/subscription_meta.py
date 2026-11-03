#!/usr/bin/env python3
"""What a subscription server says about the subscription in its response headers, and the
device a fetch may name to it (opt-in, per subscription).

The headers are the ones panels (Marzban, 3x-ui, Remnawave) send and clients (v2rayN,
Hiddify, Happ) show: traffic and expiry, a title, an announcement, where to get support and
how often to refetch. Whoever serves the subscription writes them, so all of it is text from
anywhere: cut to size and stripped of what could rewrite a terminal or reorder a line.

`hwid` (run by root, never by the fetcher): the HWID a fetch sends as x-hwid. Derived from
/etc/machine-id, as systemd's application-specific IDs are, so it survives a lost state
directory and does not hand out the machine ID itself; a random one kept in a state file
where there is no machine ID; or one given in a file, to keep a panel's device slot after a
move to another machine.
"""

import argparse
import base64
import binascii
import hashlib
import hmac
import os
import platform
import re
import secrets
import sys
import urllib.parse

TITLE_MAX = 128
ANNOUNCE_MAX = 2000
URL_MAX = 512
# profile-update-interval is in hours. Not more often than hourly: the server would otherwise
# set how often this host calls it.
INTERVAL_HOURS_MIN = 1
INTERVAL_HOURS_MAX = 720
_COUNTER_MAX = 1 << 62
# A link a front end may one day make clickable: never javascript:, data: or file:.
URL_SCHEMES = ("http", "https", "tg", "mailto")

# C0 and C1 controls but newline (announcements have lines), and the invisible marks that
# reorder or hide text: bidirectional overrides and isolates, zero-width characters.
_HIDDEN = re.compile("[\x00-\x09\x0b-\x1f\x7f-\x9f​-‏ -‮⁠-⁩﻿]")

# The keys proxy-ctl may show anyone: the whole of it stays beside the cache, which the
# "secrets" scope guards (a profile page's URL is the subscription's own, token and all).
PUBLIC_KEYS = (
    "title",
    "upload",
    "download",
    "total",
    "expire",
    "updateIntervalHours",
    "fetchedAt",
    "userAgent",
    "deviceInfo",
)

HWID_LENGTH = 32
# The application ID the HWID is keyed with, as sd_id128_get_machine_app_specific() does.
_HWID_APP_ID = b"proxy-suite-subscription-hwid"
_HWID_SHAPE = re.compile(r"[\x21-\x7e]{1,128}")


def _header_value(value) -> str:
    """http.client decodes header bytes as Latin-1; panels send UTF-8 (a Cyrillic title)."""
    value = str(value)
    try:
        return value.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return value


def _decoded(value: str) -> "str | None":
    """A header's text, from base64 when it says "base64:" first (it may have to: headers are
    ASCII on the wire, and a title often is not)."""
    if value[:7].lower() != "base64:":
        return value
    raw = "".join(value[7:].split()).translate(str.maketrans("-_", "+/"))
    try:
        return base64.b64decode(raw + "=" * (-len(raw) % 4), validate=True).decode("utf-8")
    except (binascii.Error, ValueError, UnicodeDecodeError):
        return None


def _cut(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def header_text(value, limit: int, multiline: bool = False) -> "str | None":
    if value is None:
        return None
    text = _decoded(_header_value(value).strip())
    if text is None:
        return None
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if multiline:
        text = re.sub(r"[ \t]+", " ", text.replace("\t", " "))
        text = re.sub(r"\n{3,}", "\n\n", text)
    else:
        text = re.sub(r"\s+", " ", text)
    text = _HIDDEN.sub("", text).strip()
    return _cut(text, limit) or None


def header_url(value) -> "str | None":
    text = header_text(value, URL_MAX * 2)
    if not text or len(text) > URL_MAX or re.search(r"\s", text):
        return None
    try:
        parts = urllib.parse.urlsplit(text)
    except ValueError:
        return None
    if parts.scheme.lower() not in URL_SCHEMES:
        return None
    if parts.scheme.lower() in ("http", "https") and not parts.netloc:
        return None
    return text


def userinfo(value) -> dict:
    """subscription-userinfo: "upload=1; download=2; total=3; expire=1700000000", bytes and a
    Unix time; total and expire 0 for none."""
    out = {}
    for part in _header_value(value).split(";"):
        key, sep, number = part.partition("=")
        key = key.strip().lower()
        if not sep or key not in ("upload", "download", "total", "expire"):
            continue
        try:
            n = int(float(number.strip()))
        except (ValueError, OverflowError):
            continue
        if 0 <= n < _COUNTER_MAX:
            out[key] = n
    return out


def interval_hours(value) -> "int | None":
    try:
        hours = float(_header_value(value).strip())
    except ValueError:
        return None
    if hours != hours or hours <= 0:
        return None
    return int(round(min(max(hours, INTERVAL_HOURS_MIN), INTERVAL_HOURS_MAX)))


def from_headers(headers) -> dict:
    """The subscription's metadata from a response's headers (any mapping; names in any case)."""
    if headers is None:
        return {}
    lowered = {str(k).lower(): v for k, v in headers.items()}
    meta = {}
    if (value := lowered.get("subscription-userinfo")) is not None:
        meta.update(userinfo(value))
    fields = (
        ("title", "profile-title", lambda v: header_text(v, TITLE_MAX)),
        ("announce", "announce", lambda v: header_text(v, ANNOUNCE_MAX, multiline=True)),
        ("supportUrl", "support-url", header_url),
        ("webPageUrl", "profile-web-page-url", header_url),
        ("updateIntervalHours", "profile-update-interval", interval_hours),
    )
    for key, header, parse in fields:
        if (value := lowered.get(header)) is not None and (parsed := parse(value)) is not None:
            meta[key] = parsed
    return meta


def public(meta: dict) -> dict:
    return {k: meta[k] for k in PUBLIC_KEYS if meta.get(k) is not None}


def device_headers(hwid: str) -> dict:
    """What Happ and v2RayTun tell a panel about the device: its HWID and system. The
    model is the machine's architecture, as their desktop builds send: no host name."""
    uname = platform.uname()

    def clean(value, fallback):
        value = re.sub(r"[^\x20-\x7e]", "", str(value or "")).strip()
        return value[:64] or fallback

    return {
        "x-hwid": hwid,
        "x-device-os": clean(uname.system, "Linux"),
        "x-ver-os": clean(uname.release, "unknown"),
        "x-device-model": clean(uname.machine, "unknown"),
    }


def valid_hwid(value: str) -> bool:
    return bool(_HWID_SHAPE.fullmatch(value))


def hwid(override_file: "str | None", machine_id_file: str, fallback_file: str) -> str:
    if override_file:
        with open(override_file, encoding="utf-8") as f:
            value = f.read().strip()
        if not valid_hwid(value):
            raise ValueError(f"{override_file}: an HWID is 1 to 128 printable characters, no spaces")
        return value
    try:
        with open(machine_id_file, encoding="ascii") as f:
            machine_id = f.read().strip()
    except (OSError, UnicodeDecodeError):
        machine_id = ""
    if re.fullmatch(r"[0-9a-f]{32}", machine_id):
        return hmac.new(bytes.fromhex(machine_id), _HWID_APP_ID, hashlib.sha256).hexdigest()[:HWID_LENGTH]
    try:
        with open(fallback_file, encoding="ascii") as f:
            value = f.read().strip()
        if re.fullmatch(r"[0-9a-f]{%d}" % HWID_LENGTH, value):
            return value
    except (OSError, UnicodeDecodeError):
        pass
    value = secrets.token_hex(HWID_LENGTH // 2)
    os.makedirs(os.path.dirname(fallback_file) or ".", exist_ok=True)
    tmp = f"{fallback_file}.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as f:
        f.write(value + "\n")
    os.replace(tmp, fallback_file)
    return value


def main() -> None:
    ap = argparse.ArgumentParser(description="The HWID subscription fetches send as x-hwid.")
    sub = ap.add_subparsers(dest="command", required=True)
    h = sub.add_parser("hwid")
    h.add_argument("--file", default=None, help="Use the HWID in this file.")
    h.add_argument("--machine-id", default="/etc/machine-id", dest="machine_id")
    h.add_argument("--fallback", required=True, help="Where a random HWID is kept without a machine ID.")
    args = ap.parse_args()
    try:
        print(hwid(args.file, args.machine_id, args.fallback))
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
