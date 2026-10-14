#!/usr/bin/env python3
"""Per-user policies of the inbound manager (services.proxy-suite.inbounds.manager).

A policy says whether a user may connect and how much: switched on or off by hand, an
expiry time (or a term that starts with the first connection), a traffic allowance that may renew every day, week or month, how many
addresses may use it at once, and a speed limit. Declared users take theirs from
`inbounds.users.<name>.policy`; the manager's policy file overrides those field by field,
and holds the runtime users' whole. Only the manager (root) writes that file.

The manager's state file keeps what the policies are measured against: when each user's
traffic period began, and the speed slot (XRay user level) a limited user's sockets are
marked with. Traffic comes from the collector's file (proxy-suite-inbound-stats), whose
daily totals are summed from the period's first day, less what that day had carried before
the period began.

Whoever renders the inbounds (build-inbound.py, awg_inbound.py) asks statuses() which users
are active and at which level; this module never writes there.
"""

from __future__ import annotations

import calendar
import copy
import datetime
import fcntl
import json
import math
import os
import re
import secrets
import time

PERIODS = ("daily", "weekly", "monthly")
DEFAULT_POLICY = {
    "enabled": True,
    "expiresAt": None,
    "expiresAfter": None,
    "trafficLimit": None,
    "trafficPeriod": None,
    "ipLimit": None,
    "speedLimit": None,
    "meta": {},
}
FIELDS = tuple(DEFAULT_POLICY)
MAX_META_KEYS = 32
MAX_META_VALUE = 1024
STATE_VERSION = 1
MAX_TIME = 253402214400  # 9999-12-31


class PolicyError(ValueError):
    """A policy value that cannot be used."""


# --- parsing --------------------------------------------------------------------------

_SIZE = re.compile(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTP]?)(?:I?B)?\s*", re.IGNORECASE)
_RATE = re.compile(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([KMG]?)(?:BIT|BPS|BIT/S|B/S)?\s*", re.IGNORECASE)
_RELATIVE = re.compile(r"\s*\+\s*([0-9]+)\s*([mhdw])\s*", re.IGNORECASE)
_DURATION = re.compile(r"\s*\+?\s*([0-9]+)\s*([mhdw])\s*", re.IGNORECASE)
SIZE_UNITS = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}
RATE_UNITS = {"": 1, "K": 1000, "M": 1000**2, "G": 1000**3}
RELATIVE_UNITS = {"m": 60, "h": 3600, "d": 86400, "w": 7 * 86400}


def parse_size(value) -> int | None:
    """Bytes, from an int or "50G", "1.5T", "512MiB": binary units, as clients show them.
    None, "", "none", "unlimited" and 0 mean no limit."""
    if value is None or value == 0:
        return None
    if type(value) is int:
        if value < 0:
            raise PolicyError(f"size {value} is negative")
        return value
    if not isinstance(value, str):
        raise PolicyError(f"size {json.dumps(value)} is neither a number nor a string")
    if value.strip().lower() in ("", "none", "unlimited", "0"):
        return None
    match = _SIZE.fullmatch(value)
    if not match:
        raise PolicyError(f"size {json.dumps(value)}: a number with K, M, G or T")
    return int(float(match.group(1)) * SIZE_UNITS[match.group(2).upper()])


def parse_rate(value) -> int | None:
    """Bits per second, from an int or "10M", "500k", "1G": decimal units, as ISPs sell them."""
    if value is None or value == 0:
        return None
    if type(value) is int:
        if value < 0:
            raise PolicyError(f"rate {value} is negative")
        return value
    if not isinstance(value, str):
        raise PolicyError(f"rate {json.dumps(value)} is neither a number nor a string")
    if value.strip().lower() in ("", "none", "unlimited", "0"):
        return None
    match = _RATE.fullmatch(value)
    if not match:
        raise PolicyError(f"rate {json.dumps(value)}: bits per second, a number with k, M or G")
    return int(float(match.group(1)) * RATE_UNITS[match.group(2).upper()])


