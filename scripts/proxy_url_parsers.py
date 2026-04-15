#!/usr/bin/env python3

import base64
import json
import urllib.parse


def _qs(query: str) -> dict:
    return dict(urllib.parse.parse_qsl(query))


def _parse_url_parts(url: str, scheme: str) -> tuple[str, str, str, dict]:
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
    if transport_type == "ws":
        return {
            "type": "ws",
            "path": urllib.parse.unquote(path),
            "headers": {"Host": host_header},
        }
    if transport_type == "grpc":
        return {
            "type": "grpc",
            "service_name": urllib.parse.unquote(service_name),
        }
    if transport_type == "h2":
        return {
            "type": "http",
            "host": [host_header],
            "path": urllib.parse.unquote(path),
        }
    return None


def parse_vless(url: str, tag: str) -> dict:
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
