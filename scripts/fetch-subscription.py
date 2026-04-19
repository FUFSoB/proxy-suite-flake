#!/usr/bin/env python3
"""Read a subscription URL from stdin and emit a JSON array of outbounds."""

import argparse
import json
import sys

from proxy_parsing import decode_subscription, fetch_raw, parse_subscription


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Fetch a proxy subscription URL from stdin and emit a sing-box outbound JSON array."
    )
    ap.add_argument("--tag-prefix", required=True, dest="tag_prefix",
                    help="Prefix for outbound tags, e.g. 'my-sub'.")
    ap.add_argument("--routing-mark", type=int, default=None, dest="routing_mark")
    args = ap.parse_args()

    url = sys.stdin.read().strip()
    if not url:
        print("error: no URL provided on stdin", file=sys.stderr)
        sys.exit(1)

    try:
        raw = fetch_raw(url)
    except Exception as exc:
        print(f"error: failed to fetch subscription: {exc}", file=sys.stderr)
        sys.exit(1)

    lines = decode_subscription(raw)
    outbounds = parse_subscription(lines, args.tag_prefix, args.routing_mark)

    if not outbounds:
        print("error: subscription contained no parseable proxy URIs", file=sys.stderr)
        sys.exit(1)

    print(json.dumps(outbounds))


if __name__ == "__main__":
    main()
