#!/usr/bin/env python3
"""Prepare a private AmneziaWG configuration for a proxy-suite profile."""

from __future__ import annotations

import argparse
import base64
import binascii
import ipaddress
import json
import os
import re
import socket
import tempfile
import zlib
from pathlib import Path
from typing import Any


MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_DECOMPRESSED_BYTES = 8 * 1024 * 1024
AWG3_SAFE_DEFAULT_MTU = 1280
FORBIDDEN_WG_QUICK_KEYS = {"preup", "postup", "predown", "postdown", "saveconfig"}
AWG_PROTOCOL_KEYS = {"awg", "amnezia-awg", "amnezia-awg2", "amnezia-awg3"}
AWG3_INTERFACE_KEYS = {
    "headerprotectionkey",
    "contentpaddingaddition",
    "rekeyaftertime",
    "rekeytimeout",
    "rejectaftertime",
    "keepalivetimeout",
    "maxhandshakeattempts",
    "randomtrailers",
    "disablecookies",
}
VPN_INTERFACE_FIELDS = {
    "jc": "Jc",
    "jmin": "Jmin",
    "jmax": "Jmax",
    "s1": "S1",
    "s2": "S2",
    "s3": "S3",
    "s4": "S4",
    "h1": "H1",
    "h2": "H2",
    "h3": "H3",
    "h4": "H4",
    "i1": "I1",
    "i2": "I2",
    "i3": "I3",
    "i4": "I4",
    "i5": "I5",
    "headerprotectionkey": "HeaderProtectionKey",
    "contentpaddingaddition": "ContentPaddingAddition",
    "rekeyaftertime": "RekeyAfterTime",
    "rekeytimeout": "RekeyTimeout",
    "rejectaftertime": "RejectAfterTime",
    "keepalivetimeout": "KeepaliveTimeout",
    "maxhandshakeattempts": "MaxHandshakeAttempts",
    "randomtrailers": "RandomTrailers",
    "disablecookies": "DisableCookies",
}


class ConfigError(ValueError):
    pass


def _read_limited(path: str) -> str:
    with Path(path).open("rb") as handle:
        data = handle.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise ConfigError(f"input exceeds {MAX_INPUT_BYTES} bytes")
    return data.decode("utf-8")


