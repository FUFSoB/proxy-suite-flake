#!/usr/bin/env python3
"""Turn a WireGuard .conf (e.g. wgcf-profile.conf) into a WARP outbound for sing-box or XRay."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


class ConfigError(ValueError):
    pass


def parse_conf(text: str) -> tuple[dict[str, str], dict[str, str]]:
    """Return the [Interface] section and the first [Peer], keys lowercased."""
    sections: list[tuple[str, dict[str, str]]] = []
    for line in text.splitlines():
        stripped = line.split("#", 1)[0].strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            sections.append((stripped[1:-1].strip().lower(), {}))
        elif "=" in stripped and sections:
            key, value = (part.strip() for part in stripped.split("=", 1))
            sections[-1][1][key.lower()] = value
    interface = next((s for name, s in sections if name == "interface"), None)
    peer = next((s for name, s in sections if name == "peer"), None)
    if interface is None or peer is None:
        raise ConfigError("configuration requires [Interface] and [Peer] sections")
    for section, key in ((interface, "privatekey"), (interface, "address"), (peer, "publickey"), (peer, "endpoint")):
        if not section.get(key):
            raise ConfigError(f"configuration has no {key}")
    return interface, peer


def _split(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def split_endpoint(endpoint: str) -> tuple[str, int]:
    host, sep, port = endpoint.rpartition(":")
    if not sep or not port.isdigit() or not host:
        raise ConfigError(f"endpoint '{endpoint}' is not host:port")
    return host.strip("[]"), int(port)


def build(text: str, backend: str, tag: str, routing_mark: int | None) -> dict[str, Any]:
    interface, peer = parse_conf(text)
    addresses = _split(interface["address"])
    allowed_ips = _split(peer.get("allowedips", "")) or ["0.0.0.0/0", "::/0"]
    mtu = int(interface.get("mtu") or 1280)
    keepalive = int(peer["persistentkeepalive"]) if peer.get("persistentkeepalive") else None
    psk = peer.get("presharedkey")
    host, port = split_endpoint(peer["endpoint"])

    if backend == "xray":
        xray_peer: dict[str, Any] = {
            "publicKey": peer["publickey"],
            "endpoint": peer["endpoint"],
            "allowedIPs": allowed_ips,
        }
        if keepalive is not None:
            xray_peer["keepAlive"] = keepalive
        if psk:
            xray_peer["preSharedKey"] = psk
        outbound: dict[str, Any] = {
            "protocol": "wireguard",
            "tag": tag,
            "settings": {
                "secretKey": interface["privatekey"],
                "address": addresses,
                "peers": [xray_peer],
                "mtu": mtu,
            },
        }
        if routing_mark is not None:
            outbound["streamSettings"] = {"sockopt": {"mark": routing_mark}}
        return outbound

    # sing-box >= 1.11: WireGuard is an endpoint; the start script moves it out of outbounds.
    sb_peer: dict[str, Any] = {
        "address": host,
        "port": port,
        "public_key": peer["publickey"],
        "allowed_ips": allowed_ips,
    }
    if keepalive is not None:
        sb_peer["persistent_keepalive_interval"] = keepalive
    if psk:
        sb_peer["pre_shared_key"] = psk
    endpoint: dict[str, Any] = {
        "type": "wireguard",
        "tag": tag,
        "address": addresses,
        "private_key": interface["privatekey"],
        "mtu": mtu,
        "peers": [sb_peer],
    }
    if routing_mark is not None:
        endpoint["routing_mark"] = routing_mark
    return endpoint


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["sing-box", "xray"], required=True)
    parser.add_argument("--tag", default="warp")
    parser.add_argument("--routing-mark", type=int)
    args = parser.parse_args()
    try:
        print(json.dumps(build(sys.stdin.read(), args.backend, args.tag, args.routing_mark)))
    except (ConfigError, ValueError) as error:
        print(f"proxy-suite: warp: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
