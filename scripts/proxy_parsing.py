#!/usr/bin/env python3

import base64
import re
import sys
import urllib.parse
import urllib.request

from proxy_url_parsers import PARSERS


def detect_scheme(url: str) -> str:
    return url.split("://", 1)[0].lower()


def _parse_url(url: str, tag: str, backend: str) -> dict:
    scheme = detect_scheme(url)
    if scheme not in PARSERS:
        raise ValueError(f"unsupported scheme '{scheme}'")

    parser = PARSERS[scheme]
    try:
        return parser(url, tag, backend)
    except TypeError:
        return parser(url, tag)


def _xray_sockopt(routing_mark: int | None) -> dict:
    if routing_mark is None:
        return {}
    return {"streamSettings": {"sockopt": {"mark": routing_mark}}}


def _xray_tls(tls: dict | None) -> tuple[str, dict]:
    if not tls or not tls.get("enabled"):
        return "none", {}

    if tls.get("reality", {}).get("enabled"):
        reality = tls["reality"]
        settings = {
            "serverName": tls.get("server_name", ""),
            "publicKey": reality["public_key"],
            "shortId": reality.get("short_id", ""),
        }
        utls = tls.get("utls", {})
        if reality.get("spider_x"):
            settings["spiderX"] = reality["spider_x"]
        if utls.get("enabled") and utls.get("fingerprint"):
            settings["fingerprint"] = utls["fingerprint"]
        return "reality", {"realitySettings": settings}

    settings = {"serverName": tls.get("server_name", "")}
    if tls.get("alpn"):
        settings["alpn"] = tls["alpn"]
    if tls.get("insecure"):
        raise ValueError(
            "XRay no longer supports tlsSettings.allowInsecure; "
            "remove insecure=1 or use a supported certificate verification option"
        )
    if tls.get("ech_config_list"):
        settings["echConfigList"] = tls["ech_config_list"]
    utls = tls.get("utls", {})
    if utls.get("enabled") and utls.get("fingerprint"):
        settings["fingerprint"] = utls["fingerprint"]
    return "tls", {"tlsSettings": settings}


def _xray_transport(transport: dict | None) -> tuple[str, dict]:
    if not transport:
        return "raw", {}

    t = transport["type"]
    if t == "ws":
        return "ws", {"wsSettings": {"path": transport.get("path", "/"), "headers": transport.get("headers", {})}}
    if t == "grpc":
        return "grpc", {"grpcSettings": {"serviceName": transport.get("service_name", "")}}
    if t == "http":
        return "http", {"httpSettings": {"host": transport.get("host", []), "path": transport.get("path", "/")}}
    if t == "httpupgrade":
        return "httpupgrade", {
            "httpupgradeSettings": {
                "host": transport.get("host", ""),
                "path": transport.get("path", "/"),
            }
        }
    if t == "quic":
        return "quic", {}
    if t == "xhttp":
        settings = {"path": transport.get("path", "/")}
        if transport.get("host"):
            settings["host"] = transport["host"]
        if transport.get("mode"):
            settings["mode"] = transport["mode"]
        if transport.get("extra") is not None:
            settings["extra"] = transport["extra"]
        return "xhttp", {"xhttpSettings": settings}
    return t, {}


