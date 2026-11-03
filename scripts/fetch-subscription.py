#!/usr/bin/env python3
"""Read a subscription URL from stdin and emit a JSON array of backend outbounds."""

import argparse
import json
import re
import signal
import subprocess
import sys
import time
import urllib.error

import subscription_meta
from proxy_parsing import (
    DEFAULT_USER_AGENT,
    FetchError,
    checked_tweaks,
    decode_subscription,
    fetch_subscription,
    json_subscription_entries,
    parse_hybrid_subscription,
    parse_json_subscription,
    parse_subscription,
)

# The whole fetch: the socket timeout bounds one read only, and a server trickling its
# reply would otherwise hold a cold start, which waits on this, for as long as it liked.
OVERALL_DEADLINE_SECONDS = 90


def _out_of_time(_signum, _frame):
    raise FetchError(f"subscription fetch took longer than {OVERALL_DEADLINE_SECONDS}s")


def _describe(exc: Exception) -> str:
    """The error, unless it may quote the URL: http.client's InvalidURL and "nonnumeric port"
    carry the path or the userinfo, which hold the subscription's token."""
    if isinstance(exc, (FetchError, urllib.error.URLError, TimeoutError, ConnectionError)):
        return str(exc)
    return type(exc).__name__


# Runs of the backend's own check one subscription may take, and their wall time: past
# either, what is left goes unchecked rather than dropped.
MAX_CHECK_RUNS = 256
CHECK_BUDGET_SECONDS = 120

# Where the backend's refusal names the outbound at fault.
_XRAY_REFUSED_TAG = re.compile(r"failed to build outbound config with tag (.*?)(?: > |$)", re.MULTILINE)
_SING_BOX_REFUSED_INDEX = re.compile(r"\boutbounds?\[(\d+)\]")


class _OutOfBudget(Exception):
    pass


