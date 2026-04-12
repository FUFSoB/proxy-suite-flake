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


# ---------------------------------------------------------------------------
# Proxy URL parsers (identical to build-outbound.py)
# ---------------------------------------------------------------------------

def _qs(query: str) -> dict:
    return dict(urllib.parse.parse_qsl(query))


def parse_vless(url: str, tag: str) -> dict:
    rest = url[len("vless://"):]
    rest, _, _ = rest.partition("#")

    userinfo, _, rest = rest.partition("@")
    hostpart, _, query = rest.partition("?")
    host, _, port = hostpart.rpartition(":")
    params = _qs(query)

    ob: dict = {
        "type": "vless",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "uuid": userinfo,
        "packet_encoding": "xudp",
    }

    security = params.get("security", "none")
    transport = params.get("type", "tcp")

    if security == "reality":
        ob["tls"] = {
            "enabled": True,
            "server_name": params.get("sni", host),
            "utls": {"enabled": True, "fingerprint": params.get("fp", "chrome")},
            "reality": {
                "enabled": True,
                "public_key": params["pbk"],
                "short_id": params.get("sid", ""),
            },
        }
    elif security == "tls":
        ob["tls"] = {
            "enabled": True,
            "server_name": params.get("sni", host),
        }
        if params.get("fp"):
            ob["tls"]["utls"] = {"enabled": True, "fingerprint": params["fp"]}
        if params.get("alpn"):
            ob["tls"]["alpn"] = params["alpn"].split(",")

    if transport == "ws":
        ob["transport"] = {
            "type": "ws",
            "path": urllib.parse.unquote(params.get("path", "/")),
            "headers": {"Host": params.get("host", host)},
        }
    elif transport == "grpc":
        ob["transport"] = {
            "type": "grpc",
            "service_name": urllib.parse.unquote(params.get("serviceName", "")),
        }
    elif transport == "h2":
        ob["transport"] = {
            "type": "http",
            "host": [params.get("host", host)],
            "path": urllib.parse.unquote(params.get("path", "/")),
        }

    flow = urllib.parse.unquote(params.get("flow", ""))
    if flow:
        ob["flow"] = flow

    return ob


def parse_vmess(url: str, tag: str) -> dict:
    b64 = url[len("vmess://"):]
    pad = "=" * (-len(b64) % 4)
    try:
        data = json.loads(base64.b64decode(b64 + pad))
    except Exception:
        data = json.loads(base64.urlsafe_b64decode(b64 + pad))

    host = str(data["add"])
    port = int(data["port"])
    net = data.get("net", "tcp")
    tls_field = str(data.get("tls", ""))
    sni = str(data.get("sni") or data.get("host") or host)

    ob: dict = {
        "type": "vmess",
        "tag": tag,
        "server": host,
        "server_port": port,
        "uuid": data["id"],
        "security": data.get("scy", "auto"),
        "alter_id": int(data.get("aid", 0)),
    }

    if tls_field in ("tls", "reality"):
        ob["tls"] = {"enabled": True, "server_name": sni}
        if data.get("fp"):
            ob["tls"]["utls"] = {"enabled": True, "fingerprint": str(data["fp"])}
        if data.get("alpn"):
            ob["tls"]["alpn"] = str(data["alpn"]).split(",")

    path = str(data.get("path") or "/")
    h_host = str(data.get("host") or host)

    if net == "ws":
        ob["transport"] = {
            "type": "ws",
            "path": path,
            "headers": {"Host": h_host},
        }
    elif net == "grpc":
        ob["transport"] = {
            "type": "grpc",
            "service_name": path.lstrip("/"),
        }
    elif net in ("h2", "http"):
        ob["transport"] = {
            "type": "http",
            "host": [h_host],
            "path": path,
        }

    return ob


def parse_trojan(url: str, tag: str) -> dict:
    rest = url[len("trojan://"):]
    rest, _, _ = rest.partition("#")

    userinfo, _, rest = rest.partition("@")
    password = urllib.parse.unquote(userinfo)

    hostpart, _, query = rest.partition("?")
    host, _, port = hostpart.rpartition(":")
    params = _qs(query)
    transport = params.get("type", "tcp")

    ob: dict = {
        "type": "trojan",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": params.get("sni", host),
        },
    }

    if params.get("fp"):
        ob["tls"]["utls"] = {"enabled": True, "fingerprint": params["fp"]}
    if params.get("alpn"):
        ob["tls"]["alpn"] = params["alpn"].split(",")

    if transport == "ws":
        ob["transport"] = {
            "type": "ws",
            "path": urllib.parse.unquote(params.get("path", "/")),
            "headers": {"Host": params.get("host", host)},
        }
    elif transport == "grpc":
        ob["transport"] = {
            "type": "grpc",
            "service_name": urllib.parse.unquote(params.get("serviceName", "")),
        }

    return ob


