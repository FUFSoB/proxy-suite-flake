#!/usr/bin/env python3

import base64
import binascii
import ipaddress
import json
import re
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

# XRay 26 removed the HTTP/2 and QUIC transports and refuses to start on them.
SUPPORTED_XRAY_TRANSPORTS = SUPPORTED_VLESS_TRANSPORTS - {"h2", "http", "quic"} | {
    "xhttp",
    "splithttp",
}

# The rest of what a backend refuses to start on, so one bad subscription entry is
# skipped instead of taking every other outbound down with it (see _port below).
VLESS_FLOWS = {
    "sing-box": {"", "xtls-rprx-vision"},
    "xray": {"", "xtls-rprx-vision", "xtls-rprx-vision-udp443"},
}
SING_BOX_VMESS_SECURITY = {"auto", "none", "zero", "aes-128-cfb", "aes-128-gcm", "chacha20-poly1305"}
TUIC_CONGESTION_CONTROLS = {"cubic", "new_reno", "bbr"}
XHTTP_MODES = {"", "auto", "packet-up", "stream-up", "stream-one"}
SS2022_KEY_BYTES = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "2022-blake3-chacha20-poly1305": 32,
}
SING_BOX_SS_METHODS = set(SS2022_KEY_BYTES) | {
    "none",
    "aes-128-gcm",
    "aes-192-gcm",
    "aes-256-gcm",
    "chacha20-ietf-poly1305",
    "xchacha20-ietf-poly1305",
    "aes-128-ctr",
    "aes-192-ctr",
    "aes-256-ctr",
    "aes-128-cfb",
    "aes-192-cfb",
    "aes-256-cfb",
    "rc4-md5",
    "chacha20-ietf",
    "xchacha20",
}
# XRay lowercases these; its 2022 methods are matched as written.
XRAY_SS_METHODS = {
    "aes-128-gcm",
    "aes-256-gcm",
    "chacha20-poly1305",
    "chacha20-ietf-poly1305",
    "xchacha20-poly1305",
    "xchacha20-ietf-poly1305",
    "aead_aes_128_gcm",
    "aead_aes_256_gcm",
    "aead_chacha20_poly1305",
    "aead_xchacha20_poly1305",
}
UUID_RE = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|[0-9a-fA-F]{32}")
# REALITY's x25519 key, unpadded base64url; its short id, whole hex bytes, at most 8.
REALITY_PUBLIC_KEY_RE = re.compile(r"[A-Za-z0-9_-]{43}")
REALITY_SHORT_ID_RE = re.compile(r"(?:[0-9a-fA-F]{2}){0,8}")
# A path Go's url.Parse takes: no control characters, and % only as an escape. XRay ignores
# the parse error on spiderX and dies on the nil URL, taking every outbound with it.
REALITY_SPIDER_X_RE = re.compile(r"/(?:[^\x00-\x1f\x7f%]|%[0-9A-Fa-f]{2})*")
# hysteria2's pinSHA256: the certificate's SHA-256, hex, colons optional.
CERT_SHA256_RE = re.compile(r"[0-9A-Fa-f]{64}|[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31}")


def _one_of(value, allowed: set, what: str):
    if value not in allowed:
        # repr: the value is the link's, escape sequences and all, and goes to a terminal.
        raise ValueError(f"unsupported {what} {str(value)[:80]!r}")
    return value


# sing-box takes any string as a VLESS/VMess id; XRay a UUID, or 1-30 characters it hashes into one.
def _user_id(value, backend: str, protocol: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{protocol} id must be a string")
    if backend == "xray" and not (UUID_RE.fullmatch(value) or 1 <= len(value) <= 30):
        # Not quoted: the id is the credential, and the message reaches the journal.
        raise ValueError(f"invalid {protocol} id ({len(value)} characters): XRay takes a UUID or 1-30 characters")
    return value


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
        raise ValueError(f"invalid port {str(value)[:20]!r}") from None
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


def _all_keys(value) -> set[str]:
    """Every key anywhere in `value`, lowercased."""
    found: set[str] = set()
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            found.update(str(key).lower() for key in item)
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)
    return found


