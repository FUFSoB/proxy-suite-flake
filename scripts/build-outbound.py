#!/usr/bin/env python3
"""
Read a proxy URL from stdin, emit a sing-box outbound JSON object to stdout.

Usage:
    echo "vless://..." | build-outbound.py --tag my-server [--routing-mark 2]

Supported schemes: vless, vmess, trojan, ss, hysteria2, hy2, tuic,
    socks5, socks5h, socks4, socks4a, http, https
"""

import argparse
import json
import sys
from proxy_url_parsers import PARSERS


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Convert a proxy URL from stdin into a sing-box outbound JSON object."
    )
    ap.add_argument("--tag", required=True)
    ap.add_argument("--routing-mark", type=int, default=None, dest="routing_mark")
    args = ap.parse_args()

    url = sys.stdin.read().strip()
    scheme = url.split("://")[0].lower()

    if scheme not in PARSERS:
        print(f"error: unsupported scheme '{scheme}'", file=sys.stderr)
        sys.exit(1)

    try:
        ob = PARSERS[scheme](url, args.tag)
    except Exception as e:
        print(f"error: failed to parse {scheme} URL: {e}", file=sys.stderr)
        sys.exit(1)

    if args.routing_mark is not None:
        ob["routing_mark"] = args.routing_mark

    print(json.dumps(ob))


if __name__ == "__main__":
    main()
