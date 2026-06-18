#!/usr/bin/env python3

import base64
import binascii
import json
import urllib.parse

SUPPORTED_VLESS_TRANSPORTS = {
    "",
    "tcp",
    "ws",
    "grpc",
    "h2",
    "http",
    "httpupgrade",
    "quic",
}

SUPPORTED_XRAY_TRANSPORTS = SUPPORTED_VLESS_TRANSPORTS | {
    "xhttp",
    "splithttp",
}


def _qs(query: str) -> dict:
    return dict(urllib.parse.parse_qsl(query, keep_blank_values=True))


def _split_host_port(hostpart: str) -> tuple[str, str]:
    host, separator, port = hostpart.rpartition(":")
    if not separator or not host or not port:
        raise ValueError("URL must include host and port")
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    return host, port


def _parse_url_parts(url: str, scheme: str) -> tuple[str, str, str, dict]:
    rest = url[len(f"{scheme}://") :]
    rest, _, _ = rest.partition("#")
    if "@" in rest:
        userinfo, _, rest = rest.rpartition("@")
    else:
        userinfo = ""
    hostpart, _, query = rest.partition("?")
    host, port = _split_host_port(hostpart)
    return userinfo, host, port, _qs(query)


def _parse_json_param(value: str, name: str) -> dict:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid {name} JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ValueError(f"invalid {name} JSON: expected object")
    return parsed


def _mk_transport(
    transport_type: str,
    path: str = "/",
    host_header: str = "",
    service_name: str = "",
    mode: str = "",
    extra: str = "",
    x_padding_bytes: str = "",
) -> "dict | None":
    normalized = transport_type.lower()

    if normalized in ("", "tcp"):
        return None
    if normalized == "ws":
        return {
            "type": "ws",
            "path": urllib.parse.unquote(path),
            "headers": {"Host": host_header},
        }
    if normalized == "grpc":
        return {
            "type": "grpc",
            "service_name": urllib.parse.unquote(service_name),
        }
    if normalized in ("h2", "http"):
        return {
            "type": "http",
            "host": [host_header],
            "path": urllib.parse.unquote(path),
        }
    if normalized == "httpupgrade":
        return {
            "type": "httpupgrade",
            "host": host_header,
            "path": urllib.parse.unquote(path),
        }
    if normalized == "quic":
        return {
            "type": "quic",
        }
    if normalized in ("xhttp", "splithttp"):
        transport = {
            "type": "xhttp",
            "path": urllib.parse.unquote(path),
        }
        if host_header:
            transport["host"] = host_header
        if mode:
            transport["mode"] = mode
        if extra:
            transport["extra"] = _parse_json_param(extra, "xhttp extra")
        elif x_padding_bytes:
            transport["extra"] = {"xPaddingBytes": x_padding_bytes}
        return transport
    return None


def _mk_tls(
    server_name: str, fp: "str | None" = None, alpn: "str | None" = None
) -> dict:
    tls: dict = {"enabled": True, "server_name": server_name}
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if alpn:
        tls["alpn"] = alpn.split(",")
    return tls


def _mk_auth(userinfo: str) -> "tuple[str | None, str | None]":
    if userinfo and ":" in userinfo:
        username, _, password = userinfo.partition(":")
        return urllib.parse.unquote(username), urllib.parse.unquote(password)
    return None, None