class _Checker:
    """The backend's own config check of a batch: one entry it refuses would fail its whole
    start, every other outbound with it, so the refused ones go here instead."""

    def __init__(self, kind: str, binary: str):
        self.kind = kind
        self.binary = binary
        self.runs = 0
        self.deadline = time.monotonic() + CHECK_BUDGET_SECONDS

    def refused(self, outbounds: list[dict]) -> "int | None":
        """None when the backend takes the batch; else the index of the outbound its error
        names, or -1 when it names none."""
        if self.runs >= MAX_CHECK_RUNS or time.monotonic() >= self.deadline:
            raise _OutOfBudget
        self.runs += 1
        if self.kind == "sing-box":
            argv = [self.binary, "check", "-c", "/dev/stdin"]
            obs = [{k: v for k, v in ob.items() if k not in ("detour", "domain_resolver")} for ob in outbounds]
        else:
            argv = [self.binary, "run", "-test", "-format", "json", "-c", "stdin:"]
            obs = [{k: v for k, v in ob.items() if k != "proxySettings"} for ob in outbounds]
        try:
            result = subprocess.run(
                argv,
                input=json.dumps({"outbounds": obs}).encode(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=max(self.deadline - time.monotonic(), 1),
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise _OutOfBudget from None
        if result.returncode == 0:
            return None
        error = result.stderr.decode("utf-8", errors="replace")
        if self.kind == "sing-box":
            match = _SING_BOX_REFUSED_INDEX.search(error)
            if match and int(match.group(1)) < len(outbounds):
                return int(match.group(1))
        elif match := _XRAY_REFUSED_TAG.search(error):
            for index, ob in enumerate(outbounds):
                if ob.get("tag") == match.group(1):
                    return index
        return -1

    def keep(self, outbounds: list[dict]) -> list[dict]:
        """The outbounds the backend takes, dropping each one it refuses."""
        if not outbounds:
            return outbounds
        # A check that fails on nothing at all says nothing about the entries.
        try:
            works = self.refused([]) is None
        except (OSError, _OutOfBudget):
            works = False
        if not works:
            print(f"warning: {self.kind}'s config check does not run; entries left unchecked", file=sys.stderr)
            return outbounds
        return self._keep(list(outbounds))

    def _drop(self, outbound: dict) -> None:
        print(f"warning: skipping entry {outbound.get('tag')!r}: {self.kind} refuses it", file=sys.stderr)

    def _keep(self, batch: list[dict]) -> list[dict]:
        while batch:
            try:
                refused = self.refused(batch)
            except (OSError, _OutOfBudget):
                print(
                    f"warning: {len(batch)} entries left unchecked: {self.kind}'s check could not finish",
                    file=sys.stderr,
                )
                return batch
            if refused is None:
                return batch
            if refused >= 0:
                self._drop(batch.pop(refused))
                continue
            # An error that names no outbound: bisect.
            if len(batch) == 1:
                self._drop(batch[0])
                return []
            middle = len(batch) // 2
            return self._keep(batch[:middle]) + self._keep(batch[middle:])
        return batch


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Fetch a proxy subscription URL from stdin and emit a backend outbound JSON array."
    )
    ap.add_argument(
        "--tag-prefix",
        required=True,
        dest="tag_prefix",
        help="Prefix for outbound tags, e.g. 'my-sub'.",
    )
    ap.add_argument("--backend", choices=["sing-box", "xray", "hybrid"], default="sing-box")
    ap.add_argument("--routing-mark", type=int, default=None, dest="routing_mark")
    ap.add_argument(
        "--links-out", default=None, dest="links_out", help="Also write {tag: original URI} here, for sharing."
    )
    # For a caller that drops privileges first: root opens the file, this only writes to it.
    ap.add_argument(
        "--links-fd", type=int, default=None, dest="links_fd", help="As --links-out, to this open descriptor."
    )
    ap.add_argument(
        "--allow-private-servers",
        action="store_true",
        dest="allow_private",
        help="Keep entries whose server is on a private network (RFC 1918, CGNAT, ULA).",
    )
    ap.add_argument(
        "--allow-insecure",
        action="store_true",
        dest="allow_insecure",
        help="Keep entries that turn certificate checks off (insecure=1).",
    )
    ap.add_argument(
        "--https-only",
        action="store_true",
        dest="https_only",
        help="Refuse an http:// URL: anyone on the way could hand over entries of their own.",
    )
    ap.add_argument("--check-sing-box", default=None, dest="check_sing_box", metavar="SING_BOX",
                    help="Drop the sing-box entries this sing-box binary's config check refuses.")
    ap.add_argument("--check-xray", default=None, dest="check_xray", metavar="XRAY",
                    help="Drop the XRay entries this xray binary's config check refuses.")
    ap.add_argument(
        "--user-agent",
        action="append",
        default=None,
        dest="user_agents",
        metavar="UA",
        help=f"Fetch with this User-Agent (default {DEFAULT_USER_AGENT}). Given more than once: "
        "tried in order until one gets entries, for a panel that serves some clients a stub.",
    )
    ap.add_argument(
        "--device-info",
        action="store_true",
        dest="device_info",
        help="Send the HWID (stdin's second line, hwid=...) and the system, as x-hwid and x-device-*.",
    )
    ap.add_argument(
        "--tweaks",
        default=None,
        help="JSON: fragment and multiplex for every entry (subscriptions.*.fragment, .multiplex).",
    )
    ap.add_argument(
        "--meta-fd",
        type=int,
        default=None,
        dest="meta_fd",
        help="Write what the response's headers say of the subscription (JSON) to this open descriptor.",
    )
    args = ap.parse_args()
    checkers = {
        kind: _Checker(kind, binary)
        for kind, binary in (("sing-box", args.check_sing_box), ("xray", args.check_xray))
        if binary
    }

    def checked(kind: str, outbounds: list[dict]) -> list[dict]:
        return checkers[kind].keep(outbounds) if kind in checkers else outbounds

    # The URL, then lines of key=value: the HWID comes this way, out of argv and the environment.
    url, _, rest = sys.stdin.read().strip().partition("\n")
    url = url.strip()
    if not url:
        print("error: no URL provided on stdin", file=sys.stderr)
        sys.exit(1)
    if args.https_only and not url.lower().startswith("https://"):
        print("error: this subscription must be an https:// URL", file=sys.stderr)
        sys.exit(1)
    try:
        tweaks = checked_tweaks(json.loads(args.tweaks)) if args.tweaks else None
    except ValueError as exc:
        print(f"error: --tweaks: {exc}", file=sys.stderr)
        sys.exit(1)
    extra_headers: dict[str, str] = {}
    if args.device_info:
        given = dict(line.strip().partition("=")[::2] for line in rest.splitlines() if "=" in line)
        hwid = given.get("hwid", "").strip()
        if not subscription_meta.valid_hwid(hwid):
            print("error: --device-info without an HWID on stdin", file=sys.stderr)
            sys.exit(1)
        extra_headers = subscription_meta.device_headers(hwid)

    def parsed(lines: list[str], links: dict[str, str]):
        if args.backend == "hybrid":
            return parse_hybrid_subscription(
                lines,
                args.tag_prefix,
                args.routing_mark,
                links,
                allow_private=args.allow_private,
                allow_insecure=args.allow_insecure,
                tweaks=tweaks,
            )
        return parse_subscription(
            lines,
            args.tag_prefix,
            args.routing_mark,
            args.backend,
            links,
            allow_private=args.allow_private,
            allow_insecure=args.allow_insecure,
            tweaks=tweaks,
        )

    def found(outbounds) -> bool:
        return bool(outbounds["singBox"] or outbounds["xray"]) if args.backend == "hybrid" else bool(outbounds)

    # The deadline is the whole fetch, every User-Agent tried; the alarm only ever runs
    # around the network, so it never lands inside the parser's own error handling.
    user_agents = args.user_agents or [DEFAULT_USER_AGENT]
    deadline = time.monotonic() + OVERALL_DEADLINE_SECONDS
    signal.signal(signal.SIGALRM, _out_of_time)
    error = "subscription contained no parseable proxy URIs"
    outbounds = None
    for attempt, user_agent in enumerate(user_agents):
        last = attempt == len(user_agents) - 1
        left = deadline - time.monotonic()
        if left <= 0:
            error = f"failed to fetch subscription: subscription fetch took longer than {OVERALL_DEADLINE_SECONDS}s"
            break
        signal.alarm(max(1, int(left + 0.999)))
        try:
            raw, headers = fetch_subscription(url, user_agent, extra_headers)
        except Exception as exc:
            error = f"failed to fetch subscription: {_describe(exc)}"
            if not last:
                print(f"warning: with User-Agent {user_agent!r}: {error}; trying the next one", file=sys.stderr)
            continue
        finally:
            signal.alarm(0)
        links: dict[str, str] = {}
        # JSON (whole XRay configs, sing-box outbounds) or a list of links.
        if (from_json := json_subscription_entries(raw)) is not None:
            candidate = parse_json_subscription(
                from_json, args.tag_prefix, args.routing_mark, args.backend,
                allow_private=args.allow_private, allow_insecure=args.allow_insecure, tweaks=tweaks,
            )
        else:
            candidate = parsed(decode_subscription(raw), links)
        if found(candidate):
            outbounds = candidate
            break
        error = "subscription contained no parseable proxy URIs"
        if not last:
            print(f"warning: with User-Agent {user_agent!r} the subscription has no usable entries; trying the next one",
                  file=sys.stderr)

    if outbounds is None:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)

    if args.backend == "hybrid":
        outbounds = {"singBox": checked("sing-box", outbounds["singBox"]), "xray": checked("xray", outbounds["xray"])}
    else:
        outbounds = checked(args.backend, outbounds)
    if not found(outbounds):
        print("error: subscription contained no parseable proxy URIs", file=sys.stderr)
        sys.exit(1)

    kept = {ob.get("tag") for ob in (outbounds["singBox"] + outbounds["xray"] if args.backend == "hybrid" else outbounds)}
    links = {tag: line for tag, line in links.items() if tag in kept}
    links_target = args.links_out or args.links_fd
    if links_target is not None:
        with open(links_target, "w", encoding="utf-8") as handle:
            json.dump(links, handle)
    if args.meta_fd is not None:
        meta = subscription_meta.from_headers(headers)
        meta.update(fetchedAt=int(time.time()), userAgent=user_agent, deviceInfo=args.device_info)
        if args.device_info:
            meta["hwid"] = extra_headers["x-hwid"]
        with open(args.meta_fd, "w", encoding="utf-8") as handle:
            json.dump(meta, handle)
    print(json.dumps(outbounds))


if __name__ == "__main__":
    main()
