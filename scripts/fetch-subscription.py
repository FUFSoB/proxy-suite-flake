#!/usr/bin/env python3
"""Read a subscription URL from stdin and emit a JSON array of backend outbounds."""

import argparse
import json
import sys

from proxy_parsing import decode_subscription, fetch_raw, parse_hybrid_subscription, parse_subscription


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
    links: dict[str, str] = {}
    if args.backend == "hybrid":
        outbounds = parse_hybrid_subscription(lines, args.tag_prefix, args.routing_mark, links)
        has_outbounds = bool(outbounds["singBox"] or outbounds["xray"])
    else:
        outbounds = parse_subscription(lines, args.tag_prefix, args.routing_mark, args.backend, links)
        has_outbounds = bool(outbounds)

    if not has_outbounds:
        print("error: subscription contained no parseable proxy URIs", file=sys.stderr)
        sys.exit(1)

    if args.links_out:
        with open(args.links_out, "w", encoding="utf-8") as handle:
            json.dump(links, handle)
    print(json.dumps(outbounds))


if __name__ == "__main__":
    main()
