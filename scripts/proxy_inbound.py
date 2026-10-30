#!/usr/bin/env python3
"""Render server-side proxy inbounds and their client share links.

The input spec is backend-neutral: it mirrors the
services.proxy-suite.inbounds option tree, with secrets given as file
paths that are read here rather than at Nix evaluation time. XRay serves every
listener; the anytls, naive, tuic and shadowtls ones sing-box takes on their port
and hands on to a loopback VLESS inbound of XRay's under the listener's tag, one
client per user, so XRay routes, counts and limits them like the rest.
"""

import base64
import functools
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import urllib.parse
import uuid

import inbound_runtime
from awg_inbound import client_entries
from proxy_parsing import build_outbound

UUID_TYPES = ("vless", "vmess")
PASSWORD_TYPES = ("trojan", "hysteria2", "shadowsocks", "socks", "http", "anytls", "naive", "tuic", "shadowtls")
SING_BOX_TYPES = ("anytls", "naive", "tuic", "shadowtls")
# How long the server keeps a VLESS Encryption session's ticket for a 0-RTT reconnect.
VLESS_ENCRYPTION_TICKET = "600s"

TRANSPORT_SETTINGS_KEY = {
    "ws": "wsSettings",
    "grpc": "grpcSettings",
    "httpupgrade": "httpupgradeSettings",
    "xhttp": "xhttpSettings",
}


