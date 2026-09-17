#!/usr/bin/env python3
"""AmneziaWG server listeners of services.proxy-suite.inbounds.

Keys, preshared keys, tunnel addresses and generated obfuscation live in one state file per
listener, so they survive restarts; users gone from the spec are dropped from it, which
revokes them. Values declared in the spec (key files, addresses, obfuscation fields) win
over the state and are not stored in it. The state is read back by proxy_inbound.py to
render client configs and links.
"""

from __future__ import annotations

import argparse
import fcntl
import ipaddress
import json
import os
import random
import subprocess
import sys
from pathlib import Path
from typing import Any

from amneziawg_config import (
    ConfigError,
    _apply_awg3_mtu_default,
    _set_interface_value,
    encode_vpn_link,
    render_settings,
    transport_implementation,
    write_private,
)

STATE_VERSION = 1
# AWG 1.x fields: every AmneziaWG client understands them.
GENERATED_OBFUSCATION = ("jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4")
# Size of a WireGuard handshake initiation minus a response: S1 + 56 == S2 would make the
# padded messages the same size again.
HANDSHAKE_SIZE_DIFFERENCE = 56


def _random() -> random.Random:
    return random.SystemRandom()


def generate_obfuscation(declared: dict[str, Any], stored: dict[str, Any]) -> dict[str, int]:
    """Generated values for the AWG 1.x fields the spec leaves null.

    Stored values are kept unless they no longer fit around the declared ones.
    """
    rng = _random()
    values = {key: declared[key] for key in GENERATED_OBFUSCATION if declared.get(key) is not None}
    generated: dict[str, int] = {}

    def pick(key: str, valid, make) -> None:
        if key in values:
            return
        current = stored.get(key)
        if not (type(current) is int and valid(current)):
            current = make()
            while not valid(current):
                current = make()
        values[key] = generated[key] = current

    pick("jc", lambda v: 3 <= v <= 10, lambda: rng.randint(3, 10))
    # Junk packets go out ahead of every handshake: kept small, as AmneziaVPN's own are.
    jmax_declared = values.get("jmax") if type(values.get("jmax")) is int else None
    jmin_high = 50 if jmax_declared is None else max(0, min(50, jmax_declared - 1))
    jmin_low = min(8, jmin_high)
    pick("jmin", lambda v: jmin_low <= v <= jmin_high, lambda: rng.randint(jmin_low, jmin_high))
    jmin = values["jmin"] if type(values["jmin"]) is int else 0
    pick("jmax", lambda v: jmin + 8 <= v <= max(jmin + 8, 250), lambda: rng.randint(jmin + 8, max(jmin + 8, 250)))
    pick("s1", lambda v: 15 <= v <= 150, lambda: rng.randint(15, 150))
    s1 = values["s1"] if isinstance(values["s1"], int) else None
    pick(
        "s2",
        lambda v: 15 <= v <= 150 and (s1 is None or s1 + HANDSHAKE_SIZE_DIFFERENCE != v),
        lambda: rng.randint(15, 150),
    )
    for key in ("h1", "h2", "h3", "h4"):
        others = {values[other] for other in ("h1", "h2", "h3", "h4") if other != key and other in values}
        pick(key, lambda v, others=others: 5 <= v <= 2**31 - 1 and v not in others, lambda: rng.randint(5, 2**31 - 1))
    return generated


def _read_key(path: str, what: str) -> str:
    try:
        value = Path(path).read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ConfigError(f"cannot read {what} file '{path}': {exc.strerror}") from None
    if not value or "\n" in value:
        raise ConfigError(f"{what} file '{path}' must hold one non-empty line")
    return value


class Keys:
    """`awg genkey`, `pubkey` and `genpsk`."""

    def __init__(self, awg: str):
        self.awg = awg

    def _run(self, *args: str, stdin: str | None = None) -> str:
        result = subprocess.run(
            [self.awg, *args], input=stdin, capture_output=True, text=True, check=False
        )
        if result.returncode != 0 or not result.stdout.strip():
            raise ConfigError(f"awg {args[0]} failed")
        return result.stdout.strip()

    def private(self) -> str:
        return self._run("genkey")

    def public(self, private: str) -> str:
        return self._run("pubkey", stdin=private + "\n")

    def preshared(self) -> str:
        return self._run("genpsk")