def local_file_keys(value) -> list[str]:
    """The keys anywhere in `value` that point a backend at a local file or program.

    The backends hold CAP_NET_ADMIN, and a share link is whatever a subscription serves:
    xhttp's extra carries a whole streamSettings (downloadSettings), where
    certificateFile is a file XRay reads and masterKeyLog one it writes. The start
    script's localFileKeysJq applies the same rule to runtime JSON outbounds.

    Any non-ASCII key counts too: Go's JSON folds case, reading "maſterKeyLog" as masterKeyLog.
    """
    return sorted(
        k
        for k in _all_keys(value)
        if not k.isascii()
        or k.endswith(("file", "directory"))
        or (k.endswith("path") and k != "path")
        or k in ("masterkeylog", "torrc", "extra_args")
    )


# The same streamSettings could also set the socket's mark or interface, or chain
# through another outbound: a subscription would steer around proxy-suite's own
# routing (the loop-avoiding mark, a loopback hop). These go; other socket options stay.
SOCKET_KEYS = {"customsockopt", "dialerproxy", "interface", "mark", "tproxy"}


def _strip_socket_keys(value) -> None:
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            for key in [k for k in item if str(k).lower() in SOCKET_KEYS]:
                del item[key]
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)


def _refuse_constant(value: str):
    raise ValueError(f"{value} is not JSON")


def _parse_json_param(value: str, name: str) -> dict:
    try:
        # NaN and Infinity: Python takes them, the JSON written for the backends cannot hold them.
        parsed = json.loads(value, parse_constant=_refuse_constant)
    except ValueError as exc:
        raise ValueError(f"invalid {name} JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ValueError(f"invalid {name} JSON: expected object")
    if unsafe := local_file_keys(parsed):
        raise ValueError(f"{name} JSON names local files: {', '.join(unsafe)}")
    _strip_socket_keys(parsed)
    # XRay 26 refuses its whole configuration over a removed setting: this entry goes instead.
    if "allowinsecure" in _all_keys(parsed):
        raise ValueError(f"{name} JSON sets allowInsecure, which XRay no longer accepts")
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
        if _one_of(mode, XHTTP_MODES, "xhttp mode"):
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
# set is larger (it has "unsafe"), so an XRay entry is checked against its own.
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
# XRay's own names (transport/internet/tls), matched lowercased. REALITY refuses
# "unsafe" and "hellogolang" on top.
XRAY_FINGERPRINTS = SING_BOX_FINGERPRINTS | {
    "randomizednoalpn",
    "unsafe",
    *(
        "hello" + name
        for name in (
            "firefox_120 firefox_148 chrome_120 chrome_131 chrome_133 ios_13 ios_14 edge_106 "
            "safari_26_3 360_11_0 qq_11_1 golang randomized randomizedalpn randomizednoalpn "
            "firefox_auto firefox_55 firefox_56 firefox_63 firefox_65 firefox_99 firefox_102 "
            "firefox_105 chrome_auto chrome_58 chrome_62 chrome_70 chrome_72 chrome_83 chrome_87 "
            "chrome_96 chrome_100 chrome_102 chrome_106_shuffle ios_auto ios_11_1 ios_12_1 "
            "android_11_okhttp edge_85 edge_auto safari_16_0 safari_auto 360_auto 360_7_5 "
            "qq_auto chrome_100_psk chrome_112_psk_shuf chrome_114_padding_psk_shuf "
            "chrome_115_pq chrome_115_pq_psk chrome_120_pq"
        ).split()
    ),
}


def _check_fingerprint(fp: str, backend: str, reality: bool = False) -> str:
    if backend != "xray":
        if fp not in SING_BOX_FINGERPRINTS:
            raise ValueError(f"unsupported uTLS fingerprint '{fp}': sing-box would refuse to start")
    elif fp.lower() not in XRAY_FINGERPRINTS or (reality and fp.lower() in ("unsafe", "hellogolang")):
        raise ValueError(f"unsupported uTLS fingerprint '{fp}': XRay would refuse to start")
    return fp


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
        tls["utls"] = {"enabled": True, "fingerprint": _check_fingerprint(fp, backend)}
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


def _set_auth(ob: dict, userinfo: str) -> None:
    """Copies userinfo onto the outbound, password only when it is there."""
    username, password = _mk_auth(userinfo)
    if username is not None:
        ob["username"] = username
        if password is not None:
            ob["password"] = password


# XRay's GetPrivateIPMatcher and GetPrivateDomainMatcher (common/geodata/consts.go): the
# only servers it lets VLESS reach in the clear.
_XRAY_PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(net)
    for net in (
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
        "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3",
        "::/127", "fc00::/7", "fe80::/10", "ff00::/8",
    )
)
_XRAY_PRIVATE_SUFFIXES = (
    "lan", "localdomain", "example", "invalid", "localhost", "test", "local", "home.arpa", "internal",
)


