#!/usr/bin/env python3
"""Inbound users and listeners added at runtime (services.proxy-suite.inbounds.runtime).

They live in a spool directory, one JSON file each: users/<name>.json and
listeners/<tag>.json. proxy-ctl writes them through this script's commands, as the user
who runs it; the inbound services merge them into the spec Nix generated when they start
(merge()), as root, so XRay, the AmneziaWG interfaces and the share links all see the same
set.

A runtime user holds its own secrets, generated when it is added, and the listeners it is
bound to: any listener, declared or runtime. A runtime listener has the shape of an
`inbounds.listeners.<tag>` entry, filled in with the option's defaults, plus the users it
accepts, declared or runtime. Whatever such a listener could reach beyond its port is
fenced by the spec: its ports, exits, certificates (by name, never a path) and fallbacks.

Runtime entries never break the declared configuration: one that does not hold up is left
out with a warning when the services start, and refused when proxy-ctl adds it.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import ipaddress
import json
import os
import re
import secrets
import socket
import stat
import subprocess
import sys
import uuid

# User names and listener tags: they become file names, XRay emails and tags, and URL parts.
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,31}")
MAX_ENTRY_BYTES = 65536
# The stats API's inbound, in the same config.
RESERVED_TAGS = ("api-in",)

UUID_TYPES = ("vless", "vmess")
PASSWORD_TYPES = ("trojan", "hysteria2", "shadowsocks", "socks", "http")
TYPES = UUID_TYPES + PASSWORD_TYPES
TRANSPORTS = ("raw", "ws", "grpc", "httpupgrade", "xhttp")
XHTTP_MODES = ("auto", "packet-up", "stream-up", "stream-one")
ALPNS = ("h3", "h2", "http/1.1")
# Shadowsocks 2022 keys, by method: bytes of base64 key.
SS2022_KEY_BYTES = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "2022-blake3-chacha20-poly1305": 32,
}
SS_METHODS = (
    *SS2022_KEY_BYTES,
    "aes-128-gcm",
    "aes-256-gcm",
    "chacha20-poly1305",
    "chacha20-ietf-poly1305",
    "xchacha20-poly1305",
    "xchacha20-ietf-poly1305",
    "none",
)


class RuntimeError_(ValueError):
    """A runtime entry that cannot be used, or a command that cannot be carried out."""


# --- the spool ------------------------------------------------------------------------


def _read_entry(path: str) -> dict:
    """One spool file, as root reads it: a regular file only, never through a symlink,
    which would hand over any file root can read, nor a FIFO, which would hang the start."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as exc:
        raise RuntimeError_(f"cannot read {path}: {exc.strerror}") from None
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise RuntimeError_(f"{path} is not a regular file")
        if info.st_size > MAX_ENTRY_BYTES:
            raise RuntimeError_(f"{path} is larger than {MAX_ENTRY_BYTES} bytes")
        data = handle.read(MAX_ENTRY_BYTES + 1)
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise RuntimeError_(f"{path} is not valid JSON: {exc}") from None
    if not isinstance(value, dict):
        raise RuntimeError_(f"{path} must hold a JSON object")
    return value


def _entries(directory: str, warnings: list[str], what: str) -> dict[str, dict]:
    try:
        names = sorted(os.listdir(directory))
    except FileNotFoundError:
        return {}
    except OSError as exc:
        warnings.append(f"cannot list {directory}: {exc.strerror}")
        return {}
    entries = {}
    for file_name in names:
        if file_name.startswith(".") or not file_name.endswith(".json"):
            continue
        name = file_name[: -len(".json")]
        if not NAME.fullmatch(name):
            warnings.append(f"ignoring runtime {what} '{name}': not a valid name")
            continue
        try:
            entries[name] = _read_entry(os.path.join(directory, file_name))
        except RuntimeError_ as exc:
            warnings.append(f"ignoring runtime {what} '{name}': {exc}")
    return entries


def load_spool(spool: str) -> tuple[dict, list[str]]:
    """{"users": {name: entry}, "listeners": {tag: entry}} and what could not be read."""
    warnings: list[str] = []
    if not spool:  # no inbounds.runtime: nothing but the declared
        return {"users": {}, "listeners": {}}, warnings
    state = {
        "users": _entries(os.path.join(spool, "users"), warnings, "user"),
        "listeners": _entries(os.path.join(spool, "listeners"), warnings, "listener"),
    }
    return state, warnings


def write_entry(spool: str, kind: str, name: str, entry: dict) -> None:
    """Replace one spool file whole. Group-readable: the setgid spool gives it the
    userControl group, whose "inbounds" scope added it."""
    directory = os.path.join(spool, kind)
    old = os.umask(0o027)
    try:
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, f"{name}.json")
        tmp = os.path.join(directory, f".{name}.json.tmp")
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, indent=2, sort_keys=True) + "\n")
        os.replace(tmp, path)
    finally:
        os.umask(old)


def remove_entry(spool: str, kind: str, name: str) -> None:
    os.unlink(os.path.join(spool, kind, f"{name}.json"))


# --- the shape of entries -------------------------------------------------------------


def _is_port(value) -> bool:
    return type(value) is int and 1 <= value <= 65535


def _nonspace(value) -> bool:
    return isinstance(value, str) and value != "" and not re.search(r"\s", value)


def _strings(value) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def _nullable(check):
    return lambda value: value is None or check(value)


def _one_of(*choices):
    return lambda value: value in choices


def _is_bool(value) -> bool:
    return type(value) is bool


def _is_str(value) -> bool:
    return isinstance(value, str)


def _is_alpn(value) -> bool:
    return isinstance(value, list) and all(item in ALPNS for item in value)


# What a runtime listener's JSON may set, and how. The file fields of the option are not
# here: a runtime listener names nothing on disk. Nor raw JSON, AmneziaWG or port hopping,
# which need more than XRay (interfaces, nftables) and are built in Nix.
LISTENER_SCHEMA = {
    "type": _one_of(*TYPES),
    "port": _is_port,
    "sharePort": _nullable(_is_port),
    "shareAddress": _nullable(_nonspace),
    "address": _nonspace,
    "acceptProxyProtocol": _is_bool,
    "via": _nullable(_nonspace),
    "order": lambda value: type(value) is int,
    "users": lambda value: isinstance(value, list) and all(isinstance(n, str) and NAME.fullmatch(n) for n in value),
    "flow": _nullable(_one_of("xtls-rprx-vision")),
    "method": _one_of(*SS_METHODS),
    "serverPassword": _nullable(_nonspace),
    "transport": {
        "type": _one_of(*TRANSPORTS),
        "path": _is_str,
        "host": _nullable(_nonspace),
        "mode": _nullable(_one_of(*XHTTP_MODES)),
        "serviceName": _is_str,
        "trustedXForwardedFor": _strings,
    },
    "tls": {
        "enable": _is_bool,
        "certificate": _nullable(_nonspace),
        "serverName": _nullable(_nonspace),
        "alpn": _nullable(_is_alpn),
    },
    "reality": {
        "enable": _is_bool,
        "dest": _nonspace,
        "serverNames": _strings,
        "privateKey": _nullable(_nonspace),
        "publicKey": _nullable(_nonspace),
        "shortIds": lambda value: _strings(value) and all(re.fullmatch(r"[0-9a-fA-F]{0,16}", i) for i in value),
        "xver": _one_of(0, 1, 2),
    },
    "fallbacks": "fallbacks",
    "hysteria": {
        "masquerade": _nullable(_nonspace),
        "salamander": {
            "enable": _is_bool,
            "password": _nullable(_nonspace),
        },
    },
}