def _host(network: ipaddress._BaseNetwork, offset: int) -> ipaddress._BaseAddress:
    return network.network_address + offset


def allocate_addresses(awg: dict, users: list[dict], stored: dict[str, dict]) -> dict[str, int]:
    """Host offset in the subnet of each user by name: declared, kept, then the lowest free.

    This host has offset 1.
    """
    tag = awg["tag"]
    network = ipaddress.ip_network(awg["subnet"], strict=False)
    last = network.num_addresses - (1 if network.prefixlen < 31 else 0)
    offsets: dict[str, int] = {}
    taken = {1}
    for user in users:
        if user.get("address") is None:
            continue
        address = ipaddress.ip_address(user["address"])
        offset = int(address) - int(network.network_address)
        if address not in network or not 1 < offset < last:
            raise ConfigError(f"listener '{tag}': address {address} of user '{user['name']}' is not a client address in {network}")
        if offset in taken:
            raise ConfigError(f"listener '{tag}': address {address} is taken twice")
        offsets[user["name"]] = offset
        taken.add(offset)
    for user in users:
        name = user["name"]
        offset = stored.get(name, {}).get("offset")
        if name not in offsets and type(offset) is int and 1 < offset < last and offset not in taken:
            offsets[name] = offset
            taken.add(offset)
    free = (offset for offset in range(2, last) if offset not in taken)
    for user in users:
        if user["name"] not in offsets:
            offset = next(free, None)
            if offset is None:
                raise ConfigError(f"listener '{tag}': subnet {network} has no free address for user '{user['name']}'")
            offsets[user["name"]] = offset
            taken.add(offset)
    return offsets


def update_state(listener: dict, state: dict, keys: Keys) -> dict:
    """The state after this spec: generated values filled in, departed users dropped."""
    awg = {**listener["amneziaWg"], "tag": listener["tag"]}
    stored_users = state.get("users", {}) if state.get("version") == STATE_VERSION else {}
    stored_server = state.get("server", {}) if state.get("version") == STATE_VERSION else {}
    stored_obfuscation = state.get("obfuscation", {}) if state.get("version") == STATE_VERSION else {}

    server: dict[str, str] = {}
    if awg.get("privateKeyFile") is not None:
        server["publicKey"] = keys.public(_read_key(awg["privateKeyFile"], "server private key"))
    else:
        private = stored_server.get("privateKey")
        if private and stored_server.get("publicKey"):
            server = {"privateKey": private, "publicKey": stored_server["publicKey"]}
        else:
            private = private or keys.private()
            server = {"privateKey": private, "publicKey": keys.public(private)}

    offsets = allocate_addresses(awg, listener["users"], stored_users)
    users: dict[str, dict] = {}
    for user in listener["users"]:
        name = user["name"]
        stored = stored_users.get(name, {})
        entry: dict[str, Any] = {"offset": offsets[name]}
        if user.get("publicKey") is not None:
            entry["publicKey"] = user["publicKey"]
        elif user.get("privateKeyFile") is not None:
            entry["publicKey"] = keys.public(_read_key(user["privateKeyFile"], f"private key of user '{name}'"))
        else:
            private = stored.get("privateKey") or keys.private()
            entry["privateKey"] = private
            entry["publicKey"] = (
                stored["publicKey"] if stored.get("privateKey") == private and stored.get("publicKey") else keys.public(private)
            )
        # A peer holding its own private key brings its own preshared key, if any.
        if user.get("presharedKeyFile") is None and user.get("publicKey") is None:
            entry["presharedKey"] = stored.get("presharedKey") or keys.preshared()
        users[name] = entry

    obfuscation = generate_obfuscation(awg.get("obfuscation") or {}, stored_obfuscation)
    return {"version": STATE_VERSION, "server": server, "obfuscation": obfuscation, "users": users}