def _read_secret(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


def _resolve(literal: str | None, path: str | None, what: str, tag: str) -> str:
    """Take the inline value, or the contents of the file holding it."""
    if literal is not None:
        return literal
    if path is not None:
        value = _read_secret(path)
        if not value:
            raise ValueError(f"listener '{tag}': {what} file '{path}' is empty")
        return value
    raise ValueError(f"listener '{tag}': no {what} configured")


def _user_secret(user: dict, listener_type: str, tag: str) -> str:
    if listener_type in UUID_TYPES:
        return _resolve(user.get("uuid"), user.get("uuidFile"), "uuid", tag)
    return _resolve(user.get("password"), user.get("passwordFile"), "password", tag)


def _server_secret(listener: dict, tag: str) -> str:
    """Server key of a multi-user shadowsocks 2022 listener."""
    return _resolve(
        listener.get("serverPassword"), listener.get("serverPasswordFile"), "server password", tag
    )


def _salamander(listener: dict) -> str | None:
    """The Salamander password of a hysteria2 listener that obfuscates, else None.

    Given inline or as a file; otherwise generated on first start and kept in the
    state file, so share links stay the same across restarts.
    """
    salamander = (listener.get("hysteria") or {}).get("salamander") or {}
    if not salamander.get("enable"):
        return None
    if salamander.get("password") is not None or salamander.get("passwordFile") is not None:
        return _resolve(
            salamander.get("password"), salamander.get("passwordFile"), "salamander password", listener["tag"]
        )
    return _kept_secret(listener["salamanderStateFile"], lambda: secrets.token_urlsafe(24))


def _kept_secret(path: str, generate) -> str:
    """The secret kept in path, or one generated now and kept there for the next start."""
    try:
        stored = _read_secret(path)
    except FileNotFoundError:
        stored = ""
    if stored:
        return stored
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    generated = generate()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(generated + "\n")
    return generated


def _xray_keys(xray: str, *args: str) -> dict[str, str]:
    """What `xray <args>` prints as "Label: value" lines, by label in lower-case letters
    alone ("Password (PublicKey)": "passwordpublickey"). Its errors never quote the command,
    which may hold a private key."""
    try:
        out = subprocess.run([xray, *args], capture_output=True, text=True, check=True, timeout=30).stdout
    except OSError as exc:
        raise ValueError(f"cannot run {xray}: {exc.strerror}") from None
    except subprocess.SubprocessError:
        raise ValueError(f"`xray {args[0]}` failed") from None
    keys = {}
    for line in out.splitlines():
        label, _, value = line.partition(":")
        keys[re.sub(r"[^a-z]", "", label.lower())] = value.strip()
    return keys


def _client_half(keys: dict[str, str], authentication: str) -> str | None:
    if authentication == "mlkem768":
        return keys.get("client")
    return next((v for k, v in keys.items() if "publickey" in k or k == "password"), None)


def _generate_vless_key(xray: str, authentication: str) -> tuple[str, str]:
    """A new VLESS Encryption key: (an X25519 private key or an ML-KEM-768 seed, the clients'
    half), both as XRay prints them."""
    keys = _xray_keys(xray, authentication)
    private = keys.get("seed" if authentication == "mlkem768" else "privatekey")
    client = _client_half(keys, authentication)
    if not private or not client:
        raise ValueError(f"cannot read the key `{xray}` generated for VLESS Encryption")
    return private, client


@functools.lru_cache(maxsize=None)
def _derive_vless_client_key(xray: str, authentication: str, private: str) -> str:
    # `-i` takes the key on its command line, where other local users can see it: only for
    # a key with no client half kept yet (_vless_client_key).
    client = _client_half(_xray_keys(xray, authentication, "-i", private), authentication)
    if not client:
        raise ValueError(f"not a VLESS Encryption {authentication} private key")
    return client


def _vless_client_key(xray: str, authentication: str, private: str, kept: str, known: str | None = None) -> str:
    """The clients' half of a VLESS Encryption key (the X25519 public key, or the ML-KEM-768
    encapsulation key): kept in a file beside the state, under the private key's hash, or
    derived by XRay once (known: the half it printed when it generated the key)."""
    digest = hashlib.sha256(private.encode("utf-8")).hexdigest()
    try:
        with open(kept, encoding="utf-8") as handle:
            lines = handle.read().split()
        if len(lines) == 2 and hmac.compare_digest(lines[0], digest):
            return lines[1]
    except FileNotFoundError:
        pass
    client = known or _derive_vless_client_key(xray, authentication, private)
    try:
        os.makedirs(os.path.dirname(kept), mode=0o700, exist_ok=True)
        fd = os.open(kept, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(f"{digest}\n{client}\n")
    except OSError:
        # Only the cost of deriving it again next time.
        pass
    return client


def _vless_encryption(listener: dict) -> tuple[str, str] | None:
    """(decryption, encryption): the server's and the clients' VLESS Encryption strings of a
    vless listener, or None without it. A key given neither inline nor as a file is
    generated on first start and kept, one per kind, so links stay the same."""
    encryption = listener.get("encryption") or {}
    if not encryption.get("enable"):
        return None
    tag = listener["tag"]
    xray = listener.get("xray") or "xray"
    authentication = encryption.get("authentication") or "x25519"
    mode = encryption.get("mode") or "native"
    state = f"{listener['encryptionStateFile']}.{authentication}"
    generated: dict[str, str] = {}

    def generate() -> str:
        private, generated["client"] = _generate_vless_key(xray, authentication)
        return private

    if encryption.get("privateKey") is not None or encryption.get("privateKeyFile") is not None:
        private = _resolve(encryption.get("privateKey"), encryption.get("privateKeyFile"), "encryption private key", tag)
    else:
        private = _kept_secret(state, generate)
    try:
        public = _vless_client_key(xray, authentication, private, f"{state}.client", generated.get("client"))
    except ValueError as exc:
        raise ValueError(f"listener '{tag}': {exc}") from None
    prefix = f"mlkem768x25519plus.{mode}"
    return f"{prefix}.{VLESS_ENCRYPTION_TICKET}.{private}", f"{prefix}.0rtt.{public}"


def _b64(value: str) -> str:
    """base64 without padding, as share links carry it."""
    return base64.urlsafe_b64encode(value.encode("utf-8")).decode("ascii").rstrip("=")


def _share_port(listener: dict) -> int:
    """Port clients dial, which differs from the bound port when something in
    front of the listener (an nginx vhost, a port mapping) owns the public one."""
    return listener.get("sharePort") or listener["port"]


def _clients(listener: dict, tag: str) -> list[dict]:
    """The users XRay accepts: those the manager has switched off are left out (their links
    stay), and a speed-limited one carries its slot as its level, which the patched XRay
    marks its sockets with (pkgs/patches/xray-user-level-mark.patch)."""
    clients = []
    for index, user in enumerate(listener["users"]):
        if user.get("active") is False:
            continue
        secret = _user_secret(user, listener["type"], tag)
        email = user.get("name") or f"{tag}-{index}"
        if listener["type"] in UUID_TYPES:
            client = {"id": secret, "email": email}
            if listener["type"] == "vless" and listener.get("flow"):
                client["flow"] = listener["flow"]
        elif listener["type"] == "hysteria2":
            client = {"auth": secret, "email": email}
        else:
            client = {"password": secret, "email": email}
        if user.get("level"):
            client["level"] = user["level"]
        clients.append(client)
    return clients


def _accounts(listener: dict, tag: str) -> list[dict]:
    accounts = []
    for index, user in enumerate(listener["users"]):
        if user.get("active") is False:
            continue
        secret = _user_secret(user, listener["type"], tag)
        accounts.append({"user": user.get("name") or f"{tag}-{index}", "pass": secret})
    return accounts


def _xray_stream(listener: dict, tag: str) -> dict:
    if listener["type"] == "hysteria2":
        # QUIC: the transport is hysteria's own, always under TLS.
        settings = {"version": 2}
        hysteria = listener.get("hysteria") or {}
        masquerade = hysteria.get("masquerade")
        if masquerade:
            settings["masquerade"] = {"type": "proxy", "url": masquerade, "rewriteHost": hysteria.get("rewriteHost", True)}
            if hysteria.get("xForwarded"):
                settings["masquerade"]["xForwarded"] = True
        stream = {
            "network": "hysteria",
            "hysteriaSettings": settings,
            "security": "tls",
            "tlsSettings": _tls_settings(listener["tls"], ["h3"]),
        }
        salamander = _salamander(listener)
        if salamander is not None:
            stream["finalmask"] = {"udp": [{"type": "salamander", "settings": {"password": salamander}}]}
        return stream

    transport = listener["transport"]
    network = transport["type"]
    stream: dict = {"network": network}

    settings_key = TRANSPORT_SETTINGS_KEY.get(network)
    if settings_key == "grpcSettings":
        stream[settings_key] = {"serviceName": transport["serviceName"]}
    elif settings_key is not None:
        settings = {"path": transport["path"]}
        if transport.get("host"):
            settings["host"] = transport["host"]
        if network == "xhttp" and transport.get("mode"):
            settings["mode"] = transport["mode"]
        stream[settings_key] = settings

    # Behind a web server the socket address is loopback, which XRay will not record as
    # online; the forwarded address is only trusted when one of these headers is present.
    if transport.get("trustedXForwardedFor"):
        stream.setdefault("sockopt", {})["trustedXForwardedFor"] = transport["trustedXForwardedFor"]
    # Behind another listener's fallback or a TCP front, the client address arrives in
    # PROXY protocol.
    if listener.get("front") or listener.get("acceptProxyProtocol"):
        stream.setdefault("sockopt", {})["acceptProxyProtocol"] = True

    reality = listener["reality"]
    tls = listener["tls"]
    if reality["enable"]:
        stream["security"] = "reality"
        stream["realitySettings"] = {
            "show": False,
            "dest": reality["dest"],
            "serverNames": reality["serverNames"],
            "privateKey": _resolve(
                reality.get("privateKey"),
                reality.get("privateKeyFile"),
                "reality private key",
                tag,
            ),
            "shortIds": reality["shortIds"],
        }
        if reality.get("xver"):
            stream["realitySettings"]["xver"] = reality["xver"]
    elif tls["enable"] or listener["type"] == "trojan":
        stream["security"] = "tls"
        stream["tlsSettings"] = _tls_settings(tls)
    else:
        stream["security"] = "none"

    return stream


def _tls_settings(tls: dict, default_alpn: list[str] | None = None) -> dict:
    settings: dict = {"certificates": [{"certificateFile": tls["certificateFile"], "keyFile": tls["keyFile"]}]}
    if tls.get("serverName"):
        settings["serverName"] = tls["serverName"]
    # ["h3"] alone is what makes an xhttp listener serve HTTP/3, on UDP.
    alpn = tls.get("alpn") or default_alpn
    if alpn:
        settings["alpn"] = alpn
    return settings


def render_xray_inbound(listener: dict) -> dict:
    """Build one XRay inbound object from a typed listener spec."""
    tag = listener["tag"]
    listener_type = listener["type"]

    if listener_type in SING_BOX_TYPES:
        return _internal_inbound(listener)
    if listener_type in UUID_TYPES:
        settings: dict = {"clients": _clients(listener, tag)}
        if listener_type == "vless":
            encryption = _vless_encryption(listener)
            settings["decryption"] = encryption[0] if encryption else "none"
    elif listener_type == "trojan":
        settings = {"clients": _clients(listener, tag)}
    elif listener_type == "hysteria2":
        settings = {"version": 2, "clients": _clients(listener, tag)}
    elif listener_type == "shadowsocks":
        settings = {"method": listener["method"], "network": "tcp,udp"}
        users = listener["users"]
        if len(users) == 1:
            settings["password"] = _user_secret(users[0], listener_type, tag)
            settings["email"] = users[0].get("name") or f"{tag}-0"
            if users[0].get("level"):
                settings["level"] = users[0]["level"]
            keys = [(settings["email"], settings["password"])]
        else:
            # Multi-user is 2022-blake3-aes only: the server key, then one key per user.
            settings["password"] = _server_secret(listener, tag)
            settings["clients"] = _clients(listener, tag)
            keys = [("server", settings["password"])] + [(c["email"], c["password"]) for c in settings["clients"]]
        # Keys from files are only seen here; XRay refuses one of another length with a bare
        # "bad key" and does not start at all.
        method = listener["method"]
        if method in inbound_runtime.SS2022_KEY_BYTES:
            for name, key in keys:
                if not inbound_runtime._ss2022_key_ok(key, method):
                    raise ValueError(
                        f"listener '{tag}': the {name} key is not base64 of "
                        f"{inbound_runtime.SS2022_KEY_BYTES[method]} bytes, as {method} needs"
                    )
    elif listener_type in ("socks", "http"):
        settings = {"auth": "password", "accounts": _accounts(listener, tag)}
        if listener_type == "socks":
            settings["udp"] = True
    else:
        raise ValueError(f"listener '{tag}': unsupported type '{listener_type}'")

    if listener.get("fallbacks"):
        settings["fallbacks"] = [
            {key: value for key, value in fallback.items() if value is not None}
            for fallback in listener["fallbacks"]
        ]

    return {
        "tag": tag,
        "listen": listener["listen"],
        "port": listener["port"],
        # XRay names hysteria2 "hysteria", and takes the version in its settings.
        "protocol": "hysteria" if listener_type == "hysteria2" else listener_type,
        "settings": settings,
        "streamSettings": _xray_stream(listener, tag),
        # routeOnly keeps the sniffed domain for routing decisions without
        # rewriting the destination the client actually asked for.
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"],
            "routeOnly": True,
        },
    }


def _link_transport_params(listener: dict) -> dict:
    transport = listener["transport"]
    network = transport["type"]
    # "raw" is XRay's current name for plain TCP; share links still say "tcp",
    # which is what every client (and our own outbound parser) understands.
    params: dict = {"type": "tcp" if network == "raw" else network}
    if network == "grpc":
        params["serviceName"] = transport["serviceName"]
    elif network in ("ws", "httpupgrade", "xhttp"):
        params["path"] = transport["path"]
        if transport.get("host"):
            params["host"] = transport["host"]
        if network == "xhttp" and transport.get("mode"):
            params["mode"] = transport["mode"]
    return params


def _link_security_params(listener: dict, server_address: str, fingerprint: str | None) -> dict:
    """The link's security: the TLS or REALITY of the listener it dials (`listener`, the
    front of one behind a fallback), with the browser fingerprint the link's own listener
    names, if any."""
    reality = listener["reality"]
    tls = listener["tls"]
    if reality["enable"]:
        if not reality.get("publicKey"):
            raise ValueError(
                f"listener '{listener['tag']}': reality.publicKey is required "
                "to generate a share link"
            )
        server_names = reality["serverNames"]
        short_ids = reality["shortIds"]
        params = {
            "security": "reality",
            "pbk": reality["publicKey"],
            "sni": server_names[0] if server_names else server_address,
        }
        if fingerprint:
            params["fp"] = fingerprint
        if short_ids and short_ids[0]:
            params["sid"] = short_ids[0]
        return params
    if tls["enable"] or listener["type"] == "trojan":
        params = {
            "security": "tls",
            "sni": tls.get("serverName") or server_address,
        }
        if fingerprint:
            params["fp"] = fingerprint
        # A client left to its own ALPN offers h2 and http/1.1, and so never
        # reaches an HTTP/3-only listener at all.
        if tls.get("alpn"):
            params["alpn"] = ",".join(tls["alpn"])
        return params
    return {"security": "none"}


def _vmess_link(
    listener: dict, secret: str, server_address: str, label: str, endpoint_address: str
) -> str:
    transport = listener["transport"]
    reality = listener["reality"]
    tls = listener["tls"]
    blob = {
        "v": "2",
        "ps": label,
        "add": endpoint_address,
        "port": str(_share_port(listener)),
        "id": secret,
        "aid": "0",
        "scy": "auto",
        # Clients know plain TCP as "tcp", and take gRPC's service name from path.
        "net": "tcp" if transport["type"] == "raw" else transport["type"],
        "type": "none",
        "host": transport.get("host") or "",
        "path": transport["serviceName"] if transport["type"] == "grpc" else transport["path"],
        "tls": "tls" if (tls["enable"] or reality["enable"]) else "",
        "sni": tls.get("serverName") or server_address,
    }
    return "vmess://" + _b64(json.dumps(blob, separators=(",", ":")))


def _apply_variant(params: dict, variant: dict, listener_type: str) -> None:
    """Rewrite a link's query for a share variant: only what the client sends changes."""
    if variant.get("fingerprint") is not None and params.get("security") in ("tls", "reality"):
        params["fp"] = variant["fingerprint"]
    if variant.get("alpn") is not None:
        if variant["alpn"]:
            params["alpn"] = ",".join(variant["alpn"])
        else:
            params.pop("alpn", None)
    if variant.get("mode") is not None and params.get("type") == "xhttp":
        params["mode"] = variant["mode"]
    if variant.get("serverName") is not None and "sni" in params:
        params["sni"] = variant["serverName"]
    if listener_type == "hysteria2" and variant.get("portHopping") is False:
        params.pop("mport", None)


def build_share_link(
    listener: dict, server_address: str, user_index: int = 0, onion_address: str = "", variant: dict | None = None
) -> str:
    """Build the client-facing share URL for a listener.

    With an onion address the link dials that instead, through the client's Tor; the TLS
    and REALITY names stay those of server_address, which the listener still answers to.
    A share variant (listener["shareVariants"]) changes what the client sends: fingerprint,
    ALPN, xhttp mode, the address it dials and the SNI, hysteria2's port hopping.
    """
    tag = listener["tag"]
    listener_type = listener["type"]
    users = listener["users"]
    if not users:
        raise ValueError(f"listener '{tag}': no users to build a share link for")
    if user_index < 0 or user_index >= len(users):
        raise ValueError(f"listener '{tag}': user index {user_index} is out of range")

    # Behind another listener's fallback, clients dial that one, under its TLS or REALITY.
    front = listener.get("front") or listener
    # A listener with a name of its own is dialled by it, so the name clients look up is the
    # one they then send as SNI; it is also the default SNI.
    server_address = front.get("shareAddress") or server_address

    user = users[user_index]
    secret = _user_secret(user, listener_type, tag)
    user_name = user.get("name") or f"{tag}-{user_index}"
    variant = variant or {}
    if variant:
        label = f"{tag} {variant['name']} ({user_name})"
    else:
        label = f"{tag} ({user_name}, onion)" if onion_address else f"{tag} ({user_name})"
    fragment = urllib.parse.quote(label, safe="")
    endpoint_address = onion_address or variant.get("address") or server_address
    host = f"[{endpoint_address}]" if ":" in endpoint_address else endpoint_address
    endpoint = f"{host}:{_share_port(front)}"

    if listener_type == "vmess":
        return _vmess_link(listener, secret, server_address, label, endpoint_address)

    if listener_type == "shadowsocks":
        if len(users) > 1:
            # SIP022 multi-user: the client presents the server key and its own.
            secret = f"{_server_secret(listener, tag)}:{secret}"
        method = listener["method"]
        # SIP002: 2022 ciphers take the userinfo percent-encoded, the older ones base64.
        if method.startswith("2022-"):
            userinfo = f"{method}:{urllib.parse.quote(secret, safe='')}"
        else:
            userinfo = _b64(f"{method}:{secret}")
        return f"ss://{userinfo}@{endpoint}#{fragment}"

    if listener_type in ("socks", "http"):
        if listener_type == "socks":
            userinfo = _b64(f"{user_name}:{secret}")
            return f"socks://{userinfo}@{endpoint}#{fragment}"
        credentials = urllib.parse.quote(user_name, safe="") + ":" + urllib.parse.quote(secret, safe="")
        scheme = "https" if listener["tls"]["enable"] else "http"
        return f"{scheme}://{credentials}@{endpoint}#{fragment}"

    if listener_type == "hysteria2":
        tls = listener["tls"]
        params = {"sni": tls.get("serverName") or server_address, "alpn": ",".join(tls.get("alpn") or ["h3"])}
        salamander = _salamander(listener)
        if salamander is not None:
            params.update({"obfs": "salamander", "obfs-password": salamander})
        # v2rayN's name for the hop range; clients that do not know it stay on the port.
        hopping = (listener.get("hysteria") or {}).get("portHopping")
        if hopping:
            params["mport"] = hopping
        _apply_variant(params, variant, listener_type)
        query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
        return f"hysteria2://{urllib.parse.quote(secret, safe='')}@{endpoint}?{query}#{fragment}"

    if listener_type in SING_BOX_TYPES:
        return _sing_box_link(listener, user, user_name, secret, server_address, endpoint_address, endpoint, fragment)

    params = _link_transport_params(listener)
    params.update(_link_security_params(front, server_address, listener.get("shareFingerprint")))
    if listener_type == "vless" and listener.get("flow"):
        params["flow"] = listener["flow"]
    if listener_type == "vless" and (encryption := _vless_encryption(listener)):
        params["encryption"] = encryption[1]
    _apply_variant(params, variant, listener_type)
    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    # A trojan password may hold @, #, ? or %; a vless uuid comes through unchanged.
    return f"{listener_type}://{urllib.parse.quote(secret, safe='')}@{endpoint}?{query}#{fragment}"


# --- sing-box listeners ---------------------------------------------------------------


def _sing_box_users(listener: dict) -> list[tuple[str, dict]]:
    """(name, user) of the users sing-box takes on a listener: those the manager has not
    switched off. XRay drops the others too, but sing-box should not let them in at all."""
    return [
        (user.get("name") or f"{listener['tag']}-{index}", user)
        for index, user in enumerate(listener["users"])
        if user.get("active") is not False
    ]


def _internal_id(listener: dict, name: str, user: dict) -> str:
    """A user's id on the listener's loopback VLESS inbound: from their secrets, so sing-box's
    config and XRay's agree without keeping it anywhere, and it changes when they do."""
    material = ["proxy-suite-sing-box", listener["tag"], name, _user_secret(user, listener["type"], listener["tag"])]
    if listener["type"] == "tuic":
        material.append(_resolve(user.get("uuid"), user.get("uuidFile"), "uuid", listener["tag"]))
    digest = hashlib.sha256("\n".join(material).encode("utf-8")).digest()
    return str(uuid.UUID(bytes=digest[:16], version=4))


def _internal_inbound(listener: dict) -> dict:
    """XRay's side of a sing-box listener: a loopback VLESS inbound under the listener's tag,
    a client per user with their name and level, which the rest of XRay's config (routing,
    stats, speed limits, the API) takes as any listener's."""
    clients = []
    for name, user in _sing_box_users(listener):
        client = {"id": _internal_id(listener, name, user), "email": name}
        if user.get("level"):
            client["level"] = user["level"]
        clients.append(client)
    return {
        "tag": listener["tag"],
        "listen": "127.0.0.1",
        "port": listener["singBox"]["internalPort"],
        "protocol": "vless",
        "settings": {"clients": clients, "decryption": "none"},
        "streamSettings": {"network": "raw", "security": "none"},
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"],
            "routeOnly": True,
        },
    }