FALLBACK_SCHEMA = {
    "name": _nullable(_nonspace),
    "alpn": _nullable(_one_of("h2", "http/1.1")),
    "path": _nullable(_is_str),
    "dest": _nullable(lambda value: _is_port(value) or _nonspace(value)),
    "listener": _nullable(lambda value: isinstance(value, str) and bool(NAME.fullmatch(value))),
    "xver": _one_of(0, 1, 2),
}

USER_SCHEMA = {
    "order": lambda value: type(value) is int and value >= 1,
    "uuid": lambda value: isinstance(value, str) and _is_uuid(value),
    "password": _nonspace,
    "listeners": lambda value: isinstance(value, list) and all(isinstance(n, str) and NAME.fullmatch(n) for n in value),
}


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
    except ValueError:
        return False
    return True


def _check_shape(value: dict, schema: dict, where: str) -> None:
    for key, item in value.items():
        rule = schema.get(key)
        if rule is None:
            raise RuntimeError_(f"{where}{key}: not something a runtime entry can set")
        if rule == "fallbacks":
            if not isinstance(item, list) or not all(isinstance(fb, dict) for fb in item):
                raise RuntimeError_(f"{where}{key}: must be a list of objects")
            for index, fallback in enumerate(item):
                _check_shape(fallback, FALLBACK_SCHEMA, f"{where}{key}[{index}].")
        elif isinstance(rule, dict):
            if not isinstance(item, dict):
                raise RuntimeError_(f"{where}{key}: must be an object")
            _check_shape(item, rule, f"{where}{key}.")
        elif not rule(item):
            raise RuntimeError_(f"{where}{key}: invalid value {json.dumps(item)}")


def check_user_shape(entry: dict) -> None:
    _check_shape(entry, USER_SCHEMA, "")
    for key in ("order", "uuid", "password"):
        if key not in entry:
            raise RuntimeError_(f"{key} is missing")


def check_listener_shape(entry: dict) -> None:
    _check_shape(entry, LISTENER_SCHEMA, "")
    if "type" not in entry:
        raise RuntimeError_("type is missing")


def _deep_merge(base, override):
    if isinstance(base, dict) and isinstance(override, dict):
        merged = dict(base)
        for key, value in override.items():
            merged[key] = _deep_merge(base.get(key), value)
        return merged
    return copy.deepcopy(override)


# --- ports ----------------------------------------------------------------------------


def _port_ranges(ports: list) -> list[tuple[int, int]]:
    ranges = []
    for item in ports:
        if isinstance(item, int):
            ranges.append((item, item))
        else:
            low, high = (int(part) for part in str(item).split("-", 1))
            ranges.append((low, high))
    return ranges


def _port_allowed(port: int, ports: list) -> bool:
    return any(low <= port <= high for low, high in _port_ranges(ports))


def _udp_only(listener: dict) -> bool:
    tls = listener["tls"]
    return listener["type"] == "hysteria2" or (
        listener["transport"]["type"] == "xhttp" and tls["enable"] and tls.get("alpn") == ["h3"]
    )


def _protocols(listener: dict) -> list[int]:
    if _udp_only(listener):
        return [socket.SOCK_DGRAM]
    if listener["type"] in ("shadowsocks", "socks"):
        return [socket.SOCK_STREAM, socket.SOCK_DGRAM]
    return [socket.SOCK_STREAM]


def port_free(address: str, port: int, kinds: list[int]) -> bool:
    """Whether XRay could bind this: a runtime listener on a port something else holds would
    stop XRay, and every declared listener with it."""
    try:
        infos = socket.getaddrinfo(address, port, 0, 0, 0, socket.AI_PASSIVE)
    except OSError:
        return False
    for kind in kinds:
        for family, _, _, _, sockaddr in infos:
            try:
                with socket.socket(family, kind) as sock:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    if family == socket.AF_INET6:
                        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                    sock.bind(sockaddr)
            except OSError:
                return False
            break
    return True


def _loopback(address: str) -> bool:
    return address.startswith("127.") or address in ("::1", "localhost")


# --- users ----------------------------------------------------------------------------


def _ss_key(method: str, password: str) -> str:
    """A runtime user's key for a Shadowsocks 2022 listener: its password stretched or cut
    to the method's key length, so one stored password serves every cipher."""
    size = SS2022_KEY_BYTES[method]
    digest = hashlib.sha256(("proxy-suite-shadowsocks\n" + password).encode("utf-8")).digest()
    return base64.b64encode(digest[:size]).decode("ascii")


def _runtime_user(name: str, entry: dict) -> dict:
    """A runtime user as the renderers take a declared one."""
    return {
        "name": name,
        "order": entry["order"],
        "uuid": entry["uuid"],
        "uuidFile": None,
        "password": entry["password"],
        "passwordFile": None,
        "publicKey": None,
        "privateKeyFile": None,
        "presharedKeyFile": None,
        "address": None,
        "runtime": True,
    }


def _user_for(user: dict, listener: dict) -> dict:
    """The user as this listener takes it: a Shadowsocks 2022 listener, a key of its length."""
    if user.get("runtime") and listener.get("type") == "shadowsocks" and listener.get("method") in SS2022_KEY_BYTES:
        return {**user, "password": _ss_key(listener["method"], user["password"])}
    return user


def _user_problem(user: dict, listener_type: str) -> str | None:
    """Why a user cannot be on a listener of this type, or None."""
    if listener_type in UUID_TYPES and user.get("uuid") is None and user.get("uuidFile") is None:
        return f"user '{user['name']}' has no uuid, which {listener_type} needs"
    if listener_type in PASSWORD_TYPES and user.get("password") is None and user.get("passwordFile") is None:
        return f"user '{user['name']}' has no password, which {listener_type} needs"
    return None


def new_user(order: int, listeners: list[str]) -> dict:
    return {
        "order": order,
        "uuid": str(uuid.uuid4()),
        "password": secrets.token_urlsafe(18),
        "listeners": listeners,
    }