def parse_speed(value) -> dict | None:
    """{"up": bit/s|None, "down": bit/s|None}, from one rate for both ("20M"), "down/up"
    ("20M/5M"), or such an object. None: no limit."""
    if value is None:
        return None
    if isinstance(value, dict):
        unknown = set(value) - {"up", "down"}
        if unknown:
            raise PolicyError(f"speedLimit: unknown keys {sorted(unknown)}")
        speed = {"up": parse_rate(value.get("up")), "down": parse_rate(value.get("down"))}
    elif isinstance(value, str) and "/" in value:
        down, up = value.split("/", 1)
        speed = {"up": parse_rate(up), "down": parse_rate(down)}
    else:
        rate = parse_rate(value)
        speed = {"up": rate, "down": rate}
    return speed if speed["up"] or speed["down"] else None


def parse_duration(value) -> int | None:
    """Seconds, from an int or "30d", "+12h" (m, h, d, w). None, "", "none" and 0: none."""
    if value is None or value == 0:
        return None
    if type(value) is int:
        if value < 0:
            raise PolicyError(f"duration {value} is negative")
        return value
    if not isinstance(value, str):
        raise PolicyError(f"duration {json.dumps(value)} is neither a number nor a string")
    text = value.strip()
    if text.lower() in ("", "none", "0"):
        return None
    if text.isdigit():
        return int(text)
    match = _DURATION.fullmatch(text)
    if not match:
        raise PolicyError(f"duration {json.dumps(value)}: a number with m, h, d or w, such as 30d")
    return int(match.group(1)) * RELATIVE_UNITS[match.group(2).lower()] or None


def _local_midnight(day: datetime.date) -> int:
    return int(time.mktime(day.timetuple()))


def parse_time(value, now: float | None = None) -> int | None:
    """A Unix time from an int, "2026-12-31" (the end of that day, local time),
    "2026-12-31T18:00" (local), an ISO time with its zone, or "+30d" from now (m, h, d, w).
    None, "", "never": no expiry."""
    if value is None:
        return None
    if type(value) is int:
        return value
    if not isinstance(value, str):
        raise PolicyError(f"time {json.dumps(value)} is neither a number nor a string")
    text = value.strip()
    if text.lower() in ("", "never", "none"):
        return None
    if text.isdigit():
        return int(text)
    relative = _RELATIVE.fullmatch(text)
    if relative:
        base = time.time() if now is None else now
        return int(base) + int(relative.group(1)) * RELATIVE_UNITS[relative.group(2).lower()]
    try:
        if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", text):
            return _local_midnight(datetime.date.fromisoformat(text) + datetime.timedelta(days=1))
        moment = datetime.datetime.fromisoformat(text)
    except ValueError:
        raise PolicyError(f"time {json.dumps(value)}: a date, an ISO time, a Unix time or +<n>d") from None
    return int(moment.timestamp())


# --- policies -------------------------------------------------------------------------


def _check_meta(value) -> dict:
    if not isinstance(value, dict):
        raise PolicyError("meta must be an object of strings")
    if len(value) > MAX_META_KEYS:
        raise PolicyError(f"meta holds at most {MAX_META_KEYS} keys")
    for key, item in value.items():
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", key):
            raise PolicyError(f"meta key {json.dumps(key)}: letters, digits, dot, dash and underscore, up to 64")
        if not isinstance(item, str) or len(item) > MAX_META_VALUE:
            raise PolicyError(f"meta.{key} must be a string of at most {MAX_META_VALUE} characters")
    return dict(value)