def _shadow_tls_key(listener: dict) -> str:
    """The Shadowsocks 2022 server key inside a shadowtls listener: given, or generated on
    first start and kept."""
    tag = listener["tag"]
    method = listener["method"]
    size = inbound_runtime.SS2022_KEY_BYTES[method]
    if listener.get("serverPassword") is not None or listener.get("serverPasswordFile") is not None:
        key = _server_secret(listener, tag)
    else:
        key = _kept_secret(
            listener["serverPasswordStateFile"], lambda: base64.b64encode(secrets.token_bytes(size)).decode("ascii")
        )
    if not inbound_runtime._ss2022_key_ok(key, method):
        raise ValueError(f"listener '{tag}': the server key is not base64 of {size} bytes, as {method} needs")
    return key


def _handshake(listener: dict) -> tuple[str, int]:
    host, _, port = listener["shadowTls"]["handshake"].rpartition(":")
    return host.strip("[]"), int(port)


def _sing_box_tls(tls: dict, default_alpn: list[str] | None = None) -> dict:
    settings: dict = {"enabled": True, "certificate_path": tls["certificateFile"], "key_path": tls["keyFile"]}
    if tls.get("serverName"):
        settings["server_name"] = tls["serverName"]
    alpn = tls.get("alpn") or default_alpn
    if alpn:
        settings["alpn"] = alpn
    return settings