def _xray_wants_transport_security(host: str) -> bool:
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        domain = host.lower().rstrip(".")
        if re.fullmatch(r"[a-z]([a-z0-9-]{0,61}[a-z0-9])?", domain):
            return False
        return not any(domain == s or domain.endswith("." + s) for s in _XRAY_PRIVATE_SUFFIXES)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    return not any(address in net for net in _XRAY_PRIVATE_NETWORKS if net.version == address.version)


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
        "uuid": _user_id(userinfo, backend, "VLESS"),
        "packet_encoding": "xudp",
    }

    if security == "reality":
        fp = _check_fingerprint(_param(params, "fp", "chrome"), backend, reality=True)
        ob["tls"] = _mk_tls(_param(params, "sni", host), fp=fp, backend=backend)
        public_key = _require(params, "pbk", "reality")
        if not REALITY_PUBLIC_KEY_RE.fullmatch(public_key):
            raise ValueError(f"invalid reality pbk '{public_key}': expected a 43-character base64url key")
        short_id = params.get("sid", "")
        if not REALITY_SHORT_ID_RE.fullmatch(short_id):
            raise ValueError(f"invalid reality sid '{short_id}': expected up to 16 hex digits, in pairs")
        ob["tls"]["reality"] = {
            "enabled": True,
            "public_key": public_key,
            "short_id": short_id,
        }
        if backend == "xray" and params.get("spx"):
            if not REALITY_SPIDER_X_RE.fullmatch(params["spx"]):
                raise ValueError(f"invalid reality spx {params['spx']!r}: XRay wants a URL path")
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

    if backend == "xray" and "tls" not in ob and _xray_wants_transport_security(host):
        raise ValueError("XRay refuses VLESS without TLS or REALITY to a public server")

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
    if _one_of(flow, VLESS_FLOWS[backend], f"{backend} VLESS flow"):
        ob["flow"] = flow

    return ob