def normalize(fields: dict, now: float | None = None) -> dict:
    """Policy fields as the file keeps them, from what a person or a bot gave: sizes,
    rates and times in any form parse_* takes. Only the fields given."""
    if not isinstance(fields, dict):
        raise PolicyError("a policy is an object")
    unknown = set(fields) - set(FIELDS)
    if unknown:
        raise PolicyError(f"unknown policy fields: {', '.join(sorted(unknown))}")
    out: dict = {}
    for key, value in fields.items():
        if key == "enabled":
            if type(value) is not bool:
                raise PolicyError("enabled must be true or false")
            out[key] = value
        elif key == "expiresAt":
            # 0 is no expiry, as 0 is no limit in the other fields: not 1970.
            out[key] = None if value in (0, "0") else parse_time(value, now)
            if out[key] is not None and not 0 < out[key] < MAX_TIME:
                raise PolicyError(f"time {json.dumps(value)} is out of range")
        elif key == "expiresAfter":
            out[key] = parse_duration(value)
            if out[key] is not None and out[key] >= MAX_TIME:
                raise PolicyError(f"duration {json.dumps(value)} is out of range")
        elif key == "trafficLimit":
            out[key] = parse_size(value)
        elif key == "trafficPeriod":
            if value in (None, "", "none", "never"):
                out[key] = None
            elif value in PERIODS:
                out[key] = value
            else:
                raise PolicyError(f"trafficPeriod must be one of {', '.join(PERIODS)} or none")
        elif key == "ipLimit":
            if value in (None, 0, ""):
                out[key] = None
            elif type(value) is int and value > 0:
                out[key] = value
            elif isinstance(value, str) and value.isdigit():
                out[key] = int(value) or None
            else:
                raise PolicyError("ipLimit must be a positive number, or 0 for none")
        elif key == "speedLimit":
            out[key] = parse_speed(value)
        elif key == "meta":
            out[key] = _check_meta(value)
    return out


def check_stored(entry: dict) -> dict:
    """A stored policy, already normalized: the same check, which must change nothing."""
    normalized = normalize(entry)
    if normalized != entry:
        raise PolicyError("not in its stored form")
    return entry


def effective(declared: dict | None, stored: dict | None) -> dict:
    """The defaults, then the declared policy, then the stored one, field by field."""
    policy = copy.deepcopy(DEFAULT_POLICY)
    for layer in (declared or {}, stored or {}):
        for key in FIELDS:
            if key in layer:
                policy[key] = copy.deepcopy(layer[key])
    return policy


def declared_policies(spec: dict) -> dict[str, dict]:
    """The declared users' `policy` options, normalized; a bad one is left out (the module's
    assertions catch it at build time)."""
    policies = {}
    for name, user in (spec.get("users") or {}).items():
        declared = {k: v for k, v in (user.get("policy") or {}).items() if v is not None}
        try:
            policies[name] = normalize(declared)
        except PolicyError:
            continue
    return policies


# --- files ----------------------------------------------------------------------------


def read_json(path: str, default):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except FileNotFoundError:
        return copy.deepcopy(default)
    except (OSError, ValueError):
        return copy.deepcopy(default)
    return value if isinstance(value, type(default)) else copy.deepcopy(default)