def render_sing_box_listener(listener: dict) -> dict:
    """The sing-box config's part for one listener: its inbounds, an outbound per user to
    XRay's loopback inbound, and the rules between them. Empty with no user let in."""
    tag = listener["tag"]
    kind = listener["type"]
    users = _sing_box_users(listener)
    if not users:
        return {"inbounds": [], "outbounds": [], "rules": []}
    # No acceptProxyProtocol: sing-box dropped PROXY protocol inbounds in 1.6 (refused in Nix).
    inbound: dict = {"type": kind, "tag": tag, "listen": listener["listen"], "listen_port": listener["port"]}
    secret = {name: _user_secret(user, kind, tag) for name, user in users}
    inbounds = [inbound]
    # The inbound the users authenticate on, which the rules match.
    routed = tag
    if kind == "anytls":
        inbound["users"] = [{"name": name, "password": secret[name]} for name, _ in users]
        inbound["tls"] = _sing_box_tls(listener["tls"])
    elif kind == "naive":
        inbound["users"] = [{"username": name, "password": secret[name]} for name, _ in users]
        inbound["network"] = "tcp"
        inbound["tls"] = _sing_box_tls(listener["tls"])
    elif kind == "tuic":
        inbound["users"] = [
            {"name": name, "uuid": _resolve(user.get("uuid"), user.get("uuidFile"), "uuid", tag), "password": secret[name]}
            for name, user in users
        ]
        inbound["congestion_control"] = (listener.get("tuic") or {}).get("congestionControl") or "bbr"
        inbound["tls"] = _sing_box_tls(listener["tls"], ["h3"])
    elif kind == "shadowtls":
        # ShadowTLS v3 vouches for the user and hands the stream to a Shadowsocks 2022
        # inbound on loopback, whose per-user keys say who it is.
        host, port = _handshake(listener)
        routed = f"{tag}/shadowsocks"
        inbound.update(
            {
                "version": 3,
                "users": [{"name": name, "password": secret[name]} for name, _ in users],
                "handshake": {"server": host, "server_port": port},
                "strict_mode": True,
                "detour": routed,
            }
        )
        method = listener["method"]
        inbounds.append(
            {
                "type": "shadowsocks",
                "tag": routed,
                "listen": "127.0.0.1",
                "network": "tcp",
                "method": method,
                "password": _shadow_tls_key(listener),
                "users": [{"name": name, "password": inbound_runtime._ss_key(method, secret[name])} for name, _ in users],
            }
        )
    else:
        raise ValueError(f"listener '{tag}': sing-box does not serve '{kind}'")
    outbounds = []
    rules = []
    for name, user in users:
        hop = f"{tag}/{name}"
        outbounds.append(
            {
                "type": "vless",
                "tag": hop,
                "server": "127.0.0.1",
                "server_port": listener["singBox"]["internalPort"],
                "uuid": _internal_id(listener, name, user),
                "packet_encoding": "xudp",
            }
        )
        rules.append({"inbound": [routed], "auth_user": [name], "outbound": hop})
    return {"inbounds": inbounds, "outbounds": outbounds, "rules": rules}


