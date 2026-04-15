#!/usr/bin/env python3
"""
Read a proxy URL from stdin, emit a sing-box outbound JSON object to stdout.

Usage:
    echo "vless://..." | build-outbound.py --tag my-server [--routing-mark 2]

Supported schemes: vless, vmess, trojan, ss, hysteria2, hy2, tuic,
    socks5, socks5h, socks4, socks4a, http, https
"""

import argparse
import base64
import json
import sys
import urllib.parse


def _qs(query: str) -> dict:
    return dict(urllib.parse.parse_qsl(query))


def _parse_url_parts(url: str, scheme: str) -> tuple[str, str, str, dict]:
    """Strip scheme+fragment, return (userinfo, host, port_str, params).
    userinfo is "" when no '@' is present."""
    rest = url[len(f"{scheme}://"):]
    rest, _, _ = rest.partition("#")
    if "@" in rest:
        userinfo, _, rest = rest.partition("@")
    else:
        userinfo = ""
    hostpart, _, query = rest.partition("?")
    host, _, port = hostpart.rpartition(":")
    return userinfo, host, port, _qs(query)


def _mk_transport(
    transport_type: str,
    path: str = "/",
    host_header: str = "",
    service_name: str = "",
) -> "dict | None":
    """Build a sing-box transport dict for ws/grpc/h2. Returns None for tcp."""
    if transport_type == "ws":
        return {
            "type": "ws",
            "path": urllib.parse.unquote(path),
            "headers": {"Host": host_header},
        }
    elif transport_type == "grpc":
        return {
            "type": "grpc",
            "service_name": urllib.parse.unquote(service_name),
        }
    elif transport_type == "h2":
        return {
            "type": "http",
            "host": [host_header],
            "path": urllib.parse.unquote(path),
        }
    return None


def parse_vless(url: str, tag: str) -> dict:
    """
    vless://UUID@HOST:PORT?security=reality&pbk=KEY&fp=chrome&sni=SNI&sid=SID&flow=FLOW&type=tcp
    vless://UUID@HOST:PORT?security=tls&sni=SNI&fp=chrome&type=ws&path=/path&host=HOST
    """
    userinfo, host, port, params = _parse_url_parts(url, "vless")
    security = params.get("security", "none")
    transport = params.get("type", "tcp")

    ob: dict = {
        "type": "vless",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "uuid": userinfo,
        "packet_encoding": "xudp",
    }

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

    tr = _mk_transport(
        transport,
        path=params.get("path", "/"),
        host_header=params.get("host", host),
        service_name=params.get("serviceName", ""),
    )
    if tr is not None:
        ob["transport"] = tr

    flow = urllib.parse.unquote(params.get("flow", ""))
    if flow:
        ob["flow"] = flow

    return ob


def parse_vmess(url: str, tag: str) -> dict:
    """
    vmess://BASE64  where BASE64 decodes to a JSON object (V2 link format).
    Fields: v, ps, add, port, id, aid, scy, net, type, host, path, tls, sni, alpn, fp
    """
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

    # vmess grpc uses path as service_name; other transports use path/h_host directly
    tr = _mk_transport(
        net if net != "http" else "h2",
        path=path,
        host_header=h_host,
        service_name=path.lstrip("/"),
    )
    if tr is not None:
        ob["transport"] = tr

    return ob


def parse_trojan(url: str, tag: str) -> dict:
    """
    trojan://PASSWORD@HOST:PORT?sni=SNI&fp=chrome&security=tls&type=tcp|ws|grpc&path=...
    """
    userinfo, host, port, params = _parse_url_parts(url, "trojan")
    transport = params.get("type", "tcp")

    ob: dict = {
        "type": "trojan",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "password": urllib.parse.unquote(userinfo),
        "tls": {
            "enabled": True,
            "server_name": params.get("sni", host),
        },
    }

    if params.get("fp"):
        ob["tls"]["utls"] = {"enabled": True, "fingerprint": params["fp"]}
    if params.get("alpn"):
        ob["tls"]["alpn"] = params["alpn"].split(",")

    tr = _mk_transport(
        transport,
        path=params.get("path", "/"),
        host_header=params.get("host", host),
        service_name=params.get("serviceName", ""),
    )
    if tr is not None:
        ob["transport"] = tr

    return ob


def parse_shadowsocks(url: str, tag: str) -> dict:
    """
    SIP002: ss://BASE64(method:password)@HOST:PORT[?plugin=...]#remark
    plain:  ss://method:password@HOST:PORT#remark
    """
    rest = url[len("ss://"):]
    rest, _, _ = rest.partition("#")

    userinfo, _, rest = rest.partition("@")
    hostpart, _, _ = rest.partition("?")
    host, _, port = hostpart.rpartition(":")

    # Try SIP002 base64 decode first
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
    """
    hysteria2://PASSWORD@HOST:PORT?sni=SNI&insecure=1&obfs=salamander&obfs-password=PASS
    hy2://... (same, shorter alias)
    """
    scheme = "hysteria2" if url.startswith("hysteria2://") else "hy2"
    userinfo, host, port, params = _parse_url_parts(url, scheme)

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
    """
    tuic://UUID:PASSWORD@HOST:PORT?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=SNI
    """
    userinfo, host, port, params = _parse_url_parts(url, "tuic")
    uuid, _, password = userinfo.partition(":")
    alpn = [a for a in params.get("alpn", "h3").split(",") if a]

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
    """
    socks5://[user:pass@]host:port[#remark]
    socks5h://...   (socks5 with remote DNS resolution – same wire format)
    socks4://host:port[#remark]
    socks4a://host:port[#remark]
    """
    scheme = url.split("://")[0].lower()
    version = "4" if scheme.startswith("socks4") else "5"
    userinfo, host, port, _ = _parse_url_parts(url, scheme)

    ob: dict = {"type": "socks", "tag": tag, "version": version}
    if userinfo and ":" in userinfo:
        username, _, password = userinfo.partition(":")
        ob["username"] = urllib.parse.unquote(username)
        ob["password"] = urllib.parse.unquote(password)
    ob["server"] = host
    ob["server_port"] = int(port)

    return ob


def parse_http_proxy(url: str, tag: str) -> dict:
    """
    http://[user:pass@]host:port[#remark]   – plain HTTP CONNECT proxy
    https://[user:pass@]host:port[#remark]  – HTTP CONNECT proxy over TLS
    """
    scheme = url.split("://")[0].lower()
    userinfo, host, port, _ = _parse_url_parts(url, scheme)

    ob: dict = {"type": "http", "tag": tag}
    if userinfo and ":" in userinfo:
        username, _, password = userinfo.partition(":")
        ob["username"] = urllib.parse.unquote(username)
        ob["password"] = urllib.parse.unquote(password)
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