def write_json(path: str, value, mode: int = 0o600) -> None:
    """Atomically, through a new file of its own next to it."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    tmp = os.path.join(directory, f".{os.path.basename(path)}.{secrets.token_hex(6)}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(value, indent=2, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class Locked:
    """flock on <path>.lock, for a read-modify-write of path."""

    def __init__(self, path: str):
        self.path = path + ".lock"
        self.fd = -1

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path) or ".", mode=0o700, exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        os.close(self.fd)


def load_policies(path: str) -> dict[str, dict]:
    """The policy file: {name: stored fields}; entries that do not hold up are left out."""
    raw = read_json(path, {})
    policies = {}
    for name, entry in (raw.get("users") or {}).items() if isinstance(raw.get("users"), dict) else []:
        try:
            policies[name] = check_stored(entry)
        except PolicyError:
            continue
    return policies


def _count(value) -> bool:
    return type(value) is int and value >= 0


def check_user_state(entry) -> dict:
    """A user's entry in the state file, as start_period() and roll_period() make it: the
    renderers read it at every start, so a bad one (an import, a hand edit) must not get in."""
    if not isinstance(entry, dict):
        raise PolicyError("a user's state is an object")
    for key in ("periodStart", "baselineUp", "baselineDown"):
        if key in entry and not _count(entry[key]):
            raise PolicyError(f"{key} must be a whole number")
    # A date the calendar functions still take (the year 9999).
    if entry.get("periodStart", 0) >= MAX_TIME:
        raise PolicyError("periodStart is too far ahead")
    if "anchorDay" in entry and not (type(entry["anchorDay"]) is int and 1 <= entry["anchorDay"] <= 31):
        raise PolicyError("anchorDay must be a day of the month")
    if "notified" in entry and not isinstance(entry["notified"], dict):
        raise PolicyError("notified must be an object")
    return entry


def load_state(path: str) -> dict:
    """The state file; entries that do not hold up are left out, as the policy file's are."""
    state = read_json(path, {})
    state.setdefault("version", STATE_VERSION)
    for key in ("users", "slots", "bans", "seen", "subscriptions"):
        if not isinstance(state.get(key), dict):
            state[key] = {}
    for name, entry in list(state["users"].items()):
        try:
            check_user_state(entry)
        except PolicyError:
            del state["users"][name]
    for name, slot in list(state["slots"].items()):
        if not (type(slot) is int and slot > 0):
            del state["slots"][name]
    for name, first in list(state["seen"].items()):
        if not isinstance(first, dict):
            del state["seen"][name]
    # Salts of the users whose subscription URL was moved on (proxy_inbound.subscription_token).
    for name, salt in list(state["subscriptions"].items()):
        if not is_subscription_salt(salt):
            del state["subscriptions"][name]
    return state


def is_subscription_salt(value) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value) is not None


def read_stats(path: str) -> dict:
    return read_json(path, {})


# --- traffic --------------------------------------------------------------------------


def day_key(ts: float) -> str:
    """The collector's day: its `date +%F`, in local time."""
    return time.strftime("%Y-%m-%d", time.localtime(ts))


def _counters(entry) -> tuple[int, int]:
    """(up, down) of one day's counters; nothing from a malformed entry, which must not stop
    the renderers that ask statuses()."""
    if not isinstance(entry, dict):
        return 0, 0

    def number(value) -> int:
        # jq may write a large sum as a float.
        return int(value) if type(value) in (int, float) and math.isfinite(value) and value >= 0 else 0

    return number(entry.get("up", 0)), number(entry.get("down", 0))


def day_traffic(stats: dict, day: str, name: str) -> tuple[int, int]:
    buckets = (stats.get("days") or {}).get(day)
    users = buckets.get("user") if isinstance(buckets, dict) else None
    return _counters(users.get(name) if isinstance(users, dict) else None)


def day_total(stats: dict, day: str, name: str) -> int:
    return sum(day_traffic(stats, day, name))


def period_traffic(stats: dict, user_state: dict, name: str) -> tuple[int, int]:
    """(up, down) since the period began: every day from its first, less what that day had
    before it (the baselines). A user the manager has not measured yet has used nothing:
    their count begins when it first sees them, not with whatever the file kept before."""
    start = user_state.get("periodStart")
    if not start:
        return 0, 0
    first = day_key(start)
    up = down = 0
    days = stats.get("days")
    for day, buckets in (days.items() if isinstance(days, dict) else []):
        if not isinstance(day, str) or day < first or not isinstance(buckets, dict):
            continue
        users = buckets.get("user")
        day_up, day_down = _counters(users.get(name) if isinstance(users, dict) else None)
        up += day_up
        down += day_down
    return (max(up - int(user_state.get("baselineUp", 0) or 0), 0),
            max(down - int(user_state.get("baselineDown", 0) or 0), 0))