def sing_box_config(parts: list[dict]) -> dict | None:
    """The whole sing-box config of the listeners it serves, or None without any. Anything
    the rules do not hand to XRay is refused (a rule, not the default outbound, which is
    the first user's)."""
    if not parts:
        return None
    inbounds = [inbound for part in parts for inbound in part["inbounds"]]
    rules = [rule for part in parts for rule in part["rules"]]
    if inbounds:
        rules.append({"inbound": [inbound["tag"] for inbound in inbounds], "action": "reject"})
    return {
        "log": {"level": "warn"},
        "inbounds": inbounds,
        "outbounds": [outbound for part in parts for outbound in part["outbounds"]],
        "route": {"rules": rules},
    }


def _sing_box_link(
    listener: dict, user: dict, user_name: str, secret: str, server_address: str, endpoint_address: str, endpoint: str,
    fragment: str,
) -> str:
    tag = listener["tag"]
    kind = listener["type"]
    tls = listener["tls"]
    sni = tls.get("serverName") or server_address
    if kind == "anytls":
        params = {"sni": sni}
        if listener.get("shareFingerprint"):
            params["fp"] = listener["shareFingerprint"]
        if tls.get("alpn"):
            params["alpn"] = ",".join(tls["alpn"])
        query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
        return f"anytls://{urllib.parse.quote(secret, safe='')}@{endpoint}?{query}#{fragment}"
    if kind == "naive":
        # The user's name is their login: a naive client sends both.
        credentials = urllib.parse.quote(user_name, safe="") + ":" + urllib.parse.quote(secret, safe="")
        query = "" if sni == endpoint_address else "?" + urllib.parse.urlencode({"sni": sni}, quote_via=urllib.parse.quote)
        return f"naive+https://{credentials}@{endpoint}{query}#{fragment}"
    if kind == "tuic":
        params = {
            "sni": sni,
            "alpn": ",".join(tls.get("alpn") or ["h3"]),
            "congestion_control": (listener.get("tuic") or {}).get("congestionControl") or "bbr",
            "udp_relay_mode": "native",
        }
        query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
        user_id = _resolve(user.get("uuid"), user.get("uuidFile"), "uuid", tag)
        return f"tuic://{user_id}:{urllib.parse.quote(secret, safe='')}@{endpoint}?{query}#{fragment}"
    raise ValueError(f"listener '{tag}': {kind} has no share link")