def _obfuscation(awg: dict, state: dict) -> dict[str, Any]:
    declared = {key: value for key, value in (awg.get("obfuscation") or {}).items() if value is not None}
    return {**state.get("obfuscation", {}), **declared}


def _addresses(awg: dict, offset: int, prefix: bool) -> list[str]:
    result = []
    for key in ("subnet", "subnet6"):
        if awg.get(key) is None:
            continue
        network = ipaddress.ip_network(awg[key], strict=False)
        length = network.prefixlen if prefix else network.max_prefixlen
        result.append(f"{_host(network, offset)}/{length}")
    return result


def _user_private_key(user: dict, entry: dict) -> str | None:
    if user.get("privateKeyFile") is not None:
        return _read_key(user["privateKeyFile"], f"private key of user '{user['name']}'")
    return entry.get("privateKey")


def _user_preshared_key(user: dict, entry: dict) -> str | None:
    if user.get("presharedKeyFile") is not None:
        return _read_key(user["presharedKeyFile"], f"preshared key of user '{user['name']}'")
    return entry.get("presharedKey")


def render_server_config(listener: dict, state: dict) -> str:
    awg = listener["amneziaWg"]
    peers = []
    for user in listener["users"]:
        entry = state["users"][user["name"]]
        peer: dict[str, Any] = {
            "publicKey": entry["publicKey"],
            "allowedIPs": _addresses(awg, entry["offset"], prefix=False),
        }
        preshared = _user_preshared_key(user, entry)
        if preshared is not None:
            peer["presharedKey"] = preshared
        peers.append(peer)
    settings: dict[str, Any] = {
        "addresses": _addresses(awg, 1, prefix=True),
        "listenPort": listener["port"],
        "mtu": awg.get("mtu"),
        # Traffic is steered by proxy-suite's own rules, not by AllowedIPs routes.
        "table": "off",
        "obfuscation": _obfuscation(awg, state),
        "peers": peers,
    }
    if awg.get("privateKeyFile") is not None:
        settings["privateKeyFile"] = awg["privateKeyFile"]
    else:
        settings["privateKey"] = state["server"]["privateKey"]
    config = _apply_awg3_mtu_default(render_settings(settings))
    if awg.get("fwmark") is not None:
        # Replies to clients get past TUN and TProxy capture, as an outbound interface's packets.
        config = _set_interface_value(config, "FwMark", str(awg["fwmark"]))
    return config


def render_client_config(listener: dict, state: dict, user: dict, server_address: str, port: int) -> str | None:
    """A user's .conf, or None for a peer that keeps its private key."""
    awg = listener["amneziaWg"]
    entry = state["users"][user["name"]]
    private = _user_private_key(user, entry)
    if private is None:
        return None
    host = f"[{server_address}]" if ":" in server_address else server_address
    peer: dict[str, Any] = {
        "publicKey": state["server"]["publicKey"],
        "allowedIPs": awg["clientAllowedIPs"],
        "endpoint": f"{host}:{port}",
        "persistentKeepalive": awg.get("persistentKeepalive"),
    }
    preshared = _user_preshared_key(user, entry)
    if preshared is not None:
        peer["presharedKey"] = preshared
    obfuscation = _obfuscation(awg, state)
    # The header-protection key is the server's secret too; the client gets its value.
    settings = {
        "addresses": _addresses(awg, entry["offset"], prefix=False),
        "dns": awg.get("dns") or [],
        "privateKey": private,
        "mtu": awg.get("mtu"),
        "obfuscation": obfuscation,
        "peers": [peer],
    }
    return _apply_awg3_mtu_default(render_settings(settings))


def client_entries(listener: dict, server_address: str, port: int) -> list[dict]:
    """{user, config, link} for each user with a config, from the prepared state.

    Nothing when the state is missing: the AmneziaWG unit has not prepared it yet.
    """
    path = listener["amneziaWg"]["stateFile"]
    try:
        state = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"proxy-suite: listener '{listener['tag']}' has no AmneziaWG state yet; no links", file=sys.stderr)
        return []
    entries = []
    for user in listener["users"]:
        if user["name"] not in state.get("users", {}):
            continue
        config = render_client_config(listener, state, user, server_address, port)
        if config is None:
            continue
        link = encode_vpn_link(
            config,
            server_address,
            f"{listener['tag']} ({user['name']})",
            state["users"][user["name"]].get("publicKey"),
        )
        entries.append({"user": user["name"], "config": config, "link": link})
    return entries