def _alter_id(value) -> int:
    """VMess alterId as the backends take it: an int a subscription cannot make so large
    (or fractional, or negative) that the backend refuses the whole configuration."""
    try:
        alter_id = int(value or 0)
    except (TypeError, ValueError):
        raise ValueError(f"invalid VMess aid {value!r}") from None
    if not 0 <= alter_id <= 65535:
        raise ValueError("VMess aid must be in 0-65535")
    return alter_id


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

    host = str(data["add"]).strip()
    # "[::1]", as the URL schemes write it: the backends dial it unbracketed.
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    port = _port(data["port"])
    net = _check_transport(str(data.get("net", "tcp")), backend, "VMess")
    tls_field = str(data.get("tls", ""))
    sni = str(data.get("sni") or data.get("host") or host)

    # Panels write unset fields as "": that is the default, not a value. XRay reads
    # one it does not know as "auto"; sing-box refuses to start.
    security = data.get("scy") or "auto"
    if backend != "xray":
        _one_of(security, SING_BOX_VMESS_SECURITY, "sing-box VMess security")
    elif not isinstance(security, str):
        raise ValueError("VMess scy must be a string")

    ob: dict = {
        "type": "vmess",
        "tag": tag,
        "server": host,
        "server_port": port,
        "uuid": _user_id(data["id"], backend, "VMess"),
        "security": security,
        "alter_id": _alter_id(data.get("aid")),
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
        "password": _nonempty_password(urllib.parse.unquote(userinfo), "Trojan"),
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


def _nonempty_password(password: str, protocol: str) -> str:
    # XRay refuses its whole configuration over one empty password; sing-box takes an
    # empty Trojan one, which no server has.
    if not password:
        raise ValueError(f"{protocol} password is empty")
    return password


def _check_ss(method: str, password: str, backend: str) -> None:
    if backend == "xray":
        if method not in SS2022_KEY_BYTES and method.lower() not in XRAY_SS_METHODS:
            raise ValueError(f"unsupported XRay shadowsocks method '{method}'")
    else:
        _one_of(method, SING_BOX_SS_METHODS, "sing-box shadowsocks method")
    if method.lower() != "none":
        _nonempty_password(password, "Shadowsocks")
    if method not in SS2022_KEY_BYTES:
        return
    # A 2022 password is the key itself, padded base64 ("iPSK:uPSK" for EIH, AES only):
    # both backends decode it at start.
    keys = password.split(":")
    if len(keys) > 1 and "aes" not in method:
        raise ValueError(f"{method} takes a single key")
    for key in keys:
        try:
            decoded = base64.b64decode(key, validate=True)
        except binascii.Error:
            decoded = b""
        if len(decoded) != SS2022_KEY_BYTES[method]:
            raise ValueError(f"{method} needs a base64 key of {SS2022_KEY_BYTES[method]} bytes")


def parse_shadowsocks(url: str, tag: str, backend: str = "sing-box") -> dict:
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
    _check_ss(method, password, backend)

    return {
        "type": "shadowsocks",
        "tag": tag,
        "server": host,
        "server_port": _port(port),
        "method": method,
        "password": password,
    }


# "20000-30000" or a lone "443" in sing-box's "a:b" form: it refuses to start on a bare port.
def _port_range(part: str, mport: str) -> str:
    match = re.fullmatch(r"([0-9]+)(?:-([0-9]+))?", part)
    low, high = (int(match[1]), int(match[2] or match[1])) if match else (0, 0)
    if not 1 <= low <= high <= 65535:
        raise ValueError(f"invalid hysteria2 mport {mport[:40]!r}")
    return f"{low}:{high}"


def parse_hysteria2(url: str, tag: str, backend: str = "sing-box") -> dict:
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
    # XRay checks the certificate against the pin instead (sing-box pins only a public key).
    pin = params.get("pinSHA256", "")
    if backend == "xray" and pin:
        if not CERT_SHA256_RE.fullmatch(pin):
            raise ValueError(f"invalid hysteria2 pinSHA256 {pin[:100]!r}")
        ob["tls"]["insecure"] = False
        ob["tls"]["certificate_sha256"] = pin.replace(":", "").lower()

    if params.get("obfs") == "salamander":
        # sing-box refuses to start on salamander without one.
        if not params.get("obfs-password"):
            raise ValueError("hysteria2 salamander obfs is missing its obfs-password")
        ob["obfs"] = {"type": "salamander", "password": params["obfs-password"]}

    # Port hopping, as v2rayN writes it: "20000-30000", or several joined by commas. A fixed
    # interval: hop_interval_max, which would randomise it, is newer than sing-box 1.13.
    if params.get("mport"):
        ob["server_ports"] = [_port_range(r.strip(), params["mport"]) for r in params["mport"].split(",") if r.strip()]
        ob["hop_interval"] = "30s"

    return ob


def parse_tuic(url: str, tag: str) -> dict:
    userinfo, host, port, params = _parse_url_parts(url, "tuic")
    uuid, _, password = userinfo.partition(":")
    alpn = _alpn(_param(params, "alpn", "h3"))
    # Unlike VLESS, sing-box's TUIC takes nothing but a UUID.
    if not UUID_RE.fullmatch(uuid):
        raise ValueError("invalid TUIC uuid: not a UUID")

    return {
        "type": "tuic",
        "tag": tag,
        "server": host,
        "server_port": _port(port),
        "uuid": uuid,
        "password": urllib.parse.unquote(password),
        "congestion_control": _one_of(
            _param(params, "congestion_control", "bbr"), TUIC_CONGESTION_CONTROLS, "TUIC congestion_control"
        ),
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
    _set_auth(ob, userinfo)
    if scheme == "naive+quic":
        ob["quic"] = True
    return ob


def _parse_plain_proxy(url: str, tag: str, kind: str) -> dict:
    """socks:// and http(s)://: host, port and optional credentials, nothing else."""
    scheme = url.split("://")[0].lower()
    userinfo, host, port, _ = _parse_url_parts(url, scheme)

    ob: dict = {"type": kind, "tag": tag}
    if kind == "socks":
        ob["version"] = "4" if scheme.startswith("socks4") else "5"
    _set_auth(ob, userinfo)
    ob["server"] = host
    ob["server_port"] = _port(port)
    if kind == "http" and scheme == "https":
        ob["tls"] = {"enabled": True, "server_name": host}

    return ob


def parse_socks(url: str, tag: str) -> dict:
    return _parse_plain_proxy(url, tag, "socks")


def parse_http_proxy(url: str, tag: str) -> dict:
    return _parse_plain_proxy(url, tag, "http")


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
    "ss",
    "hysteria2",
    "hy2",
}