def shadow_tls_client(listener: dict, server_address: str, user_index: int) -> dict:
    """What a sing-box client dials for a shadowtls listener, which has no share link: its
    Shadowsocks 2022 outbound, and in "hops" the ShadowTLS one it goes through (tagged
    "shadowtls", which the subscription renames along with the outbound)."""
    users = listener["users"]
    user = users[user_index]
    secret = _user_secret(user, "shadowtls", listener["tag"])
    address = listener.get("shareAddress") or server_address
    port = _share_port(listener)
    method = listener["method"]
    host, _ = _handshake(listener)
    tls: dict = {"enabled": True, "server_name": listener["shadowTls"].get("serverName") or host}
    if listener.get("shareFingerprint"):
        tls["utls"] = {"enabled": True, "fingerprint": listener["shareFingerprint"]}
    return {
        "outbound": {
            "type": "shadowsocks",
            "tag": listener["tag"],
            "server": address,
            "server_port": port,
            "method": method,
            "password": f"{_shadow_tls_key(listener)}:{inbound_runtime._ss_key(method, secret)}",
            "udp_over_tcp": {"enabled": True, "version": 2},
            "detour": "shadowtls",
        },
        "hops": [
            {
                "type": "shadowtls",
                "tag": "shadowtls",
                "server": address,
                "server_port": port,
                "version": 3,
                "password": secret,
                "tls": tls,
            }
        ],
    }