def used_bytes(stats: dict, user_state: dict, name: str) -> int:
    return sum(period_traffic(stats, user_state, name))


def _add_period(day: datetime.date, period: str, anchor_day: int) -> datetime.date:
    if period == "daily":
        return day + datetime.timedelta(days=1)
    if period == "weekly":
        return day + datetime.timedelta(days=7)
    year, month = (day.year + 1, 1) if day.month == 12 else (day.year, day.month + 1)
    return datetime.date(year, month, min(anchor_day, calendar.monthrange(year, month)[1]))


def period_end(policy: dict, user_state: dict) -> int | None:
    """When the current period ends and the traffic starts over, or None."""
    period = policy.get("trafficPeriod")
    start = user_state.get("periodStart")
    if period not in PERIODS or not start:
        return None
    first = datetime.date.fromtimestamp(start)
    anchor = int(user_state.get("anchorDay") or first.day)
    return _local_midnight(_add_period(first, period, anchor))


def start_period(stats: dict, name: str, now: float) -> dict:
    """A period that begins now: the day so far is the baseline. A renewing period begins
    at midnight, so a monthly one renews on this day of the month."""
    up, down = day_traffic(stats, day_key(now), name)
    return {
        "periodStart": int(now),
        "baselineUp": up,
        "baselineDown": down,
        "anchorDay": datetime.date.fromtimestamp(now).day,
    }


def roll_period(policy: dict, user_state: dict, now: float) -> bool:
    """Move a renewing period on past now, from boundary to boundary (midnights, so nothing
    of the day before counts). True when it moved."""
    moved = False
    while True:
        end = period_end(policy, user_state)
        if end is None or end > now:
            return moved
        user_state["periodStart"] = end
        user_state["baselineUp"] = user_state["baselineDown"] = 0
        moved = True


# --- status ---------------------------------------------------------------------------


def on_hold(policy: dict) -> bool:
    """A term that starts with the first connection, and has not: expiresAfter without
    expiresAt. An expiresAt set by hand wins over it."""
    return policy.get("expiresAt") is None and bool(policy.get("expiresAfter"))


def status(policy: dict, used: int, now: float) -> dict:
    """{"active", "reasons"}: why a user may not connect now, if they may not. A user on
    hold may: their term begins when they do."""
    reasons = []
    if not policy.get("enabled", True):
        reasons.append("disabled")
    expires = policy.get("expiresAt")
    if expires is not None and now >= expires:
        reasons.append("expired")
    limit = policy.get("trafficLimit")
    if limit is not None and used >= limit:
        reasons.append("traffic")
    return {"active": not reasons, "reasons": reasons}


def user_names(spec: dict, runtime_users) -> list[str]:
    return sorted(set(spec.get("users") or {}) | set(runtime_users))


def statuses(spec: dict, runtime_users, now: float | None = None) -> dict[str, dict]:
    """Each user's {"active", "level", "reasons"}, for the renderers. Empty without the
    manager: everyone active, nobody limited, as before it."""
    manager = spec.get("manager")
    if not manager:
        return {}
    now = time.time() if now is None else now
    declared = declared_policies(spec)
    stored = load_policies(manager["policyFile"])
    state = load_state(manager["stateFile"])
    stats = read_stats(manager["statsFile"])
    result = {}
    for name in user_names(spec, runtime_users):
        policy = effective(declared.get(name), stored.get(name))
        user_state = copy.deepcopy(state["users"].get(name) or {})
        roll_period(policy, user_state, now)
        view = status(policy, used_bytes(stats, user_state, name), now)
        slot = state["slots"].get(name)
        limited = bool(policy.get("speedLimit")) and manager.get("speedLimits", False)
        view["level"] = int(slot) if limited and isinstance(slot, int) and slot > 0 else 0
        result[name] = view
    return result
