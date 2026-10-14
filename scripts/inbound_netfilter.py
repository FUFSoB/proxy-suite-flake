#!/usr/bin/env python3
"""The inbound manager's nftables table: banned addresses, cut-off UDP, and speed limits.

- ban4/ban6: an address on a port, for a while (an address past a user's ipLimit).
- cut4/cut6: the same, for the UDP sessions of a user just switched off (inbound_apply.py).
- up/down: speed limits of XRay users, by socket mark. The patched XRay marks the sockets
  its exits dial for a user of level N with MARK_BASE + N (pkgs/patches/
  xray-user-level-mark.patch); the mark goes to the connection, whose packets toward the
  site (original direction, leaving this host) are policed against the user's "up" limit
  and those back (reply direction, arriving) against "down". Through the local proxy the
  connection is on loopback, where both directions arrive and leave: each is policed once.
- awg_up/awg_down: AmneziaWG peers, by interface and tunnel address.

Limits police (drop past the rate), which TCP and QUIC back off from. The table is
replaced whole when it is missing (nftables flushed it); the limits are swapped in one
transaction; the bans' sets are left alone.
"""

from __future__ import annotations

import json
import subprocess

TABLE = "proxy_suite_inbound_limits"
MARK_BASE = 0x04000000
MARK_MASK = 0xFFFF0000
# What the exits' sockopt.mark carries: the patch's flag, and the base the levels are added to.
LEVEL_MARK_FLAG = 0x40000000
EXIT_MARK = LEVEL_MARK_FLAG | MARK_BASE
MAX_SLOTS = 0xFFFF


def ruleset(table: str = TABLE) -> str:
    """The table from nothing: an existing one of that name goes first."""
    mark = f"ct mark & 0x{MARK_MASK:08x} == 0x{MARK_BASE:08x}"
    return f"""table inet {table}
delete table inet {table}
table inet {table} {{
  set ban4 {{ type ipv4_addr . inet_service; flags timeout; }}
  set ban6 {{ type ipv6_addr . inet_service; flags timeout; }}
  set cut4 {{ type ipv4_addr . inet_service; flags timeout; }}
  set cut6 {{ type ipv6_addr . inet_service; flags timeout; }}
  map up {{ type mark : limit; }}
  map down {{ type mark : limit; }}
  map awg_up4 {{ type ifname . ipv4_addr : limit; }}
  map awg_down4 {{ type ifname . ipv4_addr : limit; }}
  map awg_up6 {{ type ifname . ipv6_addr : limit; }}
  map awg_down6 {{ type ifname . ipv6_addr : limit; }}

  chain input {{
    type filter hook input priority filter - 5; policy accept;
    ip saddr . th dport @ban4 drop
    ip6 saddr . th dport @ban6 drop
    meta l4proto udp ip saddr . th dport @cut4 drop
    meta l4proto udp ip6 saddr . th dport @cut6 drop
    ct direction reply {mark} limit name ct mark map @down drop
  }}
  chain output {{
    type filter hook output priority filter - 5; policy accept;
    ct state new meta mark & 0x{MARK_MASK:08x} == 0x{MARK_BASE:08x} ct mark set meta mark
    ct direction original {mark} limit name ct mark map @up drop
  }}
  chain awg_in {{
    type filter hook prerouting priority filter - 5; policy accept;
    limit name iifname . ip saddr map @awg_up4 drop
    limit name iifname . ip6 saddr map @awg_up6 drop
  }}
  chain awg_out {{
    type filter hook postrouting priority filter - 5; policy accept;
    limit name oifname . ip daddr map @awg_down4 drop
    limit name oifname . ip6 daddr map @awg_down6 drop
  }}
}}
"""