def render_amneziawg_inbound(listener: dict) -> dict:
    """The XRay side of an AmneziaWG listener: a transparent inbound on loopback that the
    interface's TCP and UDP is diverted to, so it leaves by the same rules as every other."""
    awg = listener["amneziaWg"]
    return {
        "tag": listener["tag"],
        "listen": awg["internalListen"],
        "port": awg["internalPort"],
        "protocol": "tunnel",
        "settings": {"allowedNetwork": "tcp,udp", "followRedirect": True},
        "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
        # routeOnly: the client already resolved, so XRay dials the address it asked for.
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"],
            "routeOnly": True,
        },
    }


def build_listener(
    listener: dict, server_address: str, share_links: bool, onion_address: str = ""
) -> dict:
    """Render one listener into its inbound object and, when possible, a link.

    Raw-JSON listeners are passed through untouched apart from the tag, and get
    no share link: proxy-suite does not know what they serve. An AmneziaWG listener
    has no share links but client configs, each with a vpn:// link, under "configs".
    """
    tag = listener["tag"]

    if listener.get("type") == "amneziawg":
        port = _share_port(listener)
        return {
            "tag": tag,
            "type": "amneziawg",
            "port": port,
            "inbound": render_amneziawg_inbound(listener),
            "links": [],
            "configs": client_entries(listener, server_address, port) if share_links else [],
        }

    raw = listener.get("xrayJson")
    if listener.get("jsonFile") is not None:
        with open(listener["jsonFile"], encoding="utf-8") as handle:
            raw = json.load(handle)
    if raw is not None:
        # The firewall and the port checks go by the listener's port, so the JSON must agree.
        port = raw.get("port", listener["port"])
        if port != listener["port"]:
            raise ValueError(f"listener '{tag}': its JSON listens on port {port}, but port is {listener['port']}")
        return {"tag": tag, "inbound": {**raw, "tag": tag, "port": port}, "links": []}

    inbound = render_xray_inbound(listener)
    if listener["type"] == "shadowtls":
        return {
            "tag": tag,
            "type": "shadowtls",
            "port": _share_port(listener),
            "inbound": inbound,
            "singBox": render_sing_box_listener(listener),
            "links": [],
            "clients": [shadow_tls_client(listener, server_address, index) for index in range(len(listener["users"]))]
            if share_links
            else [],
        }
    links = (
        [build_share_link(listener, server_address, index) for index in range(len(listener["users"]))]
        if share_links
        else []
    )
    onion_links = (
        [
            build_share_link(listener, server_address, index, onion_address)
            for index in range(len(listener["users"]))
        ]
        if share_links and onion_address
        else []
    )
    variant_links = (
        [
            (
                variant["name"],
                [
                    build_share_link(listener, server_address, index, variant=variant)
                    for index in range(len(listener["users"]))
                ],
            )
            for variant in listener.get("shareVariants") or []
        ]
        if share_links
        else []
    )
    rendered = {
        "tag": tag,
        "type": listener["type"],
        "port": _share_port(listener.get("front") or listener),
        "inbound": inbound,
        "links": links,
        "variantLinks": variant_links,
        "onionLinks": onion_links,
    }
    if listener["type"] in SING_BOX_TYPES:
        rendered["singBox"] = render_sing_box_listener(listener)
    return rendered


def client_outbound(link: str, tag: str) -> dict | None:
    """What a client dials for this link: sing-box JSON, or XRay's where sing-box has
    no such transport (XHTTP, ECH). None when neither parser reads the link (socks://)."""
    for backend in ("sing-box", "xray"):
        try:
            return build_outbound(link, tag, backend=backend)
        except ValueError:
            pass
    return None


