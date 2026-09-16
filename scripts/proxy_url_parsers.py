#!/usr/bin/env python3

import base64
import binascii
import json
import urllib.parse

SUPPORTED_VLESS_TRANSPORTS = {
    "",
    "tcp",
    "raw",
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


# Panels write the unset half of a share link as "&sni=&host=&path=", so a blank
# parameter is an absent one: "sni=" must fall back to the server name, not blank
# out the SNI, and "host=" must not become an empty Host header.
def _param(params: dict, name: str, default: str = "") -> str:
    return params.get(name) or default


# sing-box stores a port as uint16 and refuses to start on anything else, so one
# bad share link would otherwise take the whole config down with it, the same way
# an unknown transport or fingerprint would (see _check_transport below).
def _port(value) -> int:
    try:
        port = int(value)
    except (TypeError, ValueError):
        raise ValueError(f"invalid port '{value}'") from None
    if not 1 <= port <= 65535:
        raise ValueError(f"port {port} is out of range (1-65535)")
    return port


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
    # Split the query off before the userinfo: share links routinely carry '@'
    # inside their parameters (Telegram=@handle, path=/x/?@channel), and an
    # rpartition over the whole string swallows the host along with the userinfo.
    authority, _, query = rest.partition("?")
    userinfo, _, hostpart = authority.rpartition("@")
    # "host:443/?type=tcp" – a trailing path is not part of the port.
    hostpart, _, _ = hostpart.partition("/")
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

    if normalized in ("", "tcp", "raw"):
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


# sing-box refuses to start on a transport it does not know, so one bad share
# link would otherwise take the whole config down with it.
def _check_transport(transport: str, backend: str, protocol: str) -> str:
    normalized = transport.lower()
    supported = (
        SUPPORTED_XRAY_TRANSPORTS if backend == "xray" else SUPPORTED_VLESS_TRANSPORTS
    )
    if normalized not in supported:
        raise ValueError(
            f"unsupported {protocol} transport '{transport}': proxy-suite only maps "
            f"{backend}-documented transports; use raw JSON or another client/core"
        )
    return normalized


def _require(params: dict, name: str, security: str) -> str:
    if name not in params:
        raise ValueError(f"{security} link is missing the '{name}' parameter")
    return params[name]


# sing-box's uTLS build refuses to start on a fingerprint it does not know, so
# one bad share link would otherwise take the whole config down with it. XRay's
# set is larger (it has "unsafe"), so only an explicitly-XRay entry skips this.
SING_BOX_FINGERPRINTS = {
    "chrome",
    "firefox",
    "edge",
    "safari",
    "360",
    "qq",
    "ios",
    "android",
    "random",
    "randomized",
}


# Panels write alpn either as "h2,http/1.1" or as a JSON list; str() on the list
# would hand sing-box "['h2'" as an ALPN value and break the handshake.
def _alpn(value) -> list:
    values = value if isinstance(value, list) else str(value).split(",")
    return [str(a).strip() for a in values if str(a).strip()]


def _mk_tls(
    server_name: str,
    fp: "str | None" = None,
    alpn=None,
    backend: str = "sing-box",
) -> dict:
    tls: dict = {"enabled": True, "server_name": server_name}
    if fp:
        if backend != "xray" and fp not in SING_BOX_FINGERPRINTS:
            raise ValueError(
                f"unsupported uTLS fingerprint '{fp}': sing-box would refuse to start"
            )
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if alpn:
        tls["alpn"] = _alpn(alpn)
    return tls


# SOCKS4 authenticates with a bare userid, so "socks4://me@host:1080" carries a
# username and no password; dropping it made the outbound connect anonymously.
def _mk_auth(userinfo: str) -> "tuple[str | None, str | None]":
    if not userinfo:
        return None, None
    username, separator, password = userinfo.partition(":")
    return urllib.parse.unquote(username), urllib.parse.unquote(password) if separator else None


def parse_vless(url: str, tag: str, backend: str = "sing-box") -> dict:
    userinfo, host, port, params = _parse_url_parts(url, "vless")
    security = _param(params, "security", "none")

    if "ech" in params and backend != "xray":
        raise ValueError(
            "unsupported VLESS parameter 'ech': proxy-suite does not translate "
            "share-link ECH blobs into sing-box TLS config"
        )

    normalized_transport = _check_transport(
        _param(params, "type", "tcp"), backend, "VLESS"
    )

    ob: dict = {
        "type": "vless",
        "tag": tag,
        "server": host,
        "server_port": _port(port),
        "uuid": userinfo,
        "packet_encoding": "xudp",
    }

    if security == "reality":
        ob["tls"] = _mk_tls(
            _param(params, "sni", host),
            fp=_param(params, "fp", "chrome"),
            backend=backend,
        )
        ob["tls"]["reality"] = {
            "enabled": True,
            "public_key": _require(params, "pbk", "reality"),
            "short_id": params.get("sid", ""),
        }
        if backend == "xray" and params.get("spx"):
            ob["tls"]["reality"]["spider_x"] = params["spx"]
    elif security == "tls":
        ob["tls"] = _mk_tls(
            _param(params, "sni", host),
            fp=params.get("fp"),
            alpn=params.get("alpn"),
            backend=backend,
        )
        if backend == "xray" and "ech" in params:
            ob["tls"]["ech_config_list"] = urllib.parse.unquote(params["ech"])

    tr = _mk_transport(
        normalized_transport,
        path=_param(params, "path", "/"),
        host_header=_param(params, "host", host),
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


def parse_vmess(url: str, tag: str, backend: str = "sing-box") -> dict:
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
    port = _port(data["port"])
    net = _check_transport(str(data.get("net", "tcp")), backend, "VMess")
    tls_field = str(data.get("tls", ""))
    sni = str(data.get("sni") or data.get("host") or host)

    ob: dict = {
        "type": "vmess",
        "tag": tag,
        "server": host,
        "server_port": port,
        "uuid": data["id"],
        # Panels write unset fields as "": that is the default, not a value.
        "security": data.get("scy") or "auto",
        "alter_id": int(data.get("aid") or 0),
    }

    if tls_field in ("tls", "reality"):
        ob["tls"] = _mk_tls(
            sni,
            fp=str(data["fp"]) if data.get("fp") else None,
            alpn=data.get("alpn") or None,
            backend=backend,
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


def parse_trojan(url: str, tag: str, backend: str = "sing-box") -> dict:
    userinfo, host, port, params = _parse_url_parts(url, "trojan")
    transport = _check_transport(_param(params, "type", "tcp"), backend, "Trojan")

    ob: dict = {
        "type": "trojan",
        "tag": tag,
        "server": host,
        "server_port": _port(port),
        "password": urllib.parse.unquote(userinfo),
        "tls": _mk_tls(
            _param(params, "sni", host),
            fp=params.get("fp"),
            alpn=params.get("alpn"),
            backend=backend,
        ),
    }

    tr = _mk_transport(
        transport,
        path=_param(params, "path", "/"),
        host_header=_param(params, "host", host),
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
        "server_port": _port(port),
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
        "server_port": _port(port),
        "password": urllib.parse.unquote(userinfo),
        "tls": {
            "enabled": True,
            "server_name": _param(params, "sni", host),
            "insecure": params.get("insecure", "0") == "1",
        },
    }

    if params.get("obfs") == "salamander":
        ob["obfs"] = {"type": "salamander", "password": params.get("obfs-password", "")}

    return ob


def parse_tuic(url: str, tag: str) -> dict:
    userinfo, host, port, params = _parse_url_parts(url, "tuic")
    uuid, _, password = userinfo.partition(":")
    alpn = _alpn(_param(params, "alpn", "h3"))

    return {
        "type": "tuic",
        "tag": tag,
        "server": host,
        "server_port": _port(port),
        "uuid": uuid,
        "password": urllib.parse.unquote(password),
        "congestion_control": _param(params, "congestion_control", "bbr"),
        "udp_relay_mode": _param(params, "udp_relay_mode", "native"),
        "tls": {
            "enabled": True,
            "server_name": _param(params, "sni", host),
            "alpn": alpn,
        },
    }


def parse_anytls(url: str, tag: str) -> dict:
    # anytls://password@host:port?sni=example.com&insecure=1&fp=chrome&alpn=h2
    userinfo, host, port, params = _parse_url_parts(url, "anytls")
    if not userinfo:
        raise ValueError("anytls link is missing the password")
    tls = _mk_tls(params.get("sni") or params.get("peer") or host, params.get("fp"), params.get("alpn"))
    if params.get("insecure", params.get("allowInsecure", "0")) == "1":
        tls["insecure"] = True
    return {
        "type": "anytls",
        "tag": tag,
        "server": host,
        "server_port": _port(port),
        "password": urllib.parse.unquote(userinfo),
        "tls": tls,
    }


def parse_naive(url: str, tag: str) -> dict:
    # naive+https://user:pass@host:port, or naive+quic:// for HTTP/3 (NekoBox's form).
    scheme = url.split("://", 1)[0].lower()
    userinfo, host, port, params = _parse_url_parts(url, scheme)
    ob: dict = {
        "type": "naive",
        "tag": tag,
        "server": host,
        "server_port": _port(port),
        "tls": {"enabled": True, "server_name": params.get("sni") or host},
    }
    username, password = _mk_auth(userinfo)
    if username is not None:
        ob["username"] = username
        if password is not None:
            ob["password"] = password
    if scheme == "naive+quic":
        ob["quic"] = True
    return ob


def parse_socks(url: str, tag: str) -> dict:
    scheme = url.split("://")[0].lower()
    version = "4" if scheme.startswith("socks4") else "5"
    userinfo, host, port, _ = _parse_url_parts(url, scheme)

    ob: dict = {"type": "socks", "tag": tag, "version": version}
    username, password = _mk_auth(userinfo)
    if username is not None:
        ob["username"] = username
        if password is not None:
            ob["password"] = password
    ob["server"] = host
    ob["server_port"] = _port(port)

    return ob


def parse_http_proxy(url: str, tag: str) -> dict:
    scheme = url.split("://")[0].lower()
    userinfo, host, port, _ = _parse_url_parts(url, scheme)

    ob: dict = {"type": "http", "tag": tag}
    username, password = _mk_auth(userinfo)
    if username is not None:
        ob["username"] = username
        if password is not None:
            ob["password"] = password
    ob["server"] = host
    ob["server_port"] = _port(port)

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
    "anytls": parse_anytls,
    "naive+https": parse_naive,
    "naive+quic": parse_naive,
    "socks5": parse_socks,
    "socks5h": parse_socks,
    "socks4": parse_socks,
    "socks4a": parse_socks,
    "http": parse_http_proxy,
    "https": parse_http_proxy,
}

BACKEND_AWARE_PARSERS = {
    "vless",
    "vmess",
    "trojan",
}