def _decode_json_value(value: Any, label: str) -> dict[str, Any]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise ConfigError(f"invalid {label} JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ConfigError(f"invalid {label}: expected an object")
    return value


def decode_vpn_link(link: str) -> dict[str, Any]:
    link = link.strip()
    if not link.startswith("vpn://"):
        raise ConfigError("expected a self-contained vpn:// link")
    encoded = link[len("vpn://") :]
    if not encoded or re.fullmatch(r"[A-Za-z0-9_-]+={0,2}", encoded) is None:
        raise ConfigError("unsupported vpn:// link; API-backed text keys are not supported")
    try:
        raw = base64.b64decode(
            encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True
        )
    except (binascii.Error, ValueError) as exc:
        raise ConfigError(
            "unsupported vpn:// link; expected embedded base64 data, not an API-backed text key"
        ) from exc
    if len(raw) > MAX_INPUT_BYTES:
        raise ConfigError(f"vpn:// payload exceeds {MAX_INPUT_BYTES} bytes")

    decoded = raw
    if len(raw) >= 5:
        expected_size = int.from_bytes(raw[:4], "big")
        try:
            decompressor = zlib.decompressobj()
            candidate = decompressor.decompress(raw[4:], MAX_DECOMPRESSED_BYTES + 1)
            if len(candidate) > MAX_DECOMPRESSED_BYTES or decompressor.unconsumed_tail:
                raise ConfigError(
                    f"decompressed vpn:// payload exceeds {MAX_DECOMPRESSED_BYTES} bytes"
                )
            candidate += decompressor.flush(MAX_DECOMPRESSED_BYTES + 1 - len(candidate))
            if decompressor.eof:
                if len(candidate) > MAX_DECOMPRESSED_BYTES:
                    raise ConfigError(
                        f"decompressed vpn:// payload exceeds {MAX_DECOMPRESSED_BYTES} bytes"
                    )
                if len(candidate) != expected_size:
                    raise ConfigError("vpn:// qCompress length header does not match payload")
                decoded = candidate
        except zlib.error:
            pass

    if len(decoded) > MAX_DECOMPRESSED_BYTES:
        raise ConfigError(f"decoded vpn:// payload exceeds {MAX_DECOMPRESSED_BYTES} bytes")
    # Amnezia clients also export a compact direct form where the payload is
    # simply the URL-safe-base64 encoded .conf text.  Normalize it to the
    # same container shape as the JSON export so selection and validation stay
    # identical.  This is deliberately limited to a complete AWG config and
    # never attempts to resolve short/API-backed keys.
    try:
        direct_config = decoded.decode("utf-8")
    except UnicodeDecodeError:
        direct_config = ""
    if direct_config.lstrip().startswith("[Interface]") and "[Peer]" in direct_config:
        return {
            "defaultContainer": "amnezia-awg",
            "containers": [
                {
                    "container": "amnezia-awg",
                    "config": direct_config,
                }
            ],
        }
    try:
        result = json.loads(decoded.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConfigError(
            "unsupported vpn:// link; expected embedded qCompress/base64 JSON, not an API-backed key"
        ) from exc
    if not isinstance(result, dict):
        raise ConfigError("invalid vpn:// configuration: expected a JSON object")
    return result


def encode_vpn_link(
    config: str,
    host: str,
    description: str,
    client_public_key: str | None = None,
) -> str:
    """A self-contained vpn:// link carrying a client .conf, as AmneziaVPN exports one.

    The payload is qCompress'd JSON (a 4-byte big-endian length, then zlib), in URL-safe
    base64. Everything but host and the client's public key is read from the config.
    """
    interface = {key: value for name, pairs in conf_sections(config) if name == "interface" for key, value in pairs}
    peer = {key: value for name, pairs in conf_sections(config) if name == "peer" for key, value in pairs}
    endpoint = peer.get("endpoint", "")
    port = endpoint.rsplit(":", 1)[1] if ":" in endpoint else ""
    dns = [item.strip() for item in interface.get("dns", "").split(",") if item.strip()]
    last: dict[str, Any] = {
        "config": config,
        "hostName": host,
        "port": int(port) if port.isdigit() else port,
        "client_ip": interface.get("address", "").split(",")[0].strip().split("/")[0],
        "client_priv_key": interface.get("privatekey", ""),
        "server_pub_key": peer.get("publickey", ""),
        "psk_key": peer.get("presharedkey", ""),
        "allowed_ips": [item.strip() for item in peer.get("allowedips", "").split(",") if item.strip()],
        "persistent_keep_alive": peer.get("persistentkeepalive", ""),
    }
    if client_public_key:
        last["client_pub_key"] = client_public_key
    if interface.get("mtu"):
        last["mtu"] = interface["mtu"]
    protocol: dict[str, Any] = {}
    for normalized, key in VPN_INTERFACE_FIELDS.items():
        if normalized in interface:
            last[key] = interface[normalized]
            protocol[key] = interface[normalized]
    protocol.update(
        {
            "last_config": json.dumps(last, separators=(",", ":")),
            "port": str(port),
            "transport_proto": "udp",
            "isThirdPartyConfig": True,
        }
    )
    data = {
        "containers": [{"container": "amnezia-awg", "awg": protocol}],
        "defaultContainer": "amnezia-awg",
        "description": description,
        "hostName": host,
    }
    if dns:
        data["dns1"] = dns[0]
    if len(dns) > 1:
        data["dns2"] = dns[1]
    payload = json.dumps(data, separators=(",", ":")).encode("utf-8")
    compressed = len(payload).to_bytes(4, "big") + zlib.compress(payload, 8)
    return "vpn://" + base64.urlsafe_b64encode(compressed).decode("ascii").rstrip("=")


def _candidate_payload(value: Any, key: str) -> tuple[dict[str, Any], str]:
    payload = _decode_json_value(value, f"{key} protocol")
    last = _decode_json_value(payload.get("last_config", payload), f"{key}.last_config")
    config = last.get("config")
    if not isinstance(config, str) or "[Interface]" not in config or "[Peer]" not in config:
        raise ConfigError(f"{key} candidate does not contain an AmneziaWG config")
    return last, config


def extract_vpn_config(data: dict[str, Any], requested_container: str | None = None) -> str:
    containers = data.get("containers")
    if not isinstance(containers, list):
        raise ConfigError("vpn:// configuration has no containers list")

    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(containers):
        if not isinstance(item, dict):
            continue
        container_id = item.get("container") if isinstance(item.get("container"), str) else ""
        protocols = [(key, item[key]) for key in item if key.lower() in AWG_PROTOCOL_KEYS]
        if container_id.lower() in AWG_PROTOCOL_KEYS and not protocols and (
            "last_config" in item or "config" in item
        ):
            protocols = [(container_id, item)]
        for key, value in protocols:
            try:
                last, config = _candidate_payload(value, key)
            except ConfigError:
                continue
            candidates.append(
                {
                    "id": container_id or key,
                    "key": key,
                    "index": index,
                    "last": last,
                    "config": config,
                }
            )

    if not candidates:
        raise ConfigError("vpn:// configuration contains no AmneziaWG client config")

    selected: list[dict[str, Any]]
    if requested_container:
        requested_lower = requested_container.lower()
        selected = [
            candidate
            for candidate in candidates
            if requested_lower
            in {str(candidate["id"]).lower(), str(candidate["key"]).lower()}
        ]
        if len(selected) != 1:
            raise ConfigError(
                f"vpnContainer '{requested_container}' matched {len(selected)} AmneziaWG configs"
            )
    else:
        default_container = data.get("defaultContainer")
        default_matches = [
            candidate
            for candidate in candidates
            if isinstance(default_container, str)
            and default_container.lower()
            in {str(candidate["id"]).lower(), str(candidate["key"]).lower()}
        ]
        if len(default_matches) == 1:
            selected = default_matches
        elif len(candidates) == 1:
            selected = candidates
        else:
            choices = ", ".join(str(candidate["id"]) for candidate in candidates)
            raise ConfigError(
                f"vpn:// configuration contains multiple AmneziaWG configs ({choices}); set vpnContainer"
            )

    candidate = selected[0]
    config = candidate["config"]
    dns1 = data.get("dns1") if isinstance(data.get("dns1"), str) else ""
    dns2 = data.get("dns2") if isinstance(data.get("dns2"), str) else ""
    if dns1:
        config = config.replace("$PRIMARY_DNS", dns1)
    if dns2:
        config = config.replace("$SECONDARY_DNS", dns2)
    if "$PRIMARY_DNS" in config or "$SECONDARY_DNS" in config:
        raise ConfigError("vpn:// configuration contains unresolved DNS placeholders")

    last = candidate["last"]
    normalized_last = {
        re.sub(r"[^a-z0-9]", "", str(key).lower()): value for key, value in last.items()
    }
    for normalized, config_key in VPN_INTERFACE_FIELDS.items():
        value = normalized_last.get(normalized)
        if value not in (None, ""):
            if normalized in {"randomtrailers", "disablecookies"} and isinstance(value, bool):
                value = "on" if value else "off"
            config = _set_interface_value(config, config_key, str(value))
    if last.get("mtu") not in (None, ""):
        config = _set_interface_value(config, "MTU", str(last["mtu"]))
    if last.get("port") not in (None, ""):
        config = _set_interface_value(config, "ListenPort", str(last["port"]))
    return _apply_awg3_mtu_default(config)


def _set_interface_value(config: str, key: str, value: str) -> str:
    lines = config.splitlines()
    interface_index = next(
        (index for index, line in enumerate(lines) if line.strip().lower() == "[interface]"),
        None,
    )
    if interface_index is None:
        raise ConfigError("configuration has no [Interface] section")
    end = next(
        (
            index
            for index in range(interface_index + 1, len(lines))
            if lines[index].strip().startswith("[")
        ),
        len(lines),
    )
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=", re.IGNORECASE)
    for index in range(interface_index + 1, end):
        if pattern.match(lines[index]):
            lines[index] = f"{key} = {value}"
            break
    else:
        lines.insert(end, f"{key} = {value}")
    return "\n".join(lines) + "\n"


def _remove_interface_key(config: str, key: str) -> str:
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=", re.IGNORECASE)
    lines: list[str] = []
    in_interface = False
    for line in config.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_interface = stripped.lower() == "[interface]"
        if not (in_interface and pattern.match(line)):
            lines.append(line)
    return "\n".join(lines) + "\n"


def as_outbound(config: str, fwmark: int) -> str:
    """Keep the host's routes and resolver: the proxy binds to the interface instead.

    The mark lets the tunnel's own packets past TUN and TProxy capture.
    """
    config = _remove_interface_key(config, "DNS")
    config = _set_interface_value(config, "Table", "off")
    return _set_interface_value(config, "FwMark", str(fwmark))


ENDPOINT_LINE = re.compile(r"^(\s*Endpoint\s*=\s*)(\S+):(\d+)\s*$", re.IGNORECASE | re.MULTILINE)


def resolve_endpoints(config: str) -> str:
    """Endpoint names looked up here, by this process, as awg would; one that does not resolve is left."""

    def resolve(match: re.Match[str]) -> str:
        prefix, host, port = match.groups()
        try:
            ipaddress.ip_address(host.strip("[]"))
            return match.group(0)
        except ValueError:
            pass
        try:
            family, *_, address = socket.getaddrinfo(host, int(port), type=socket.SOCK_DGRAM, flags=socket.AI_ADDRCONFIG)[0]
        except (OSError, UnicodeError):
            return match.group(0)
        ip = f"[{address[0]}]" if family == socket.AF_INET6 else address[0]
        return f"{prefix}{ip}:{port}"

    return ENDPOINT_LINE.sub(resolve, config)


# Read once by wireproxy: repeated lines are joined into one list.
WIREPROXY_LIST_KEYS = {"address", "dns", "allowedips"}
# wg-quick's, which wireproxy has no use for.
WIREPROXY_DROPPED_KEYS = FORBIDDEN_WG_QUICK_KEYS | {"table", "fwmark"}


def as_wireproxy(config: str, socks_address: str, fwmark: int | None = None) -> str:
    """A wireproxy configuration: the profile, served as a SOCKS5 listener on socks_address.

    With fwmark, the tunnel's own packets are marked, to get past TUN and TProxy capture.
    """
    lines: list[str] = []
    for name, pairs in conf_sections(config):
        if name not in {"interface", "peer"}:
            continue
        if lines:
            lines.append("")
        lines.append(f"[{name.capitalize()}]")
        lists: dict[str, list[str]] = {}
        for key, value in pairs:
            if key in WIREPROXY_DROPPED_KEYS:
                continue
            if key in WIREPROXY_LIST_KEYS:
                if key not in lists:
                    lists[key] = []
                    lines.append(key)
                lists[key].extend(item.strip() for item in value.split(",") if item.strip())
            else:
                lines.append(f"{key} = {value}")
        lines = [f"{line} = {','.join(lists[line])}" if line in lists else line for line in lines]
        if name == "interface" and fwmark is not None:
            lines.append(f"fwmark = {fwmark}")
    lines.extend(["", "[Socks5]", f"BindAddress = {socks_address}"])
    return "\n".join(lines) + "\n"


def conf_sections(config: str) -> list[tuple[str, list[tuple[str, str]]]]:
    """Each [Section] of a WireGuard .conf, lowercased, with its key = value lines in order.

    Keys are lowercased; comments (# or ;) and lines outside a section are dropped.
    """
    sections: list[tuple[str, list[tuple[str, str]]]] = []
    for line in config.splitlines():
        stripped = line.split("#", 1)[0].split(";", 1)[0].strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            sections.append((stripped[1:-1].strip().lower(), []))
        elif "=" in stripped and sections:
            key, value = (part.strip() for part in stripped.split("=", 1))
            sections[-1][1].append((key.lower(), value))
    return sections


def section_values(config: str, section: str, key: str) -> list[str]:
    """Every value of `key` in every `section`, in file order."""
    return [
        value
        for name, pairs in conf_sections(config)
        if name == section
        for found, value in pairs
        if found == key
    ]


def _interface_keys(config: str) -> set[str]:
    keys: set[str] = set()
    for name, pairs in conf_sections(config):
        if name == "interface":
            keys.update(re.sub(r"[^a-z0-9]", "", key) for key, _ in pairs)
    return keys


def _apply_awg3_mtu_default(config: str) -> str:
    keys = _interface_keys(config)
    if "mtu" in keys or not (AWG3_INTERFACE_KEYS & keys):
        return config
    # Amnezia exports rely on the official client's platform MTU default when
    # they omit MTU. awg-quick would instead choose 1420, which is unsafe once
    # AWG 3 per-packet padding is enabled and commonly black-holes larger TLS
    # handshake/data packets. Match the conservative mobile client default.
    return _set_interface_value(config, "MTU", str(AWG3_SAFE_DEFAULT_MTU))


def _secret_value(inline: Any, path: Any, label: str) -> str:
    values = int(inline is not None) + int(path is not None)
    if values != 1:
        raise ConfigError(f"set exactly one of {label} or {label}File")
    value = str(inline) if inline is not None else _read_limited(str(path)).strip()
    if not value or "\n" in value or "\r" in value:
        raise ConfigError(f"{label} must be one non-empty line")
    return value


OBFUSCATION_UNSIGNED_FIELDS = {"jc", "jmin", "jmax", "s1", "s2", "s3", "s4"}
OBFUSCATION_RANGE_FIELDS = {
    "h1",
    "h2",
    "h3",
    "h4",
    "contentPaddingAddition",
    "rekeyAfterTime",
    "rekeyTimeout",
    "rejectAfterTime",
    "keepaliveTimeout",
    "maxHandshakeAttempts",
}
OBFUSCATION_STRING_FIELDS = {"i1", "i2", "i3", "i4", "i5", "headerProtectionKey"}
OBFUSCATION_BOOLEAN_FIELDS = {"randomTrailers", "disableCookies"}


def _unique_secret_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            # Even a key can contain secret input; do not echo it.
            raise ConfigError("obfuscationFile contains duplicate JSON keys")
        result[key] = value
    return result


def _reject_secret_constant(value: str) -> Any:
    raise ConfigError("obfuscationFile contains an invalid JSON constant")


def _merge_obfuscation(settings: dict[str, Any]) -> dict[str, Any]:
    public = settings.get("obfuscation", {})
    if not isinstance(public, dict):
        raise ConfigError("obfuscation must be an object")
    path = settings.get("obfuscationFile")
    if path is None:
        return public
    try:
        secret = json.loads(
            _read_limited(str(path)),
            object_pairs_hook=_unique_secret_object,
            parse_constant=_reject_secret_constant,
        )
    except (OSError, UnicodeError, ValueError, RecursionError) as exc:
        # Decoder errors and OS exceptions can include input excerpts or paths.
        message = (
            str(exc) if isinstance(exc, ConfigError)
            else "cannot read or decode obfuscationFile"
        )
        raise ConfigError(message) from None
    if not isinstance(secret, dict):
        raise ConfigError("obfuscationFile must contain a JSON object")

    merged = dict(public)
    known = (
        OBFUSCATION_UNSIGNED_FIELDS | OBFUSCATION_RANGE_FIELDS
        | OBFUSCATION_STRING_FIELDS | OBFUSCATION_BOOLEAN_FIELDS
    )
    for key, value in secret.items():
        if key not in known:
            raise ConfigError("obfuscationFile contains an unsupported field")
        if value is None:
            continue
        if public.get(key) is not None or (
            key == "headerProtectionKey" and public.get("headerProtectionKeyFile") is not None
        ):
            raise ConfigError(f"obfuscationFile field '{key}' has multiple sources")
        unsigned = type(value) is int and value >= 0
        if key in OBFUSCATION_UNSIGNED_FIELDS:
            valid = unsigned
        elif key in OBFUSCATION_RANGE_FIELDS:
            valid = unsigned or (
                isinstance(value, str)
                and re.fullmatch(r"([0-9]+|[0-9]+-[0-9]+|\(off\))", value) is not None
            )
        elif key in OBFUSCATION_BOOLEAN_FIELDS:
            valid = type(value) is bool
        else:
            valid = (
                isinstance(value, str)
                and bool(value.strip())
                and value.splitlines() == [value]
                and "\x00" not in value
            )
            if valid:
                try:
                    value.encode("utf-8")
                except UnicodeEncodeError:
                    valid = False
        if not valid:
            raise ConfigError(f"obfuscationFile field '{key}' has an invalid value")
        merged[key] = value
    return merged


def render_settings(settings: dict[str, Any]) -> str:
    addresses = settings.get("addresses", [])
    peers = settings.get("peers", [])
    if not isinstance(addresses, list) or not addresses:
        raise ConfigError("declarative settings require at least one address")
    if not isinstance(peers, list) or not peers:
        raise ConfigError("declarative settings require at least one peer")

    lines = ["[Interface]"]
    private_key = _secret_value(
        settings.get("privateKey"), settings.get("privateKeyFile"), "privateKey"
    )
    lines.append(f"PrivateKey = {private_key}")
    for address in addresses:
        lines.append(f"Address = {address}")
    dns = settings.get("dns", [])
    if dns:
        lines.append(f"DNS = {','.join(str(value) for value in dns)}")
    field_map = {
        "listenPort": "ListenPort",
        "mtu": "MTU",
        "table": "Table",
    }
    for source, target in field_map.items():
        if settings.get(source) is not None:
            lines.append(f"{target} = {settings[source]}")

    obfuscation = _merge_obfuscation(settings)
    # Option names are the config keys in camelCase; the key comes last, from its secret.
    values = {key.lower(): value for key, value in obfuscation.items()}
    for normalized, target in VPN_INTERFACE_FIELDS.items():
        value = values.get(normalized)
        if normalized == "headerprotectionkey" or value is None:
            continue
        if isinstance(value, bool):
            value = "on" if value else "off"
        lines.append(f"{target} = {value}")
    if obfuscation.get("headerProtectionKey") is not None or obfuscation.get(
        "headerProtectionKeyFile"
    ) is not None:
        value = _secret_value(
            obfuscation.get("headerProtectionKey"),
            obfuscation.get("headerProtectionKeyFile"),
            "headerProtectionKey",
        )
        lines.append(f"HeaderProtectionKey = {value}")

    for peer in peers:
        if not isinstance(peer, dict):
            raise ConfigError("peer must be an object")
        public_key = peer.get("publicKey")
        allowed_ips = peer.get("allowedIPs", [])
        if not public_key or not allowed_ips:
            raise ConfigError("each peer requires publicKey and allowedIPs")
        lines.extend(["", "[Peer]", f"PublicKey = {public_key}"])
        if peer.get("presharedKey") is not None or peer.get("presharedKeyFile") is not None:
            value = _secret_value(
                peer.get("presharedKey"), peer.get("presharedKeyFile"), "presharedKey"
            )
            lines.append(f"PresharedKey = {value}")
        lines.append(f"AllowedIPs = {','.join(str(value) for value in allowed_ips)}")
        if peer.get("endpoint") is not None:
            lines.append(f"Endpoint = {peer['endpoint']}")
        if peer.get("persistentKeepalive") is not None:
            lines.append(f"PersistentKeepalive = {peer['persistentKeepalive']}")
        if peer.get("advancedSecurity") is not None:
            lines.append(
                f"AdvancedSecurity = {'on' if peer['advancedSecurity'] else 'off'}"
            )
    return "\n".join(lines) + "\n"


def validate_config(config: str, allow_hooks: bool = False) -> None:
    lowered = config.lower()
    if "[interface]" not in lowered or "[peer]" not in lowered:
        raise ConfigError("configuration requires [Interface] and [Peer] sections")
    if not allow_hooks:
        for line in config.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", ";")) or "=" not in stripped:
                continue
            key = stripped.split("=", 1)[0].strip().lower()
            if key in FORBIDDEN_WG_QUICK_KEYS:
                raise ConfigError(
                    f"configuration contains privileged wg-quick directive '{key}'; "
                    "set allowConfigHooks = true only for trusted input"
                )


def probe_address(config: str) -> str:
    """Return an address covered by a peer route without exposing credentials."""
    networks: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []
    for value in section_values(config, "peer", "allowedips"):
        for item in value.split(","):
            try:
                networks.append(ipaddress.ip_network(item.strip(), strict=False))
            except ValueError:
                continue

    preferred = [ipaddress.ip_address("1.1.1.1"), ipaddress.ip_address("2606:4700:4700::1111")]
    for address in preferred:
        if any(address in network for network in networks):
            return str(address)
    for network in networks:
        if network.num_addresses == 1:
            return str(network.network_address)
        return str(network.network_address + 1)
    raise ConfigError("configuration has no usable peer AllowedIPs for a startup handshake probe")


def transport_implementation(config: str) -> str:
    """Select userspace for the upstream RandomTrailers/ranged-header defect."""
    trailers = section_values(config, "interface", "randomtrailers")
    random_trailers = bool(trailers) and trailers[-1].lower() in {"on", "true", "yes", "1"}
    ranged_handshake_header = any(
        re.fullmatch(r"[0-9]+\s*-\s*[0-9]+", value) is not None
        for key in ("h1", "h2", "h3")
        for value in section_values(config, "interface", key)
    )
    return "userspace" if random_trailers and ranged_handshake_header else "auto"


def rekey_after_time(config: str) -> int:
    """Longest wait between rekeys, in seconds; 0 when rekeying is off."""
    values = section_values(config, "interface", "rekeyaftertime")
    if not values:
        return 120
    if values[-1] == "(off)":
        return 0
    return int(values[-1].split("-")[-1])


def prepare(manifest: dict[str, Any]) -> str:
    kind = manifest.get("kind")
    if kind == "configFile":
        config = _read_limited(str(manifest["path"]))
    elif kind in {"vpnFile", "vpn"}:
        link = _read_limited(str(manifest["path"]))
        config = extract_vpn_config(decode_vpn_link(link), manifest.get("vpnContainer"))
    elif kind == "settings":
        config = render_settings(_decode_json_value(manifest.get("settings"), "settings"))
    else:
        raise ConfigError(f"unsupported manifest kind '{kind}'")
    config = _apply_awg3_mtu_default(config)
    validate_config(config, bool(manifest.get("allowConfigHooks", False)))
    return config


def write_private(path: str, content: str) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest")
    parser.add_argument("--config", metavar="CONFIG", help="render a .conf file, as a configFile manifest")
    parser.add_argument("--output")
    parser.add_argument(
        "--outbound-fwmark",
        type=int,
        metavar="MARK",
        help="render for an outbound-only interface: no routes or DNS, packets marked MARK",
    )
    parser.add_argument(
        "--wireproxy",
        metavar="ADDRESS",
        help="render for wireproxy, as a SOCKS5 listener on ADDRESS (packets marked with --outbound-fwmark)",
    )
    parser.add_argument(
        "--fwmark",
        type=int,
        metavar="MARK",
        help="render a global profile whose own packets carry MARK (awg-quick routes it with table MARK)",
    )
    parser.add_argument(
        "--resolve-endpoints",
        action="store_true",
        help="write Endpoint names as the addresses they resolve to here",
    )
    parser.add_argument(
        "--inspect",
        metavar="CONFIG",
        help="print the transport implementation, a probe address and the rekey interval",
    )
    args = parser.parse_args()
    try:
        if args.inspect is not None:
            if args.manifest is not None or args.config is not None or args.output is not None:
                raise ConfigError("--inspect cannot be combined with rendering options")
            config = _read_limited(args.inspect)
            print(transport_implementation(config), probe_address(config), rekey_after_time(config))
            return 0
        if (args.manifest is None) == (args.config is None) or args.output is None:
            raise ConfigError(
                "--output and one of --manifest or --config are required when rendering a configuration"
            )
        if args.config is not None:
            manifest = {"kind": "configFile", "path": args.config}
        else:
            manifest = json.loads(_read_limited(args.manifest))
        if not isinstance(manifest, dict):
            raise ConfigError("manifest must be a JSON object")
        config = prepare(manifest)
        if args.wireproxy is not None:
            config = as_wireproxy(config, args.wireproxy, args.outbound_fwmark)
        elif args.outbound_fwmark is not None:
            config = as_outbound(config, args.outbound_fwmark)
        elif args.fwmark is not None:
            config = _set_interface_value(config, "FwMark", str(args.fwmark))
        if args.resolve_endpoints:
            config = resolve_endpoints(config)
        write_private(args.output, config)
    except (ConfigError, KeyError, OSError, json.JSONDecodeError) as exc:
        parser.exit(1, f"amneziawg-config: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