def render_xray_outbound(ob: dict, routing_mark: int | None = None) -> dict:
    typ = ob["type"]
    tag = ob["tag"]

    def stream_settings() -> dict:
        security, sec = _xray_tls(ob.get("tls"))
        network, net = _xray_transport(ob.get("transport"))
        stream = {"network": network, "security": security}
        stream.update(sec)
        stream.update(net)
        stream.setdefault("sockopt", {})["domainStrategy"] = "UseIP"
        if routing_mark is not None:
            stream.setdefault("sockopt", {})["mark"] = routing_mark
        return stream

    if typ == "vless":
        settings = {
            "address": ob["server"],
            "port": ob["server_port"],
            "id": ob["uuid"],
            "encryption": "none",
        }
        if ob.get("flow"):
            settings["flow"] = ob["flow"]
        return {"protocol": "vless", "tag": tag, "settings": settings, "streamSettings": stream_settings()}

    if typ == "vmess":
        settings = {
            "address": ob["server"],
            "port": ob["server_port"],
            "id": ob["uuid"],
            "security": ob.get("security", "auto"),
            "alterId": ob.get("alter_id", 0),
        }
        return {"protocol": "vmess", "tag": tag, "settings": settings, "streamSettings": stream_settings()}

    if typ == "trojan":
        settings = {
            "address": ob["server"],
            "port": ob["server_port"],
            "password": ob["password"],
        }
        return {"protocol": "trojan", "tag": tag, "settings": settings, "streamSettings": stream_settings()}

    if typ == "shadowsocks":
        settings = {
            "address": ob["server"],
            "port": ob["server_port"],
            "method": ob["method"],
            "password": ob["password"],
        }
        return {"protocol": "shadowsocks", "tag": tag, "settings": settings, **_xray_sockopt(routing_mark)}

    if typ == "hysteria2":
        stream = stream_settings()
        stream["network"] = "hysteria"
        stream["security"] = "tls"
        stream["hysteriaSettings"] = {"version": 2}
        settings = {
            "version": 2,
            "address": ob["server"],
            "port": ob["server_port"],
        }
        if ob.get("password"):
            stream["hysteriaSettings"]["auth"] = ob["password"]
        if ob.get("obfs", {}).get("type") == "salamander":
            stream.setdefault("finalmask", {}).setdefault("udp", []).append(
                {
                    "type": "salamander",
                    "settings": {"password": ob["obfs"].get("password", "")},
                }
            )
        return {"protocol": "hysteria", "tag": tag, "settings": settings, "streamSettings": stream}

    if typ == "socks":
        settings = {"address": ob["server"], "port": ob["server_port"]}
        if ob.get("username"):
            settings["user"] = ob["username"]
            settings["pass"] = ob.get("password", "")
        return {"protocol": "socks", "tag": tag, "settings": settings, **_xray_sockopt(routing_mark)}

    if typ == "http":
        settings = {"address": ob["server"], "port": ob["server_port"]}
        if ob.get("username"):
            settings["user"] = ob["username"]
            settings["pass"] = ob.get("password", "")
        outbound = {"protocol": "http", "tag": tag, "settings": settings}
        if ob.get("tls"):
            security, sec = _xray_tls(ob.get("tls"))
            outbound["streamSettings"] = {"security": security, **sec}
            if routing_mark is not None:
                outbound["streamSettings"].setdefault("sockopt", {})["mark"] = routing_mark
        elif routing_mark is not None:
            outbound.update(_xray_sockopt(routing_mark))
        return outbound

    raise ValueError(f"unsupported XRay outbound type '{typ}'")


def build_outbound(
    url: str, tag: str, routing_mark: int | None = None, backend: str = "sing-box"
) -> dict:
    if backend not in {"sing-box", "xray"}:
        raise ValueError(f"unsupported backend '{backend}'")

    outbound = _parse_url(url, tag, backend)
    if routing_mark is not None:
        if backend == "xray":
            return render_xray_outbound(outbound, routing_mark)
        outbound["routing_mark"] = routing_mark
    elif backend == "xray":
        return render_xray_outbound(outbound)
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


def parse_subscription(
    lines: list[str], tag_prefix: str, routing_mark: int | None, backend: str = "sing-box"
) -> list[dict]:
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
            outbound = build_outbound(line, tag, routing_mark, backend)
        except Exception as exc:
            print(f"warning: skipping entry {index} ({scheme}): {exc}", file=sys.stderr)
            continue

        seen_tags.add(tag)
        outbounds.append(outbound)

    return outbounds


def parse_hybrid_subscription(
    lines: list[str], tag_prefix: str, routing_mark: int | None = None
) -> dict[str, list[dict]]:
    outbounds: dict[str, list[dict]] = {"singBox": [], "xray": []}
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
            outbound = build_outbound(line, tag, routing_mark, "sing-box")
            outbounds["singBox"].append(outbound)
            seen_tags.add(tag)
            continue
        except Exception as sing_box_exc:
            sing_box_error = sing_box_exc

        try:
            outbound = build_outbound(line, tag, routing_mark, "xray")
        except Exception as xray_exc:
            print(
                f"warning: skipping entry {index} ({scheme}): "
                f"sing-box: {sing_box_error}; xray: {xray_exc}",
                file=sys.stderr,
            )
            continue

        outbounds["xray"].append(outbound)
        seen_tags.add(tag)

    return outbounds