def parse_vless(url: str, tag: str, backend: str = "sing-box") -> dict:
    userinfo, host, port, params = _parse_url_parts(url, "vless")
    security = params.get("security", "none")
    transport = params.get("type", "tcp")
    normalized_transport = transport.lower()

    if "ech" in params and backend != "xray":
        raise ValueError(
            "unsupported VLESS parameter 'ech': proxy-suite does not translate "
            "share-link ECH blobs into sing-box TLS config"
        )

    supported_transports = (
        SUPPORTED_XRAY_TRANSPORTS if backend == "xray" else SUPPORTED_VLESS_TRANSPORTS
    )
    if normalized_transport not in supported_transports:
        raise ValueError(
            f"unsupported VLESS transport '{transport}': proxy-suite only maps "
            f"{backend}-documented transports; use raw JSON or another client/core"
        )

    ob: dict = {
        "type": "vless",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "uuid": userinfo,
        "packet_encoding": "xudp",
    }

    if security == "reality":
        ob["tls"] = _mk_tls(params.get("sni", host), fp=params.get("fp", "chrome"))
        ob["tls"]["reality"] = {
            "enabled": True,
            "public_key": params["pbk"],
            "short_id": params.get("sid", ""),
        }
        if params.get("spx"):
            ob["tls"]["reality"]["spider_x"] = params["spx"]
    elif security == "tls":
        ob["tls"] = _mk_tls(
            params.get("sni", host), fp=params.get("fp"), alpn=params.get("alpn")
        )
        if backend == "xray" and "ech" in params:
            ob["tls"]["ech_config_list"] = urllib.parse.unquote(params["ech"])

    tr = _mk_transport(
        normalized_transport,
        path=params.get("path", "/"),
        host_header=params.get("host", host),
        service_name=params.get("serviceName", ""),
        mode=params.get("mode", ""),
        extra=params.get("extra", ""),
        x_padding_bytes=params.get("x_padding_bytes", ""),
    )
    if tr is not None:
        ob["transport"] = tr

    flow = urllib.parse.unquote(params.get("flow", ""))
    if flow:
        ob["flow"] = flow

    return ob


def parse_vmess(url: str, tag: str) -> dict:
    b64 = url[len("vmess://") :]
    b64, _, _ = b64.partition("#")
    b64, _, _ = b64.partition("?")
    b64 = urllib.parse.unquote(b64)
    pad = "=" * (-len(b64) % 4)
    try:
        data = json.loads(base64.b64decode(b64 + pad))
    except (binascii.Error, ValueError):
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
        ob["tls"] = _mk_tls(
            sni,
            fp=str(data["fp"]) if data.get("fp") else None,
            alpn=str(data["alpn"]) if data.get("alpn") else None,
        )

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
        "tls": _mk_tls(
            params.get("sni", host), fp=params.get("fp"), alpn=params.get("alpn")
        ),
    }

    tr = _mk_transport(
        transport,
        path=params.get("path", "/"),
        host_header=params.get("host", host),
        service_name=params.get("serviceName", ""),
    )
    if tr is not None:
        ob["transport"] = tr

    return ob


def _decode_ss_userinfo(userinfo: str) -> tuple[str, str]:
    plain = urllib.parse.unquote(userinfo)
    if ":" in plain:
        return tuple(plain.split(":", 1))

    pad = "=" * (-len(userinfo) % 4)
    try:
        decoded = base64.urlsafe_b64decode(userinfo + pad).decode()
        if ":" not in decoded:
            raise ValueError
        return tuple(decoded.split(":", 1))
    except (binascii.Error, UnicodeDecodeError, ValueError) as exc:
        raise ValueError("invalid shadowsocks userinfo") from exc


def parse_shadowsocks(url: str, tag: str) -> dict:
    # Support both SIP002 form:
    #   ss://base64(method:password)@host:port#name
    # and legacy subscriptions that base64-encode the whole endpoint:
    #   ss://base64(method:password@host:port)#name
    rest = url[len("ss://") :]
    rest, _, _ = rest.partition("#")
    endpoint, _, _ = rest.partition("?")

    if "@" in endpoint:
        userinfo, host, port, _ = _parse_url_parts(url, "ss")
    else:
        pad = "=" * (-len(endpoint) % 4)
        try:
            decoded = base64.urlsafe_b64decode(endpoint + pad).decode()
        except (binascii.Error, UnicodeDecodeError) as exc:
            raise ValueError("invalid shadowsocks URL") from exc
        userinfo, separator, hostpart = decoded.rpartition("@")
        if not separator:
            raise ValueError("invalid legacy shadowsocks URL")
        host, port = _split_host_port(hostpart)

    method, password = _decode_ss_userinfo(userinfo)

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
    username, password = _mk_auth(userinfo)
    if username is not None:
        ob["username"] = username
        ob["password"] = password
    ob["server"] = host
    ob["server_port"] = int(port)

    return ob


def parse_http_proxy(url: str, tag: str) -> dict:
    scheme = url.split("://")[0].lower()
    userinfo, host, port, _ = _parse_url_parts(url, scheme)

    ob: dict = {"type": "http", "tag": tag}
    username, password = _mk_auth(userinfo)
    if username is not None:
        ob["username"] = username
        ob["password"] = password
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