def _limit(name: str, bits: int) -> str:
    rate = max(bits // 8, 1)
    # Room for a TCP window or two: a burst too small holds a fast link far below its rate.
    burst = max(rate // 4, 65536)
    return f"{name} {{ rate over {rate} bytes/second burst {burst} bytes }}"


def limits_script(table: str, existing: list[str], users: dict[int, dict], peers: list[dict]) -> str:
    """One transaction that empties the maps, drops the old limits and adds the new ones.

    users: {slot: {"up": bit/s|None, "down": bit/s|None}}; peers: [{"interface", "address",
    "up", "down"}]."""
    lines = [f"flush map inet {table} {m}" for m in ("up", "down", "awg_up4", "awg_down4", "awg_up6", "awg_down6")]
    lines += [f"delete limit inet {table} {name}" for name in sorted(existing)]
    for slot, speed in sorted(users.items()):
        for direction in ("up", "down"):
            if speed.get(direction):
                name = f"u{slot}_{direction}"
                lines.append(f"add limit inet {table} {_limit(name, speed[direction])}")
                lines.append(f'add element inet {table} {direction} {{ 0x{MARK_BASE + slot:08x} : "{name}" }}')
    for index, peer in enumerate(peers):
        family = "6" if ":" in peer["address"] else "4"
        for direction in ("up", "down"):
            if peer.get(direction):
                name = f"p{index}_{direction}"
                lines.append(f"add limit inet {table} {_limit(name, peer[direction])}")
                lines.append(
                    f'add element inet {table} awg_{direction}{family} {{ "{peer["interface"]}" . {peer["address"]} : "{name}" }}'
                )
    return "\n".join(lines) + "\n"


class Netfilter:
    """nft, for the manager. Off (nft None) on hosts it cannot run on: nothing happens."""

    def __init__(self, nft: str | None, table: str = TABLE):
        self.nft = nft
        self.table = table
        self.installed: tuple | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.nft)

    def _run(self, *args: str, stdin: str | None = None) -> str:
        done = subprocess.run([self.nft, *args], input=stdin, capture_output=True, text=True, timeout=30)
        if done.returncode != 0:
            raise RuntimeError(done.stderr.strip() or f"nft exited with {done.returncode}")
        return done.stdout

    def present(self) -> bool:
        try:
            self._run("list", "table", "inet", self.table)
            return True
        except RuntimeError:
            return False

    def ensure(self) -> bool:
        """Make the table if it is gone. True when it was (the limits must go in again)."""
        if not self.enabled or self.present():
            return False
        self._run("-f", "-", stdin=ruleset(self.table))
        self.installed = None
        return True

    def objects(self) -> list[str]:
        out = self._run("-j", "list", "table", "inet", self.table)
        names = []
        for item in json.loads(out).get("nftables", []):
            if "limit" in item and isinstance(item["limit"], dict) and "name" in item["limit"]:
                names.append(item["limit"]["name"])
        return names

    def sync_limits(self, users: dict[int, dict], peers: list[dict]) -> bool:
        """Install these limits unless they are what is in. True when it changed them."""
        if not self.enabled:
            return False
        wanted = (tuple(sorted((slot, s.get("up"), s.get("down")) for slot, s in users.items())),
                  tuple(sorted((p["interface"], p["address"], p.get("up"), p.get("down")) for p in peers)))
        if wanted == self.installed and self.present():
            return False
        self.ensure()
        self._run("-f", "-", stdin=limits_script(self.table, self.objects(), users, peers))
        self.installed = wanted
        return True

    def ban(self, ip: str, ports: list[int], seconds: int) -> None:
        if not self.enabled or not ports:
            return
        family = "6" if ":" in ip else "4"
        elements = ", ".join(f"{ip} . {port} timeout {int(seconds)}s" for port in sorted(set(ports)))
        self._run("add", "element", "inet", self.table, f"ban{family}", "{ " + elements + " }")

    def bans(self) -> list[dict]:
        """[{"ip", "port", "expires"}]: seconds left."""
        if not self.enabled or not self.present():
            return []
        result = []
        for family in ("4", "6"):
            out = self._run("-j", "list", "set", "inet", self.table, f"ban{family}")
            for item in json.loads(out).get("nftables", []):
                for element in (item.get("set") or {}).get("elem") or []:
                    value = element.get("elem", element) if isinstance(element, dict) else element
                    expires = value.get("expires") if isinstance(value, dict) else None
                    concat = (value.get("val") if isinstance(value, dict) else value) or {}
                    parts = concat.get("concat") if isinstance(concat, dict) else None
                    if parts and len(parts) == 2:
                        result.append({"ip": str(parts[0]), "port": int(parts[1]), "expires": expires})
        return result

    def unban(self, ip: str) -> int:
        """Lift every ban of this address; how many there were."""
        found = [ban for ban in self.bans() if ban["ip"] == ip]
        if found:
            family = "6" if ":" in ip else "4"
            elements = ", ".join(f"{ip} . {ban['port']}" for ban in found)
            self._run("delete", "element", "inet", self.table, f"ban{family}", "{ " + elements + " }")
        return len(found)