# --- listeners ------------------------------------------------------------------------


def listener_problems(listener: dict, runtime: dict, share_links: bool) -> list[str]:
    """The declared listeners' assertions (service-assertions.nix), for a runtime listener
    filled in with the defaults and its users, plus the fences of inbounds.runtime."""
    problems = []

    def need(condition: bool, message: str) -> None:
        if not condition:
            problems.append(message)

    kind = listener["type"]
    transport = listener["transport"]
    tls = listener["tls"]
    reality = listener["reality"]
    hysteria = listener["hysteria"]
    users = listener["users"]
    tls_terminated = tls["enable"] or kind in ("trojan", "hysteria2")

    need(_port_allowed(listener["port"], runtime.get("ports") or []),
         f"port {listener['port']} is not in inbounds.runtime.ports")
    need(listener["via"] in runtime.get("vias") or [],
         f"via '{listener['via']}' is not routing.via, \"block\" or in inbounds.runtime.vias")
    need(not (tls["enable"] and reality["enable"]), "tls and reality are mutually exclusive")
    need(len({user["name"] for user in users}) == len(users), "users must each have a distinct name")
    multi_ss = kind == "shadowsocks" and len(users) > 1
    need(not multi_ss or listener["method"].startswith("2022-blake3-aes-"),
         "shadowsocks with more than one user needs a 2022-blake3-aes-* method")
    need(not multi_ss or listener.get("serverPassword") is not None,
         "shadowsocks with more than one user needs serverPassword")
    need(not reality["enable"] or transport["type"] in ("raw", "xhttp", "grpc"),
         "reality only runs over the raw, xhttp and grpc transports")
    need(not share_links or not reality["enable"] or kind in ("vless", "trojan"),
         "share links carry reality only for vless and trojan")
    need(not share_links or not tls["enable"] or kind not in ("shadowsocks", "socks"),
         f"share links cannot carry tls for {kind}")
    if reality["enable"]:
        need(reality.get("privateKey") is not None, "reality needs privateKey")
        need(bool(reality["serverNames"]), "reality.serverNames must not be empty")
        need(not share_links or reality.get("publicKey") is not None, "reality needs publicKey for share links")
    if tls_terminated and not reality["enable"]:
        certificate = tls.get("certificate")
        need(certificate is not None, "TLS needs tls.certificate, one of inbounds.runtime.tlsCertificates")
        need(certificate is None or certificate in (runtime.get("tlsCertificates") or {}),
             f"tls.certificate '{certificate}' is not in inbounds.runtime.tlsCertificates")
    need(listener.get("flow") is None or (kind == "vless" and transport["type"] == "raw"),
         'flow is only valid on a vless listener with transport.type = "raw"')
    alpn = tls.get("alpn")
    need(alpn is None or "h3" not in alpn or kind == "hysteria2"
         or (transport["type"] == "xhttp" and tls["enable"] and not reality["enable"]),
         'tls.alpn "h3" is served only by hysteria2, and by the xhttp transport with tls')
    need(kind != "hysteria2" or (not reality["enable"] and transport["type"] == "raw"),
         "hysteria2 takes no reality or transport")
    need(hysteria.get("masquerade") is None or kind == "hysteria2",
         "hysteria.masquerade is for hysteria2 listeners only")
    need(not hysteria["salamander"]["enable"] or kind == "hysteria2",
         "hysteria.salamander is for hysteria2 listeners only")
    need(not listener["acceptProxyProtocol"] or not _udp_only(listener),
         "acceptProxyProtocol is for TCP listeners")
    need(not listener["fallbacks"] or (kind in ("vless", "trojan") and transport["type"] == "raw"),
         'fallbacks run only on a vless or trojan listener with transport.type = "raw"')
    for fallback in listener["fallbacks"]:
        has_dest = fallback.get("dest") is not None
        has_listener = fallback.get("listener") is not None
        need(has_dest != has_listener, "fallbacks each need exactly one of dest or listener")
        if has_dest:
            need(fallback["dest"] in (runtime.get("fallbackDests") or []),
                 f"fallback dest {json.dumps(fallback['dest'])} is not in inbounds.runtime.fallbackDests")
    return problems


def _fallback_target_problems(listener: dict, target: dict | None, fallback: dict) -> list[str]:
    name = fallback["listener"]
    if target is None or target["tag"] == listener["tag"]:
        return [f"fallback listener '{name}' must be another runtime listener"]
    problems = []
    if not (
        target["type"] == "vless"
        and not target["tls"]["enable"]
        and not target["reality"]["enable"]
        and (target["listen"].startswith("127.") or target["listen"] == "::1")
    ):
        problems.append(f"fallback listener '{name}' must be a vless listener, without tls or reality, on a loopback address")
    if fallback.get("path") is not None and not (
        target["transport"]["type"] in ("ws", "httpupgrade") and fallback["path"] == target["transport"]["path"]
    ):
        problems.append(f"fallback path matches only a ws or httpupgrade listener '{name}', and must be its transport.path")
    if listener["reality"]["enable"] and target["transport"]["type"] not in ("xhttp", "grpc"):
        problems.append(f"a REALITY listener's fallback listener '{name}' must use the xhttp or grpc transport")
    return problems


def _render_listener(tag: str, entry: dict, runtime: dict) -> dict:
    """A runtime listener, filled in with the defaults, in the spec's shape (config.nix)."""
    filled = _deep_merge(runtime.get("listenerDefaults") or {}, {k: v for k, v in entry.items() if k != "users"})
    filled["tag"] = tag
    filled["runtime"] = True
    filled["via"] = filled.get("via") or runtime.get("defaultVia") or "proxy"
    filled["listen"] = filled.pop("address", "::")
    tls = filled.setdefault("tls", {})
    certificate = (runtime.get("tlsCertificates") or {}).get(tls.get("certificate") or "")
    tls["certificateFile"] = certificate["certificateFile"] if certificate else None
    tls["keyFile"] = certificate["keyFile"] if certificate else None
    if certificate and tls.get("serverName") is None:
        tls["serverName"] = certificate.get("serverName")
    hysteria = filled.setdefault("hysteria", {})
    hysteria["portHopping"] = None
    hysteria.setdefault("salamander", {})["passwordFile"] = None
    filled["serverPasswordFile"] = None
    filled["xrayJson"] = None
    filled["jsonFile"] = None
    filled["front"] = None
    filled["salamanderStateFile"] = os.path.join(runtime.get("salamanderStateDir") or "/var/lib/proxy-suite/inbounds", tag, "salamander-password")
    filled["users"] = []
    return filled


