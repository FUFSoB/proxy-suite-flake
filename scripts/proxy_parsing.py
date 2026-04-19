#!/usr/bin/env python3

import base64
import re
import sys
import urllib.parse
import urllib.request

from proxy_url_parsers import PARSERS


def detect_scheme(url: str) -> str:
    return url.split("://", 1)[0].lower()


def build_outbound(url: str, tag: str, routing_mark: int | None = None) -> dict:
    scheme = detect_scheme(url)
    if scheme not in PARSERS:
        raise ValueError(f"unsupported scheme '{scheme}'")

    outbound = PARSERS[scheme](url, tag)
    if routing_mark is not None:
        outbound["routing_mark"] = routing_mark
    return outbound


def fetch_raw(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "v2rayN/6.0"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def decode_subscription(data: bytes) -> list[str]:
    text = None
    stripped = data.strip()
    try:
        pad = b"=" * (-len(stripped) % 4)
        decoded = base64.b64decode(stripped + pad).decode("utf-8")
        if any(f"{scheme}://" in decoded for scheme in PARSERS):
            text = decoded
    except Exception:
        pass

    if text is None:
        text = data.decode("utf-8", errors="replace")

    return [line.strip() for line in text.splitlines() if line.strip()]


def slugify_tag(remark: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_-]", "-", remark)
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    return slug[:60] or "proxy"


def make_tag(prefix: str, remark: str, index: int) -> str:
    if remark:
        return f"{prefix}-{slugify_tag(urllib.parse.unquote(remark))}"
    return f"{prefix}-{index}"


def parse_subscription(lines: list[str], tag_prefix: str, routing_mark: int | None) -> list[dict]:
    outbounds = []
    seen_tags: set[str] = set()

    for index, line in enumerate(lines):
        scheme = detect_scheme(line)
        if scheme not in PARSERS:
            continue

        remark = line.split("#", 1)[1] if "#" in line else ""
        base_tag = make_tag(tag_prefix, remark, index)
        tag = base_tag

        if tag in seen_tags:
            suffix = 2
            while f"{base_tag}-{suffix}" in seen_tags:
                suffix += 1
            tag = f"{base_tag}-{suffix}"

        try:
            outbound = build_outbound(line, tag, routing_mark)
        except Exception as exc:
            print(f"warning: skipping entry {index} ({scheme}): {exc}", file=sys.stderr)
            continue

        seen_tags.add(tag)
        outbounds.append(outbound)

    return outbounds