def parse_shadowsocks(url: str, tag: str) -> dict:
    rest = url[len("ss://"):]
    rest, _, _ = rest.partition("#")

    userinfo, _, rest = rest.partition("@")
    hostpart, _, _ = rest.partition("?")
    host, _, port = hostpart.rpartition(":")

    pad = "=" * (-len(userinfo) % 4)
    try:
        decoded = base64.urlsafe_b64decode(userinfo + pad).decode()
        if ":" not in decoded:
            raise ValueError
        method, password = decoded.split(":", 1)
    except Exception:
        plain = urllib.parse.unquote(userinfo)
        method, password = plain.split(":", 1)

    return {
        "type": "shadowsocks",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "method": method,
        "password": password,
    }


def parse_hysteria2(url: str, tag: str) -> dict:
    scheme = "hysteria2" if url.startswith("hysteria2://") else "hy2"
    rest = url[len(scheme) + 3:]
    rest, _, _ = rest.partition("#")

    userinfo, _, rest = rest.partition("@")
    hostpart, _, query = rest.partition("?")
    host, _, port = hostpart.rpartition(":")
    params = _qs(query)

    ob: dict = {
        "type": "hysteria2",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "password": urllib.parse.unquote(userinfo),
        "tls": {
            "enabled": True,
            "server_name": params.get("sni", host),
            "insecure": params.get("insecure", "0") == "1",
        },
    }

    if params.get("obfs") == "salamander":
        ob["obfs"] = {"type": "salamander", "password": params.get("obfs-password", "")}

    return ob


def parse_tuic(url: str, tag: str) -> dict:
    rest = url[len("tuic://"):]
    rest, _, _ = rest.partition("#")

    userinfo, _, rest = rest.partition("@")
    uuid, _, password = userinfo.partition(":")

    hostpart, _, query = rest.partition("?")
    host, _, port = hostpart.rpartition(":")
    params = _qs(query)

    alpn_raw = params.get("alpn", "h3")
    alpn = [a for a in alpn_raw.split(",") if a]

    return {
        "type": "tuic",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "uuid": uuid,
        "password": urllib.parse.unquote(password),
        "congestion_control": params.get("congestion_control", "bbr"),
        "udp_relay_mode": params.get("udp_relay_mode", "native"),
        "tls": {
            "enabled": True,
            "server_name": params.get("sni", host),
            "alpn": alpn,
        },
    }


def parse_socks(url: str, tag: str) -> dict:
    scheme = url.split("://")[0].lower()
    version = "4" if scheme.startswith("socks4") else "5"

    rest = url[len(scheme) + 3:]
    rest, _, _ = rest.partition("#")

    ob: dict = {
        "type": "socks",
        "tag": tag,
        "version": version,
    }

    if "@" in rest:
        userinfo, _, rest = rest.partition("@")
        if ":" in userinfo:
            username, _, password = userinfo.partition(":")
            ob["username"] = urllib.parse.unquote(username)
            ob["password"] = urllib.parse.unquote(password)

    hostpart = rest.split("?")[0]
    host, _, port = hostpart.rpartition(":")
    ob["server"] = host
    ob["server_port"] = int(port)

    return ob


def parse_http_proxy(url: str, tag: str) -> dict:
    scheme = url.split("://")[0].lower()
    rest = url[len(scheme) + 3:]
    rest, _, _ = rest.partition("#")

    ob: dict = {
        "type": "http",
        "tag": tag,
    }

    if "@" in rest:
        userinfo, _, rest = rest.partition("@")
        if ":" in userinfo:
            username, _, password = userinfo.partition(":")
            ob["username"] = urllib.parse.unquote(username)
            ob["password"] = urllib.parse.unquote(password)

    hostpart = rest.split("?")[0]
    host, _, port = hostpart.rpartition(":")
    ob["server"] = host
    ob["server_port"] = int(port)

    if scheme == "https":
        ob["tls"] = {"enabled": True, "server_name": host}

    return ob


PARSERS = {
    "vless": parse_vless,
    "vmess": parse_vmess,
    "trojan": parse_trojan,
    "ss": parse_shadowsocks,
    "hysteria2": parse_hysteria2,
    "hy2": parse_hysteria2,
    "tuic": parse_tuic,
    "socks5": parse_socks,
    "socks5h": parse_socks,
    "socks4": parse_socks,
    "socks4a": parse_socks,
    "http": parse_http_proxy,
    "https": parse_http_proxy,
}


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