def prepare(spec: dict, awg_binary: str, runtime_dir: str) -> list[dict]:
    """Update every AmneziaWG listener's state and write its server config.

    Returns {tag, interface, config, implementation} for each; implementation is what
    awg-quick should run the interface with, "auto" or "userspace".
    """
    keys = Keys(awg_binary)
    prepared = []
    for listener in spec["listeners"]:
        if listener.get("type") != "amneziawg":
            continue
        awg = listener["amneziaWg"]
        state_path = Path(awg["stateFile"])
        state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(state_path.parent / ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                state = json.loads(state_path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                state = {}
            state = update_state(listener, state, keys)
            write_private(str(state_path), json.dumps(state, indent=2) + "\n")
        config_path = os.path.join(runtime_dir, f"{awg['interfaceName']}.conf")
        config = render_server_config(listener, state)
        write_private(config_path, config)
        prepared.append(
            {
                "tag": listener["tag"],
                "interface": awg["interfaceName"],
                "config": config_path,
                "implementation": transport_implementation(config),
            }
        )
    return prepared


def peer_names(spec: dict) -> dict[str, dict]:
    """By interface: the listener's tag and its users' names by public key."""
    result: dict[str, dict] = {}
    for listener in spec["listeners"]:
        if listener.get("type") != "amneziawg":
            continue
        awg = listener["amneziaWg"]
        try:
            state = json.loads(Path(awg["stateFile"]).read_text(encoding="utf-8"))
        except FileNotFoundError:
            continue
        result[awg["interfaceName"]] = {
            "tag": listener["tag"],
            "users": {entry["publicKey"]: name for name, entry in state.get("users", {}).items()},
        }
    return result


def parse_dump(dump: str) -> list[dict]:
    """Peers of `awg show <interface> dump`; its first line is the interface itself."""
    peers = []
    for line in dump.splitlines()[1:]:
        fields = line.split("\t")
        if len(fields) < 7:
            continue
        endpoint = fields[2]
        peers.append(
            {
                "key": fields[0],
                "endpoint": None if endpoint == "(none)" else endpoint,
                "handshake": int(fields[4]),
                "rx": int(fields[5]),
                "tx": int(fields[6]),
            }
        )
    return peers


def peer_counters(spec: dict, awg_binary: str) -> list[dict]:
    """Every known peer's raw transfer counters, latest handshake and endpoint, with its
    listener and user; interfaces that are down are left out."""
    result = []
    for interface, listener in peer_names(spec).items():
        completed = subprocess.run(
            [awg_binary, "show", interface, "dump"], capture_output=True, text=True, check=False
        )
        if completed.returncode != 0:
            continue
        for peer in parse_dump(completed.stdout):
            user = listener["users"].get(peer["key"])
            if user is not None:
                result.append({**peer, "interface": interface, "tag": listener["tag"], "user": user})
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="update the state and write the server configs")
    prepare_parser.add_argument("--spec", required=True)
    prepare_parser.add_argument("--awg", required=True, help="path to the awg tool")
    prepare_parser.add_argument("--runtime-dir", required=True)
    peers_parser = commands.add_parser("peers", help="print every peer's counters, with its listener and user")
    peers_parser.add_argument("--spec", required=True)
    peers_parser.add_argument("--awg", required=True, help="path to the awg tool")
    args = parser.parse_args()
    with open(args.spec, encoding="utf-8") as handle:
        spec = json.load(handle)
    try:
        if args.command == "prepare":
            # One line per listener, for the start script to read.
            for entry in prepare(spec, args.awg, args.runtime_dir):
                print(entry["interface"], entry["implementation"], entry["config"])
        else:
            print(json.dumps(peer_counters(spec, args.awg)))
    except (ConfigError, ValueError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