def _render_fallbacks(listener: dict, by_tag: dict) -> None:
    rendered = []
    for fallback in listener["fallbacks"]:
        entry = {key: fallback.get(key) for key in ("name", "alpn", "path")}
        if fallback.get("listener") is None:
            entry.update({"dest": fallback.get("dest"), "xver": fallback.get("xver", 0)})
        else:
            target = by_tag[fallback["listener"]]
            host = f"[{target['listen']}]" if ":" in target["listen"] else target["listen"]
            entry.update({"dest": f"{host}:{target['port']}", "xver": 2})
            target["front"] = {
                key: listener[key] for key in ("tag", "type", "port", "sharePort", "shareAddress", "tls", "reality")
            }
        rendered.append(entry)
    listener["fallbacks"] = rendered


# --- the merge ------------------------------------------------------------------------


# The declared users and their serverSource numbers are the spec's own, there with runtime
# or without: `inbounds users` lists them either way.


def _declared_users(spec: dict) -> dict[str, dict]:
    return spec.get("users") or {}


def _declared_numbers(spec: dict) -> dict[str, int]:
    return {entry["name"]: entry["number"] for entry in (spec.get("serverSource") or {}).get("declared", [])}


def taken_orders(spec: dict) -> set[int]:
    """Numbers a runtime user cannot have: the declared users' orders and serverSource numbers."""
    taken = set(_declared_numbers(spec).values())
    taken.update(user["order"] for user in _declared_users(spec).values() if user.get("order") is not None)
    return taken


def number_users(spec: dict, names: list[str], state_users: dict, warnings: list[str]) -> list[dict]:
    """The runtime users' serverSource numbers and addresses: their own order, unless a
    declared user holds it, which moves them to the next free one."""
    source = spec.get("serverSource") or {}
    if source.get("ipv4") is None and source.get("ipv6") is None:
        return []
    taken = taken_orders(spec)
    size = None
    if source.get("ipv4") is not None:
        size = ipaddress.ip_network(source["ipv4"], strict=False).num_addresses
    numbered = []
    for name in sorted(names, key=lambda n: (state_users[n]["order"], n)):
        wanted = number = state_users[name]["order"]
        while number in taken:
            number += 1
        if number != wanted:
            warnings.append(f"runtime user '{name}': order {wanted} is taken; using {number} until it is free")
        if size is not None and number + 2 > size:
            warnings.append(f"runtime user '{name}': number {number} does not fit in serverSource.ipv4; no own address")
            continue
        taken.add(number)
        numbered.append(
            {
                "email": name,
                "number": number,
                "id": str(number),
                "ipv4": None if source.get("ipv4") is None
                else str(ipaddress.ip_network(source["ipv4"], strict=False).network_address + number),
                "ipv6": None if source.get("ipv6") is None
                else source["ipv6"].split("/", 1)[0] + format(number, "x"),
            }
        )
    return numbered


def merge_state(spec: dict, state: dict, check_ports: bool = False) -> tuple[dict, dict, list[str]]:
    """The spec with the runtime entries merged in, what was made of them, and warnings.

    The result's "runtime" key holds {"listeners": [runtime tags kept], "users": [runtime
    names kept], "selfSources": [...], "problems": {("user"|"listener", name): [why]}}.
    """
    runtime = spec.get("runtime")
    merged = copy.deepcopy(spec)
    result = {"listeners": [], "users": [], "selfSources": [], "problems": {}}
    if not runtime:
        return merged, result, []
    warnings: list[str] = []
    problems: dict = result["problems"]

    def problem(kind: str, name: str, message: str) -> None:
        problems.setdefault((kind, name), []).append(message)
        warnings.append(f"runtime {kind} '{name}': {message}")

    share_links = spec.get("shareLinks", True)
    declared_users = _declared_users(spec)
    declared = {listener["tag"]: listener for listener in merged["listeners"]}

    users: dict[str, dict] = {}
    for name, entry in state["users"].items():
        try:
            check_user_shape(entry)
        except RuntimeError_ as exc:
            problem("user", name, str(exc))
            continue
        if name in declared_users:
            problem("user", name, "a declared user has this name")
            continue
        users[name] = _runtime_user(name, entry)

    def user_named(name: str) -> dict | None:
        if name in users:
            return users[name]
        if name in declared_users:
            return {**declared_users[name], "name": name}
        return None

    # Runtime listeners: shape, fences, users.
    runtime_listeners: dict[str, dict] = {}
    for tag, entry in sorted(state["listeners"].items()):
        try:
            check_listener_shape(entry)
        except RuntimeError_ as exc:
            problem("listener", tag, str(exc))
            continue
        if tag in declared or tag in RESERVED_TAGS:
            problem("listener", tag, "a declared listener has this tag")
            continue
        listener = _render_listener(tag, entry, runtime)
        for name in entry.get("users", []):
            user = user_named(name)
            if user is None:
                problem("listener", tag, f"user '{name}' does not exist; left out")
                continue
            why = _user_problem(user, listener["type"])
            if why:
                problem("listener", tag, f"{why}; left out")
                continue
            listener["users"].append(user)
        runtime_listeners[tag] = listener

    # Runtime users onto the listeners they name, declared or runtime.
    for name in sorted(users):
        for tag in state["users"][name].get("listeners", []):
            target = declared.get(tag) or runtime_listeners.get(tag)
            if target is None:
                problem("user", name, f"listener '{tag}' does not exist; not bound")
                continue
            if any(user["name"] == name for user in target["users"]):
                continue
            why = _user_problem(users[name], target["type"]) if target.get("type") else "it is a raw JSON listener"
            if why:
                problem("user", name, f"cannot be on '{tag}': {why}")
                continue
            candidate = users[name]
            if tag in declared and target["type"] == "shadowsocks" and target["users"]:
                if not target["method"].startswith("2022-blake3-aes-") or (
                    target.get("serverPassword") is None and target.get("serverPasswordFile") is None
                ):
                    problem("user", name, f"cannot be on '{tag}': a second shadowsocks user needs a 2022-blake3-aes method and a server password")
                    continue
            target["users"].append(candidate)

    # Ports, fences and the declared assertions, on the listeners as they now stand.
    declared_ports = {listener["port"] for listener in merged["listeners"]}
    used_ports: set[int] = set()
    for tag in sorted(runtime_listeners, key=lambda t: (runtime_listeners[t]["order"], t)):
        listener = runtime_listeners[tag]
        why = listener_problems(listener, runtime, share_links)
        if listener["port"] in declared_ports or listener["port"] in used_ports:
            why.append(f"port {listener['port']} is taken by another listener")
        if not why and check_ports and not port_free(listener["listen"], listener["port"], _protocols(listener)):
            why.append(f"port {listener['port']} is in use on this host")
        if why:
            for message in why:
                problem("listener", tag, message)
            del runtime_listeners[tag]
            continue
        used_ports.add(listener["port"])

    # Fallbacks to other runtime listeners, which must be there and fit, each behind one front
    # only. Until nothing changes: a front left out can leave another's target without it.
    changed = True
    while changed:
        changed = False
        fronted: dict[str, str] = {}
        for tag in sorted(runtime_listeners):
            listener = runtime_listeners[tag]
            targets = [fb for fb in listener["fallbacks"] if fb.get("listener") is not None]
            why = []
            for fallback in targets:
                why += _fallback_target_problems(listener, runtime_listeners.get(fallback["listener"]), fallback)
                if fallback["listener"] in fronted:
                    why.append(f"'{fallback['listener']}' is already the fallback listener of '{fronted[fallback['listener']]}'")
            if why:
                for message in why:
                    problem("listener", tag, message)
                del runtime_listeners[tag]
                changed = True
                break
            fronted.update({fb["listener"]: tag for fb in targets})
    for listener in runtime_listeners.values():
        _render_fallbacks(listener, runtime_listeners)

    # Every listener's users as it takes them; listeners without any are left out.
    kept = []
    for listener in merged["listeners"] + list(runtime_listeners.values()):
        listener["users"] = [_user_for(user, listener) for user in listener["users"]]
        if not listener["users"] and listener.get("type") not in (None, "amneziawg"):
            if listener.get("runtime"):
                warnings.append(f"runtime listener '{listener['tag']}' has no users yet; not started")
            else:
                warnings.append(f"listener '{listener['tag']}' has no users yet; not started")
            continue
        kept.append(listener)
    merged["listeners"] = sorted(kept, key=lambda listener: (listener.get("order", 1000), listener["tag"]))
    result["listeners"] = sorted(t for t in runtime_listeners if any(l["tag"] == t for l in kept))

    # serverSource numbers, for the users XRay's listeners accept.
    on_xray = {
        user["name"]
        for listener in merged["listeners"]
        if listener.get("type") != "amneziawg"
        for user in listener["users"]
        if user.get("runtime")
    }
    result["users"] = sorted(users)
    result["selfSources"] = number_users(spec, sorted(on_xray), state["users"], warnings)
    return merged, result, warnings


