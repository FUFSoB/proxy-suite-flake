#!/usr/bin/env python3
"""Turn a WireGuard .conf (e.g. wgcf-profile.conf) into a sing-box WireGuard endpoint for WARP."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from amneziawg_config import ConfigError, conf_sections


def parse_conf(text: str) -> tuple[dict[str, str], dict[str, str]]:
    """Return the [Interface] section and the first [Peer], keys lowercased."""
    sections = conf_sections(text)
    interface = next((dict(pairs) for name, pairs in sections if name == "interface"), None)
    peer = next((dict(pairs) for name, pairs in sections if name == "peer"), None)
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


def build(text: str, tag: str, routing_mark: int | None) -> dict[str, Any]:
    interface, peer = parse_conf(text)
    host, port = split_endpoint(peer["endpoint"])
    sb_peer: dict[str, Any] = {
        "address": host,
        "port": port,
        "public_key": peer["publickey"],
        "allowed_ips": _split(peer.get("allowedips", "")) or ["0.0.0.0/0", "::/0"],
    }
    if peer.get("persistentkeepalive"):
        # AWG 3 profiles give a range ("25-35"); sing-box takes one value.
        sb_peer["persistent_keepalive_interval"] = int(peer["persistentkeepalive"].split("-")[0])
    if peer.get("presharedkey"):
        sb_peer["pre_shared_key"] = peer["presharedkey"]
    endpoint: dict[str, Any] = {
        "type": "wireguard",
        "tag": tag,
        "address": _split(interface["address"]),
        "private_key": interface["privatekey"],
        "mtu": int(interface.get("mtu") or 1280),
        "peers": [sb_peer],
    }
    if routing_mark is not None:
        endpoint["routing_mark"] = routing_mark
    return endpoint


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="warp")
    parser.add_argument("--routing-mark", type=int)
    args = parser.parse_args()
    try:
        print(json.dumps(build(sys.stdin.read(), args.tag, args.routing_mark)))
    except ValueError as error:
        print(f"proxy-suite: warp: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