def subscription_token(name: str, secrets: list[str], key: str | None = None, salt: str = "") -> str:
    """Name of a user's subscription file, and so the secret part of its URL.

    Derived from the user's own credentials rather than stored: it stays put for
    as long as they do, and rotating the user's uuid rotates the URL with it.
    key (inbounds.subscriptions.keyFile, or the one generated) makes it an HMAC under
    a secret only this server holds: whoever learns one of a user's links cannot work
    the URL out from it. salt (the manager's, `proxy-ctl inbounds users rotate-sub`) moves one
    user's URL on without new credentials. Neither: the plain hash of before.
    """
    material = "\n".join(["proxy-suite-subscription", name, *sorted(set(secrets)), *([salt] if salt else [])])
    if key is None:
        return hashlib.sha256(material.encode("utf-8")).hexdigest()[:32]
    return hmac.new(key.encode("utf-8"), material.encode("utf-8"), hashlib.sha256).hexdigest()[:32]


def _subscription_key(spec: dict) -> str | None:
    """The config's key file; else the one generated on first start (subscriptions.keyFile
    null); else none (false)."""
    path = spec.get("subscriptionKeyFile")
    if not path:
        state = spec.get("subscriptionKeyStateFile")
        return _kept_secret(state, lambda: secrets.token_hex(32)) if state else None
    key = _read_secret(path)
    if not key:
        raise ValueError(f"subscription key file '{path}' is empty")
    return key


def build_inbounds(spec: dict, server_address: str, onion_address: str = "") -> dict:
    """Render a whole spec into {"inbounds": [...], "links": [...],
    "subscriptions": [...]}.

    A subscription gathers one user's links from every listener -- users are
    matched by name -- as base64 of the newline-joined links, which is what
    v2rayNG, Hiddify and NekoBox import. A listener's share variants follow its own
    link, each with "variant": its name. Listeners in spec["onionListeners"] get a
    second link per user to onion_address, with "variant": "onion", in both.
    "singBox" is the config of the listeners sing-box serves, or None.
    """
    inbounds = []
    links = []
    sing_box_parts = []
    by_user: dict[str, dict] = {}
    for listener in spec["listeners"]:
        onion = onion_address if listener["tag"] in spec.get("onionListeners", []) else ""
        # The XRay that derives VLESS Encryption's keys.
        listener = {**listener, "xray": spec.get("xray") or "xray"}
        rendered = build_listener(listener, server_address, spec.get("shareLinks", True), onion)
        if "singBox" in rendered:
            sing_box_parts.append(rendered["singBox"])
        # A shadowtls listener's clients have no link, only the outbounds the sing-box and
        # Clash subscriptions carry; its users still own a subscription.
        for index, client in enumerate(rendered.get("clients") or []):
            user = listener["users"][index]
            name = user.get("name") or f"{rendered['tag']}-{index}"
            links.append(
                {
                    "tag": rendered["tag"],
                    "user": name,
                    "type": rendered["type"],
                    "port": rendered["port"],
                    "link": None,
                    "outbound": client["outbound"],
                    "hops": client["hops"],
                }
            )
            entry = by_user.setdefault(name, {"links": [], "secrets": []})
            entry["secrets"].append(_user_secret(user, listener["type"], rendered["tag"]))
        sniffing = rendered["inbound"].get("sniffing")
        raw = listener.get("xrayJson") is not None or listener.get("jsonFile") is not None
        if isinstance(sniffing, dict) and not raw and spec.get("sniffDomainsExcluded"):
            # Names routing sends past the via (rules/proxy-inbounds.nix): matched on the
            # address the client asked for only, never on what its handshake claims.
            sniffing["domainsExcluded"] = list(spec["sniffDomainsExcluded"])
        inbounds.append(rendered["inbound"])
        variants = [(rendered["links"], {})]
        for name, variant_links in rendered.get("variantLinks") or []:
            variants.append((variant_links, {"variant": name}))
        if rendered.get("onionLinks"):
            variants.append((rendered["onionLinks"], {"variant": "onion"}))
        for variant_links, extra in variants:
            for index, link in enumerate(variant_links):
                user = listener["users"][index]
                name = user.get("name") or f"{rendered['tag']}-{index}"
                links.append(
                    {
                        "tag": rendered["tag"],
                        "user": name,
                        "type": rendered.get("type", ""),
                        "port": rendered.get("port", 0),
                        "link": link,
                        "outbound": client_outbound(link, rendered["tag"]),
                        **extra,
                    }
                )
                entry = by_user.setdefault(name, {"links": [], "secrets": []})
                entry["links"].append(link)
                entry["secrets"].append(_user_secret(user, listener["type"], rendered["tag"]))
        # Not in subscriptions: the clients reading those do not speak vpn://.
        for entry in rendered.get("configs", []):
            links.append(
                {
                    "tag": rendered["tag"],
                    "user": entry["user"],
                    "type": rendered["type"],
                    "port": rendered["port"],
                    "link": entry["link"],
                    "config": entry["config"],
                    "outbound": None,
                }
            )
    key = _subscription_key(spec) if by_user else None
    salts = spec.get("subscriptionSalts") or {}
    subscriptions = [
        {
            "user": name,
            "token": subscription_token(name, entry["secrets"], key, salts.get(name, "")),
            "body": base64.b64encode("\n".join(entry["links"]).encode("utf-8")).decode("ascii"),
        }
        for name, entry in by_user.items()
    ]
    return {"inbounds": inbounds, "links": links, "subscriptions": subscriptions, "singBox": sing_box_config(sing_box_parts)}