def merge(spec: dict, check_ports: bool = False) -> tuple[dict, dict, list[str]]:
    """merge_state() on the spool the spec names, as the services read it at start."""
    runtime = spec.get("runtime")
    if not runtime:
        return spec, {"listeners": [], "users": [], "selfSources": [], "problems": {}}, []
    state, warnings = load_spool(runtime["spool"])
    merged, result, more = merge_state(spec, state, check_ports)
    return merged, result, warnings + more


# --- routing --------------------------------------------------------------------------


def _member(rule: dict, via: str) -> bool:
    members = rule["_members"]
    if "via" in members and via not in members["via"]:
        return False
    return not ("notVia" in members and via in members["notVia"])


def _self_rules(anchor: dict, source: dict) -> list[dict]:
    """A runtime user's serverSource rules, as rules/proxy-inbounds.nix makes a declared one's."""
    common = {
        "type": "field",
        "user": [source["email"]],
        "inboundTag": list(anchor["inboundTag"]),
        "port": anchor["port"],
        "_members": anchor["_members"],
    }
    rules = []
    if anchor["_anchor"] == "selfIp":
        if source["ipv4"] is not None and anchor.get("ip4"):
            rules.append({**common, "ruleTag": f"inbound-server-address-self-ip4-{source['id']}", "ip": anchor["ip4"],
                          "outboundTag": f"direct-self4-{source['id']}"})
        if source["ipv6"] is not None and anchor.get("ip6"):
            rules.append({**common, "ruleTag": f"inbound-server-address-self-ip6-{source['id']}", "ip": anchor["ip6"],
                          "outboundTag": f"direct-self6-{source['id']}"})
    elif anchor.get("domain"):
        family = "4" if source["ipv4"] is not None else "6"
        rules.append({**common, "ruleTag": f"inbound-server-address-self-{source['id']}", "domain": anchor["domain"],
                      "outboundTag": f"direct-self{family}-{source['id']}"})
    return rules


def expand_rules(rules: list[dict], listeners: list[dict], self_sources: list[dict], default_via: str) -> list[dict]:
    """The template's routing rules with the runtime listeners and users in: their tags added
    to the rules marked for their via, their serverSource rules at the anchors, their own
    via rules before the final one. Marked rules nobody is left in go."""
    expanded = []
    for rule in rules:
        if "_anchor" in rule:
            for source in self_sources:
                expanded.extend(_self_rules(rule, source))
            continue
        expanded.append(dict(rule))
    result = []
    for rule in expanded:
        if "_members" in rule:
            tags = list(rule.get("inboundTag") or [])
            tags += [listener["tag"] for listener in listeners if _member(rule, listener["via"]) and listener["tag"] not in tags]
            rule.pop("_members")
            if not tags:
                continue
            rule["inboundTag"] = tags
        result.append(rule)
    overrides = [
        {"type": "field", "ruleTag": f"inbound-via-{listener['tag']}", "inboundTag": [listener["tag"]], "outboundTag": listener["via"]}
        for listener in listeners
        if listener["via"] != default_via
    ]
    final = next((index for index, rule in enumerate(result) if rule.get("ruleTag") == "inbound-final"), len(result))
    return result[:final] + overrides + result[final:]


def self_outbounds(self_sources: list[dict], final_rules: list) -> list[dict]:
    outbounds = []
    for source in self_sources:
        for family, address in (("4", source["ipv4"]), ("6", source["ipv6"])):
            if address is not None:
                outbounds.append(
                    {
                        "protocol": "freedom",
                        "tag": f"direct-self{family}-{source['id']}",
                        "sendThrough": address,
                        "settings": {"domainStrategy": f"UseIPv{family}", "finalRules": final_rules},
                    }
                )
    return outbounds


def routing(spec: dict, result: dict, template_rules: list[dict]) -> dict:
    """What the start script splices into the XRay config: the rules, the runtime users'
    serverSource outbounds, and their addresses for the dummy interface."""
    runtime = spec.get("runtime") or {}
    listeners = [listener for listener in spec["listeners"] if listener.get("runtime")]
    return {
        "rules": expand_rules(template_rules, listeners, result["selfSources"], runtime.get("defaultVia", "proxy")),
        "selfOutbounds": self_outbounds(result["selfSources"], runtime.get("selfFinalRules") or []),
        "selfAddresses": [{"ipv4": s["ipv4"], "ipv6": s["ipv6"]} for s in result["selfSources"]],
    }


# --- proxy-ctl's commands -------------------------------------------------------------


