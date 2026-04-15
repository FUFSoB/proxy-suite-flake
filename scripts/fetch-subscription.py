#!/usr/bin/env python3
"""
Read a subscription URL from stdin, fetch it, decode it, and emit a JSON array
of sing-box outbound objects to stdout.

Usage:
    echo "https://example.com/sub" | fetch-subscription.py --tag-prefix my-sub
    echo "https://example.com/sub" | fetch-subscription.py --tag-prefix my-sub --routing-mark 2

The subscription endpoint must return either:
  - A base64-encoded blob that decodes to newline-separated proxy URIs, or
  - Plain newline-separated proxy URIs directly.

Supported URI schemes: vless, vmess, trojan, ss, hysteria2, hy2, tuic,
    socks5, socks5h, socks4, socks4a, http, https
"""

import argparse
import base64
import json
import re
import sys
import urllib.parse
import urllib.request

from proxy_url_parsers import PARSERS


# ---------------------------------------------------------------------------
# Subscription fetching & parsing
# ---------------------------------------------------------------------------

def fetch_raw(url: str) -> bytes:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "v2rayN/6.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def decode_subscription(data: bytes) -> list[str]:
    """
    Return a list of proxy URI strings from a raw subscription response.
    Tries base64 decode first (standard v2rayN format), falls back to UTF-8 plain text.
    """
    # Standard format: response is base64-encoded, decodes to newline-separated URIs.
    text = None
    stripped = data.strip()
    try:
        # Pad to a multiple of 4 before decoding.
        pad = b"=" * (-len(stripped) % 4)
        decoded = base64.b64decode(stripped + pad).decode("utf-8")
        # Sanity-check: decoded content should contain at least one known scheme.
        if any(f"{scheme}://" in decoded for scheme in PARSERS):
            text = decoded
    except Exception:
        pass

    if text is None:
        text = data.decode("utf-8", errors="replace")

    return [line.strip() for line in text.splitlines() if line.strip()]


def slugify(remark: str) -> str:
    """Convert a free-form remark into a tag-safe slug (max 60 chars)."""
    slug = re.sub(r"[^a-zA-Z0-9_-]", "-", remark)
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    return slug[:60] or "proxy"


def make_tag(prefix: str, remark: str, index: int) -> str:
    if remark:
        slug = slugify(urllib.parse.unquote(remark))
        return f"{prefix}-{slug}"
    return f"{prefix}-{index}"


def parse_subscription(lines: list[str], tag_prefix: str, routing_mark: int | None) -> list[dict]:
    outbounds = []
    seen_tags: set[str] = set()

    for i, line in enumerate(lines):
        scheme = line.split("://")[0].lower()
        if scheme not in PARSERS:
            continue

        # Extract remark from the #fragment at the end of the URI.
        remark = ""
        if "#" in line:
            remark = line.split("#", 1)[1]

        base_tag = make_tag(tag_prefix, remark, i)

        # Deduplicate: append -<index> until unique.
        tag = base_tag
        if tag in seen_tags:
            n = 2
            while f"{base_tag}-{n}" in seen_tags:
                n += 1
            tag = f"{base_tag}-{n}"
        seen_tags.add(tag)

        try:
            ob = PARSERS[scheme](line, tag)
        except Exception as exc:
            print(f"warning: skipping entry {i} ({scheme}): {exc}", file=sys.stderr)
            continue

        if routing_mark is not None:
            ob["routing_mark"] = routing_mark

        outbounds.append(ob)

    return outbounds


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
