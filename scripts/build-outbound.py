#!/usr/bin/env python3
"""Read a proxy URL from stdin and emit a sing-box outbound JSON object."""

import argparse
import json
import sys

from proxy_parsing import build_outbound


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Convert a proxy URL from stdin into a sing-box outbound JSON object."
    )
    ap.add_argument("--tag", required=True)
    ap.add_argument("--routing-mark", type=int, default=None, dest="routing_mark")
    args = ap.parse_args()

    url = sys.stdin.read().strip()
    try:
        outbound = build_outbound(url, args.tag, args.routing_mark)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        scheme = url.split("://", 1)[0].lower()
        print(f"error: failed to parse {scheme} URL: {exc}", file=sys.stderr)
        sys.exit(1)

    print(json.dumps(outbound))


if __name__ == "__main__":
    main()