def _free_order(spec: dict, state: dict, skip: str = "") -> int:
    taken = taken_orders(spec) | {entry.get("order") for name, entry in state["users"].items() if name != skip}
    order = 1
    while order in taken:
        order += 1
    return order


def _check_order(spec: dict, state: dict, order: int, name: str) -> None:
    if order < 1:
        raise RuntimeError_("An order is a number from 1 up.")
    declared = {v: k for k, v in _declared_numbers(spec).items()}
    declared.update({user["order"]: k for k, user in _declared_users(spec).items() if user.get("order") is not None})
    if order in declared:
        raise RuntimeError_(f"Order {order} belongs to declared user '{declared[order]}'.")
    for other, entry in state["users"].items():
        if other != name and entry.get("order") == order:
            raise RuntimeError_(f"Order {order} belongs to runtime user '{other}'.")


def _listener_tags(spec: dict, state: dict) -> set[str]:
    return {listener["tag"] for listener in spec["listeners"]} | set(state["listeners"])


def _commit(spec: dict, state: dict, before: dict, changed: list[tuple[str, str]]) -> None:
    """Refuse the change if it leaves one of the changed entries, or any entry that was
    fine before, not holding up."""
    _, result_before, _ = merge_state(spec, before)
    _, result, _ = merge_state(spec, state)
    new = {key: msgs for key, msgs in result["problems"].items() if key in changed or key not in result_before["problems"]}
    if new:
        messages = [f"{kind} '{name}': {message}" for (kind, name), msgs in sorted(new.items()) for message in msgs]
        raise RuntimeError_("\n".join(messages))


def _require_name(name: str, what: str) -> None:
    if not NAME.fullmatch(name or ""):
        raise RuntimeError_(f"Invalid {what} '{name}': letters, digits, dot, dash and underscore, up to 32.")


def cmd_users_add(spec: dict, spool: str, name: str, order: int | None, listeners: list[str]) -> str:
    state, _ = load_spool(spool)
    before = copy.deepcopy(state)
    _require_name(name, "user name")
    if name in _declared_users(spec):
        raise RuntimeError_(f"'{name}' is a declared user.")
    if name in state["users"]:
        raise RuntimeError_(f"A runtime user named '{name}' already exists.")
    tags = _listener_tags(spec, state)
    for tag in listeners:
        if tag not in tags:
            raise RuntimeError_(f"Unknown listener: {tag}")
    if order is None:
        order = _free_order(spec, state)
    else:
        _check_order(spec, state, order, name)
    entry = new_user(order, list(dict.fromkeys(listeners)))
    state["users"][name] = entry
    _commit(spec, state, before, [("user", name)])
    write_entry(spool, "users", name, entry)
    return f"Added user {name} (order {order})" + (f" on {', '.join(entry['listeners'])}" if entry["listeners"] else "")


def cmd_users_rm(spec: dict, spool: str, name: str) -> str:
    state, _ = load_spool(spool)
    if name in _declared_users(spec):
        raise RuntimeError_(f"'{name}' is declared in the configuration; remove it there.")
    if name not in state["users"]:
        raise RuntimeError_(f"Unknown runtime user: {name}")
    remove_entry(spool, "users", name)
    for tag, entry in state["listeners"].items():
        if name in entry.get("users", []):
            entry["users"] = [n for n in entry["users"] if n != name]
            write_entry(spool, "listeners", tag, entry)
    return f"Removed user {name}"


def cmd_users_order(spec: dict, spool: str, name: str, order: int) -> str:
    state, _ = load_spool(spool)
    if name in _declared_users(spec):
        raise RuntimeError_(f"'{name}' is declared in the configuration; set its order there.")
    if name not in state["users"]:
        raise RuntimeError_(f"Unknown runtime user: {name}")
    _check_order(spec, state, order, name)
    state["users"][name]["order"] = order
    write_entry(spool, "users", name, state["users"][name])
    return f"{name}: order {order}"


def cmd_bind(spec: dict, spool: str, user: str, tag: str, bind: bool) -> str:
    state, _ = load_spool(spool)
    before = copy.deepcopy(state)
    declared_users = _declared_users(spec)
    if user not in state["users"] and user not in declared_users:
        raise RuntimeError_(f"Unknown user: {user}")
    if tag not in _listener_tags(spec, state):
        raise RuntimeError_(f"Unknown listener: {tag}")
    if user in state["users"]:
        kind, name, field, value = "users", user, "listeners", tag
    elif tag in state["listeners"]:
        kind, name, field, value = "listeners", tag, "users", user
    else:
        raise RuntimeError_(f"Both {user} and {tag} are declared in the configuration; bind them there.")
    entry = state[kind][name]
    current = entry.get(field, [])
    if bind:
        if value in current:
            return f"{user} is already on {tag}"
        entry[field] = [*current, value]
        _commit(spec, state, before, [(kind[:-1], name)])
    else:
        if value not in current:
            raise RuntimeError_(f"{user} is not bound to {tag} at runtime.")
        entry[field] = [v for v in current if v != value]
    write_entry(spool, kind, name, entry)
    return f"{'Bound' if bind else 'Unbound'} {user} {'to' if bind else 'from'} {tag}"


