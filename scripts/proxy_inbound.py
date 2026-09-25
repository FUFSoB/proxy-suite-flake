#!/usr/bin/env python3
"""Render server-side proxy inbounds and their client share links.

The input spec is backend-neutral: it mirrors the
services.proxy-suite.inbounds option tree, with secrets given as file
paths that are read here rather than at Nix evaluation time. Only XRay is
rendered today; a render_sing_box_inbound would sit beside render_xray_inbound
without changing the spec or the link generator.
"""

import base64
import hashlib
import json
import urllib.parse

from awg_inbound import client_entries
from proxy_parsing import build_outbound

UUID_TYPES = ("vless", "vmess")
PASSWORD_TYPES = ("trojan", "hysteria2", "shadowsocks", "socks", "http")

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


def _b64(value: str) -> str:
    """base64 without padding, as share links carry it."""
    return base64.urlsafe_b64encode(value.encode("utf-8")).decode("ascii").rstrip("=")


def _share_port(listener: dict) -> int:
    """Port clients dial, which differs from the bound port when something in
    front of the listener (an nginx vhost, a port mapping) owns the public one."""
    return listener.get("sharePort") or listener["port"]


def _clients(listener: dict, tag: str) -> list[dict]:
    clients = []
    for index, user in enumerate(listener["users"]):
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
        clients.append(client)
    return clients


def _accounts(listener: dict, tag: str) -> list[dict]:
    accounts = []
    for index, user in enumerate(listener["users"]):
        secret = _user_secret(user, listener["type"], tag)
        accounts.append({"user": user.get("name") or f"{tag}-{index}", "pass": secret})
    return accounts


def _xray_stream(listener: dict, tag: str) -> dict:
    if listener["type"] == "hysteria2":
        # QUIC: the transport is hysteria's own, always under TLS.
        settings = {"version": 2}
        masquerade = (listener.get("hysteria") or {}).get("masquerade")
        if masquerade:
            settings["masquerade"] = {"type": "proxy", "url": masquerade, "rewriteHost": True}
        return {
            "network": "hysteria",
            "hysteriaSettings": settings,
            "security": "tls",
            "tlsSettings": _tls_settings(listener["tls"], ["h3"]),
        }

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
    # Behind another listener's fallback, the client address arrives in PROXY protocol.
    if listener.get("front"):
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

    if listener_type in UUID_TYPES:
        settings: dict = {"clients": _clients(listener, tag)}
        if listener_type == "vless":
            settings["decryption"] = "none"
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
        else:
            # Multi-user is 2022-blake3-aes only: the server key, then one key per user.
            settings["password"] = _server_secret(listener, tag)
            settings["clients"] = _clients(listener, tag)
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


def _link_security_params(listener: dict, server_address: str) -> dict:
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
            "fp": "chrome",
        }
        if short_ids and short_ids[0]:
            params["sid"] = short_ids[0]
        return params
    if tls["enable"] or listener["type"] == "trojan":
        params = {
            "security": "tls",
            "sni": tls.get("serverName") or server_address,
            "fp": "chrome",
        }
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


def build_share_link(
    listener: dict, server_address: str, user_index: int = 0, onion_address: str = ""
) -> str:
    """Build the client-facing share URL for a listener.

    With an onion address the link dials that instead, through the client's Tor; the TLS
    and REALITY names stay those of server_address, which the listener still answers to.
    """
    tag = listener["tag"]
    listener_type = listener["type"]
    users = listener["users"]
    if not users:
        raise ValueError(f"listener '{tag}': no users to build a share link for")
    if user_index < 0 or user_index >= len(users):
        raise ValueError(f"listener '{tag}': user index {user_index} is out of range")

    user = users[user_index]
    secret = _user_secret(user, listener_type, tag)
    user_name = user.get("name") or f"{tag}-{user_index}"
    label = f"{tag} ({user_name}, onion)" if onion_address else f"{tag} ({user_name})"
    fragment = urllib.parse.quote(label, safe="")
    endpoint_address = onion_address or server_address
    host = f"[{endpoint_address}]" if ":" in endpoint_address else endpoint_address
    # Behind another listener's fallback, clients dial that one, under its TLS or REALITY.
    front = listener.get("front") or listener
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
        query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
        return f"hysteria2://{urllib.parse.quote(secret, safe='')}@{endpoint}?{query}#{fragment}"

    params = _link_transport_params(listener)
    params.update(_link_security_params(front, server_address))
    if listener_type == "vless" and listener.get("flow"):
        params["flow"] = listener["flow"]
    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return f"{listener_type}://{secret}@{endpoint}?{query}#{fragment}"


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
    return {
        "tag": tag,
        "type": listener["type"],
        "port": _share_port(listener.get("front") or listener),
        "inbound": inbound,
        "links": links,
        "onionLinks": onion_links,
    }


def client_outbound(link: str, tag: str) -> dict | None:
    """What a client dials for this link: sing-box JSON, or XRay's where sing-box has
    no such transport (XHTTP, ECH). None when neither parser reads the link (socks://)."""
    for backend in ("sing-box", "xray"):
        try:
            return build_outbound(link, tag, backend=backend)
        except ValueError:
            pass
    return None


def subscription_token(name: str, secrets: list[str]) -> str:
    """Name of a user's subscription file, and so the secret part of its URL.

    Derived from the user's own credentials rather than stored: there is no
    second secret to manage, it stays put for as long as they do, and rotating
    the user's uuid rotates the URL with it.
    """
    material = "\n".join(["proxy-suite-subscription", name, *sorted(set(secrets))])
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:32]


def build_inbounds(spec: dict, server_address: str, onion_address: str = "") -> dict:
    """Render a whole spec into {"inbounds": [...], "links": [...],
    "subscriptions": [...]}.

    A subscription gathers one user's links from every listener -- users are
    matched by name -- as base64 of the newline-joined links, which is what
    v2rayNG, Hiddify and NekoBox import. Listeners in spec["onionListeners"] get a
    second link per user to onion_address, with "variant": "onion", in both.
    """
    inbounds = []
    links = []
    by_user: dict[str, dict] = {}
    for listener in spec["listeners"]:
        onion = onion_address if listener["tag"] in spec.get("onionListeners", []) else ""
        rendered = build_listener(listener, server_address, spec.get("shareLinks", True), onion)
        inbounds.append(rendered["inbound"])
        variants = [(rendered["links"], {})]
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
    subscriptions = [
        {
            "user": name,
            "token": subscription_token(name, entry["secrets"]),
            "body": base64.b64encode("\n".join(entry["links"]).encode("utf-8")).decode("ascii"),
        }
        for name, entry in by_user.items()
    ]
    return {"inbounds": inbounds, "links": links, "subscriptions": subscriptions}