def _x25519(xray: str) -> tuple[str, str]:
    """A REALITY key pair from `xray x25519`, whose labels vary between versions."""
    try:
        out = subprocess.run([xray, "x25519"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise RuntimeError_(f"cannot generate a REALITY key pair with {xray}: {exc}") from None
    private = public = None
    for line in out.splitlines():
        label, _, value = line.partition(":")
        label = re.sub(r"[^a-z]", "", label.lower())
        if label == "privatekey":
            private = value.strip()
        elif "publickey" in label or label == "password":
            public = value.strip()
    if not private or not public:
        raise RuntimeError_(f"cannot read the key pair `{xray} x25519` printed")
    return private, public


def complete_listener(entry: dict, xray: str) -> dict:
    """Generate what a new listener leaves out: a REALITY key pair and short ID, and a
    Shadowsocks 2022 server key."""
    entry = copy.deepcopy(entry)
    reality = entry.get("reality") or {}
    if reality.get("enable"):
        if reality.get("privateKey") is None:
            reality["privateKey"], reality["publicKey"] = _x25519(xray)
        reality.setdefault("shortIds", [secrets.token_hex(4)])
        entry["reality"] = reality
    method = entry.get("method")
    if entry.get("type") == "shadowsocks" and method in SS2022_KEY_BYTES and method.startswith("2022-blake3-aes-"):
        entry.setdefault("serverPassword", base64.b64encode(secrets.token_bytes(SS2022_KEY_BYTES[method])).decode("ascii"))
    return entry


def listener_from_flags(kind: str, args: argparse.Namespace) -> dict:
    """A listener entry from `add <tag> <type> [flags]`."""
    entry: dict = {"type": kind}
    for flag, key in (("port", "port"), ("listen", "address"), ("via", "via"), ("share_port", "sharePort"),
                      ("share_address", "shareAddress"), ("order", "order"), ("method", "method")):
        if getattr(args, flag) is not None:
            entry[key] = getattr(args, flag)
    if args.flow:
        entry["flow"] = "xtls-rprx-vision" if args.flow in ("vision", "xtls-rprx-vision") else args.flow
    transport = {}
    for flag, key in (("transport", "type"), ("path", "path"), ("host", "host"), ("mode", "mode"), ("service_name", "serviceName")):
        if getattr(args, flag) is not None:
            transport[key] = getattr(args, flag)
    if transport:
        entry["transport"] = transport
    tls = {}
    if args.tls:
        tls.update({"enable": True, "certificate": args.tls})
    if args.alpn:
        tls["alpn"] = [part for part in args.alpn.split(",") if part]
    if args.sni:
        tls["serverName"] = args.sni
    if tls:
        entry["tls"] = tls
    if args.reality:
        reality = {"enable": True, "serverNames": [part for part in args.reality.split(",") if part]}
        # The site the names belong to, unless it is somewhere else.
        if args.reality_dest:
            reality["dest"] = args.reality_dest
        elif reality["serverNames"]:
            reality["dest"] = f"{reality['serverNames'][0]}:443"
        if args.short_id is not None:
            reality["shortIds"] = [args.short_id]
        entry["reality"] = {k: v for k, v in reality.items() if v is not None}
    hysteria: dict = {}
    if args.masquerade:
        hysteria["masquerade"] = args.masquerade
    if args.salamander:
        hysteria["salamander"] = {"enable": True}
    if hysteria:
        entry["hysteria"] = hysteria
    if args.user:
        entry["users"] = list(dict.fromkeys(args.user))
    return entry


def cmd_add(spec: dict, spool: str, tag: str, entry: dict, xray: str) -> str:
    state, _ = load_spool(spool)
    before = copy.deepcopy(state)
    _require_name(tag, "listener tag")
    if tag in RESERVED_TAGS or tag in {listener["tag"] for listener in spec["listeners"]}:
        raise RuntimeError_(f"A listener named '{tag}' is declared in the configuration.")
    if tag in state["listeners"]:
        raise RuntimeError_(f"A runtime listener named '{tag}' already exists; remove it first.")
    entry.pop("tag", None)
    check_listener_shape(entry)
    for name in entry.get("users", []):
        if name not in state["users"] and name not in _declared_users(spec):
            raise RuntimeError_(f"Unknown user: {name}")
    entry = complete_listener(entry, xray)
    state["listeners"][tag] = entry
    _commit(spec, state, before, [("listener", tag)])
    write_entry(spool, "listeners", tag, entry)
    users = entry.get("users", [])
    note = f" for {', '.join(users)}" if users else "; bind users to it with: proxy-ctl inbounds bind <user> " + tag
    return f"Added listener {tag} ({entry['type']}, port {entry.get('port', 443)}){note}"


def cmd_rm(spec: dict, spool: str, tag: str) -> str:
    state, _ = load_spool(spool)
    if tag in {listener["tag"] for listener in spec["listeners"]}:
        raise RuntimeError_(f"'{tag}' is declared in the configuration; remove it there.")
    if tag not in state["listeners"]:
        raise RuntimeError_(f"Unknown runtime listener: {tag}")
    remove_entry(spool, "listeners", tag)
    for name, entry in state["users"].items():
        if tag in entry.get("listeners", []):
            entry["listeners"] = [t for t in entry["listeners"] if t != tag]
            write_entry(spool, "users", name, entry)
    return f"Removed listener {tag}"


def users_view(spec: dict, state: dict) -> list[dict]:
    """Every user, declared and runtime: its order, serverSource address, listeners and
    where it comes from, and what keeps a runtime one from working."""
    merged, result, _ = merge_state(spec, state)
    on: dict[str, list[str]] = {}
    for listener in merged["listeners"]:
        for user in listener["users"]:
            on.setdefault(user["name"], []).append(listener["tag"])
    declared_numbers = _declared_numbers(spec)
    runtime_numbers = {s["email"]: s for s in result["selfSources"]}
    source = spec.get("serverSource") or {}

    def address(number: int | None) -> str:
        if number is None or source.get("ipv4") is None:
            return ""
        return str(ipaddress.ip_network(source["ipv4"], strict=False).network_address + number)

    rows = []
    for name, user in sorted(_declared_users(spec).items()):
        number = declared_numbers.get(name)
        rows.append({"name": name, "source": "nix", "order": user.get("order") if user.get("order") is not None else number,
                     "address": address(number), "listeners": on.get(name, []), "problems": []})
    for name, entry in sorted(state["users"].items()):
        numbered = runtime_numbers.get(name)
        rows.append(
            {
                "name": name,
                "source": "runtime",
                "order": entry.get("order"),
                "address": address(numbered["number"]) if numbered else "",
                "listeners": on.get(name, []),
                "problems": result["problems"].get(("user", name), []),
            }
        )
    return rows


def listeners_view(spec: dict, state: dict) -> list[dict]:
    """Every listener, declared and runtime: tag, type, port, via, users, source."""
    merged, result, _ = merge_state(spec, state)
    started = {listener["tag"]: listener for listener in merged["listeners"]}
    rows = []
    for listener in spec["listeners"]:
        current = started.get(listener["tag"], listener)
        rows.append({"tag": listener["tag"], "type": listener.get("type") or "json", "port": listener["port"],
                     "via": listener.get("via") or "", "users": [u["name"] for u in current["users"]],
                     "source": "nix", "problems": []})
    for tag, entry in sorted(state["listeners"].items()):
        current = started.get(tag)
        rows.append(
            {
                "tag": tag,
                "type": entry.get("type", ""),
                "port": entry.get("port", (spec["runtime"].get("listenerDefaults") or {}).get("port", 443)),
                "via": entry.get("via") or spec["runtime"].get("defaultVia", ""),
                "users": [u["name"] for u in current["users"]] if current else entry.get("users", []),
                "source": "runtime",
                "problems": result["problems"].get(("listener", tag), []),
            }
        )
    return rows


def _table(rows: list[dict], columns: list[tuple[str, str]]) -> str:
    def cell(row: dict, key: str) -> str:
        value = row.get(key)
        if isinstance(value, list):
            return ",".join(str(v) for v in value) or "-"
        return "-" if value in (None, "") else str(value)

    widths = {key: max([len(heading)] + [len(cell(row, key)) for row in rows]) for key, heading in columns}
    lines = ["  " + "  ".join(heading.ljust(widths[key]) for key, heading in columns).rstrip()]
    for row in rows:
        lines.append("  " + "  ".join(cell(row, key).ljust(widths[key]) for key, _ in columns).rstrip())
        for problem in row.get("problems") or []:
            lines.append(f"    ! {problem}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="inbound-runtime", description=__doc__.split("\n", 1)[0])
    parser.add_argument("--spec", required=True, help="the generated inbound spec JSON")
    parser.add_argument("--xray", default="xray", help="XRay, for REALITY key pairs")
    commands = parser.add_subparsers(dest="command", required=True)

    users = commands.add_parser("users", help="inbound users, declared and runtime")
    users.add_argument("--json", action="store_true")
    user_verbs = users.add_subparsers(dest="verb")
    add_user = user_verbs.add_parser("add")
    add_user.add_argument("name")
    add_user.add_argument("--order", type=int)
    add_user.add_argument("--listener", action="append", default=[])
    rm_user = user_verbs.add_parser("rm")
    rm_user.add_argument("name")
    order_user = user_verbs.add_parser("order")
    order_user.add_argument("name")
    order_user.add_argument("order", type=int)

    for verb in ("bind", "unbind"):
        bind = commands.add_parser(verb)
        bind.add_argument("user")
        bind.add_argument("tag")

    listeners = commands.add_parser("listeners", help="listeners, declared and runtime")
    listeners.add_argument("--json", action="store_true")

    add = commands.add_parser("add", help="add a runtime listener")
    add.add_argument("tag")
    add.add_argument("source", help="a listener type, a JSON file, or - for JSON on stdin")
    for flag, kind in (("--port", int), ("--listen", str), ("--via", str), ("--share-port", int), ("--share-address", str),
                       ("--order", int), ("--method", str), ("--flow", str), ("--transport", str), ("--path", str),
                       ("--host", str), ("--mode", str), ("--service-name", str), ("--tls", str), ("--alpn", str),
                       ("--sni", str), ("--reality", str), ("--reality-dest", str), ("--short-id", str),
                       ("--masquerade", str)):
        add.add_argument(flag, type=kind)
    add.add_argument("--salamander", action="store_true")
    add.add_argument("--user", action="append", default=[])

    for verb in ("rm", "show"):
        commands.add_parser(verb).add_argument("tag")
    check = commands.add_parser(
        "check", help="merge the spool as the services would; warnings on stderr, units to restart on stdout"
    )
    check.add_argument("--awg-users", help="users.json of the AmneziaWG listeners' unit, as it last started")
    check.add_argument("--awg-unit", default="proxy-suite-inbounds-awg.service")

    args = parser.parse_args(argv)
    try:
        with open(args.spec, encoding="utf-8") as handle:
            spec = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"cannot read the inbound spec {args.spec}: {exc}", file=sys.stderr)
        return 1
    # Listing works without inbounds.runtime: the declared users and listeners, as they are.
    listing = args.command in ("users", "listeners") and getattr(args, "verb", None) in (None, "list")
    if not spec.get("runtime") and not listing:
        print("inbounds.runtime is not enabled in this configuration.", file=sys.stderr)
        return 1
    spool = (spec.get("runtime") or {}).get("spool", "")
    changes = args.command in ("add", "rm", "bind", "unbind") or (args.command == "users" and args.verb in ("add", "rm", "order"))
    kinds = [os.path.join(spool, kind) for kind in ("users", "listeners")]
    writable = [spool, *(path for path in kinds if os.path.isdir(path))]
    if changes and not all(os.access(path, os.W_OK | os.X_OK) for path in writable):
        print(f"Cannot write {spool}", file=sys.stderr)
        return 77
    try:
        if args.command == "users" and args.verb in (None, "list"):
            state, warnings = load_spool(spool)
            for warning in warnings:
                print(warning, file=sys.stderr)
            rows = users_view(spec, state)
            print(json.dumps(rows) if args.json else _table(rows, [("name", "USER"), ("order", "ORDER"), ("address", "ADDRESS"),
                                                                    ("source", "SOURCE"), ("listeners", "LISTENERS")]))
        elif args.command == "users" and args.verb == "add":
            print(cmd_users_add(spec, spool, args.name, args.order, args.listener))
        elif args.command == "users" and args.verb == "rm":
            print(cmd_users_rm(spec, spool, args.name))
        elif args.command == "users" and args.verb == "order":
            print(cmd_users_order(spec, spool, args.name, args.order))
        elif args.command in ("bind", "unbind"):
            print(cmd_bind(spec, spool, args.user, args.tag, args.command == "bind"))
        elif args.command == "listeners":
            state, warnings = load_spool(spool)
            for warning in warnings:
                print(warning, file=sys.stderr)
            rows = listeners_view(spec, state)
            print(json.dumps(rows) if args.json else _table(rows, [("tag", "TAG"), ("type", "TYPE"), ("port", "PORT"), ("via", "VIA"),
                                                                    ("source", "SOURCE"), ("users", "USERS")]))
        elif args.command == "add":
            if args.source in TYPES:
                entry = listener_from_flags(args.source, args)
            else:
                text = sys.stdin.read() if args.source == "-" else open(args.source, encoding="utf-8").read()
                try:
                    entry = json.loads(text)
                except ValueError as exc:
                    raise RuntimeError_(f"not a listener type, and not valid JSON: {exc}") from None
                if not isinstance(entry, dict):
                    raise RuntimeError_("the JSON must be one listener object")
                entry.setdefault("users", []).extend(u for u in args.user if u not in entry["users"])
            print(cmd_add(spec, spool, args.tag, entry, args.xray))
        elif args.command == "rm":
            print(cmd_rm(spec, spool, args.tag))
        elif args.command == "show":
            state, _ = load_spool(spool)
            if args.tag not in state["listeners"]:
                raise RuntimeError_(f"Unknown runtime listener: {args.tag}")
            print(json.dumps(state["listeners"][args.tag], indent=2, sort_keys=True))
        elif args.command == "check":
            merged, _, warnings = merge(spec)
            for warning in warnings:
                print(warning, file=sys.stderr)
            if args.awg_users:
                awg = {
                    listener["tag"]: sorted(user["name"] for user in listener["users"])
                    for listener in merged["listeners"]
                    if listener.get("type") == "amneziawg"
                }
                try:
                    with open(args.awg_users, encoding="utf-8") as handle:
                        running = json.load(handle)
                except (OSError, ValueError):
                    running = None
                if awg and awg != running:
                    print(args.awg_unit)
    except RuntimeError_ as exc:
        print(exc, file=sys.stderr)
        return 1
    except PermissionError as exc:
        print(f"Cannot write {exc.filename}: permission denied.", file=sys.stderr)
        return 77
    except OSError as exc:
        print(f"{exc.filename or ''}: {exc.strerror}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
