#!/usr/bin/env python3
"""Apply a change to the inbounds without restarting them, where XRay's API can.

The inbounds' start script keeps what it rendered (build-inbound.py's output) and with
what, in its runtime directory. This renders the spec again the same way and compares:

- users who came, went or changed on a listener that is otherwise the same: removed and
  added through the API (rmu, adu), and the connections of those removed cut (ss -K for
  TCP, a short drop in proxy-suite's nftables table for UDP), since XRay keeps them;
- the routing rules (runtime users' serverSource rules): replaced whole (adrules);
- their serverSource outbounds and addresses: added and removed (ado, rmo, ip addr);
- the share links and subscriptions: written again by the module's own writer;
- AmneziaWG listeners whose peers changed: their interfaces synced (awg syncconf), which
  leaves the other peers' sessions alone;
- the listeners sing-box serves, whose users changed: its config written again and
  reloaded, which drops their connections (theirs only: XRay's are left alone).

Anything else (a listener added, removed or changed, a Shadowsocks listener going between
one user and many, socks or http accounts) needs the restart it always needed, and so does
an API call that fails. One apply at a time (a lock in the runtime directory).
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import json
import os
import subprocess
import sys
import tempfile

import inbound_runtime
from proxy_inbound import build_inbounds

# The inbound's user list, by XRay protocol; a Shadowsocks inbound has one only with more
# than one user. The others (socks, http, a single-user Shadowsocks, AmneziaWG's) change
# only with a restart.
USER_LISTS = {"vless": "clients", "vmess": "clients", "trojan": "clients", "hysteria": "clients", "shadowsocks": "clients"}
# Inbounds that speak UDP to their clients: a cut user's sessions there are dropped for a
# while instead (QUIC has no socket to kill).
UDP_CUT_SECONDS = 90


def render(spec: dict, server_address: str, onion_address: str = "", template: dict | None = None,
           check_ports: bool | set = False, now: float | None = None) -> tuple[dict, list[str]]:
    """What build-inbound.py prints: the inbounds, links and subscriptions, and with
    inbounds.runtime and the template its routing additions. check_ports: whether a runtime
    listener's port must be free, or the ports the running XRay holds, which count as free."""
    merged, runtime, warnings = inbound_runtime.merge(spec, check_ports=check_ports, now=now)
    result = build_inbounds(merged, server_address, onion_address)
    if template is not None and merged.get("runtime"):
        result.update(inbound_runtime.routing(merged, runtime, template["routing"]["rules"]))
    return result, warnings


# --- the comparison -------------------------------------------------------------------


def split_users(inbound: dict) -> tuple[dict, dict[str, dict]]:
    """The inbound without its users, and its users by email. One whose users cannot be
    told apart from the rest comes whole, with none."""
    key = USER_LISTS.get(inbound.get("protocol", ""))
    settings = inbound.get("settings") or {}
    if key is None or not isinstance(settings.get(key), list):
        return inbound, {}
    shape = copy.deepcopy(inbound)
    users = {client.get("email"): client for client in shape["settings"].pop(key)}
    if None in users or len(users) != len(settings[key]):
        return inbound, {}
    return shape, users


def plan(old: dict, new: dict) -> dict:
    """What it takes to go from the old rendering to the new one: {"restart": [reasons],
    "users": {tag: {"remove": [emails], "add": [clients]}}, "rules": rules | None,
    "outbounds": {"remove": [tags], "add": [outbounds]}, "addresses": {"remove", "add"},
    "outputs": bool}. A non-empty "restart" means the rest does not apply."""
    result: dict = {"restart": [], "users": {}, "rules": None, "outbounds": {"remove": [], "add": []},
                    "addresses": {"remove": [], "add": []}, "outputs": False}
    old_inbounds = {ib.get("tag"): ib for ib in old.get("inbounds") or []}
    new_inbounds = {ib.get("tag"): ib for ib in new.get("inbounds") or []}
    if set(old_inbounds) != set(new_inbounds):
        added = sorted(set(new_inbounds) - set(old_inbounds))
        gone = sorted(set(old_inbounds) - set(new_inbounds))
        result["restart"].append(
            "listeners " + ", ".join(filter(None, [added and f"added: {', '.join(added)}", gone and f"gone: {', '.join(gone)}"]))
        )
        return result
    for tag, inbound in new_inbounds.items():
        old_shape, old_users = split_users(old_inbounds[tag])
        new_shape, new_users = split_users(inbound)
        if old_shape != new_shape:
            result["restart"].append(f"listener '{tag}' changed")
            continue
        remove = sorted(e for e in old_users if e not in new_users or old_users[e] != new_users[e])
        add = [new_users[e] for e in sorted(new_users) if e not in old_users or old_users[e] != new_users[e]]
        if remove or add:
            result["users"][tag] = {"remove": remove, "add": add}
    if result["restart"]:
        return result
    if (old.get("rules") or []) != (new.get("rules") or []):
        result["rules"] = new.get("rules") or []
    old_outbounds = {ob["tag"]: ob for ob in old.get("selfOutbounds") or []}
    new_outbounds = {ob["tag"]: ob for ob in new.get("selfOutbounds") or []}
    result["outbounds"]["remove"] = sorted(t for t in old_outbounds if old_outbounds[t] != new_outbounds.get(t))
    result["outbounds"]["add"] = [new_outbounds[t] for t in sorted(new_outbounds) if new_outbounds[t] != old_outbounds.get(t)]

    def addresses(rendering):
        return {(family, entry[key]) for entry in rendering.get("selfAddresses") or []
                for family, key in (("4", "ipv4"), ("6", "ipv6")) if entry.get(key)}

    old_addresses, new_addresses = addresses(old), addresses(new)
    result["addresses"]["remove"] = sorted(old_addresses - new_addresses)
    result["addresses"]["add"] = sorted(new_addresses - old_addresses)
    result["outputs"] = (old.get("links"), old.get("subscriptions")) != (new.get("links"), new.get("subscriptions"))
    return result


def is_noop(steps: dict) -> bool:
    return not (steps["restart"] or steps["users"] or steps["rules"] is not None or steps["outbounds"]["remove"]
                or steps["outbounds"]["add"] or steps["addresses"]["remove"] or steps["addresses"]["add"]
                or steps["outputs"])


def udp_inbound(inbound: dict) -> bool:
    stream = inbound.get("streamSettings") or {}
    alpn = ((stream.get("tlsSettings") or {}).get("alpn")) or []
    return inbound.get("protocol") == "hysteria" or (stream.get("network") == "xhttp" and alpn == ["h3"])


# --- doing it -------------------------------------------------------------------------


class ApplyError(RuntimeError):
    pass


class Tools:
    """The binaries and names the module hands over (apply.json), and how to call them."""

    def __init__(self, config: dict, dry_run: bool = False):
        self.config = config
        self.dry_run = dry_run
        self.log: list[str] = []

    def run(self, argv: list[str], what: str, stdin: str | None = None, check: bool = True) -> str:
        self.log.append(" ".join(argv))
        if self.dry_run:
            return ""
        env = dict(os.environ)
        env.update(self.config.get("env") or {})
        try:
            done = subprocess.run(argv, input=stdin, capture_output=True, text=True, env=env, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ApplyError(f"{what}: {exc}") from None
        if check and done.returncode != 0:
            raise ApplyError(f"{what}: {(done.stderr or done.stdout).strip() or f'exit {done.returncode}'}")
        return done.stdout

    def xray_api(self, command: str, *args: str, what: str) -> str:
        # The server first: Go's flags end at the first argument that is none (rmu's emails).
        return self.run([self.config["xray"], "api", command, f"--server={self.config['api']}", *args], what)

    def xray_api_file(self, command: str, value: dict, what: str) -> str:
        with tempfile.NamedTemporaryFile("w", suffix=".json", dir=self.config.get("tmpDir"), delete=True) as handle:
            json.dump(value, handle)
            handle.flush()
            return self.run([self.config["xray"], "api", command, f"--server={self.config['api']}", handle.name], what)


def online_ips(tools: Tools, email: str) -> list[str]:
    """Where a user is connected from now, as XRay counts it (loopback never is)."""
    try:
        out = tools.xray_api("statsonlineiplist", "-email", email, what=f"online addresses of {email}")
        return sorted((json.loads(out or "{}").get("ips") or {}).keys())
    except (ApplyError, ValueError):
        return []


def cut(tools: Tools, ips: list[str], tcp_ports: set[int], udp_ports: set[int]) -> None:
    """Close what these addresses hold open on these ports: TCP sockets killed, UDP dropped
    for a while. Other users behind the same address reconnect once."""
    ss = tools.config.get("ss")
    if ss:
        for ip in ips:
            # A prefix: a bare IPv6 address would read as address and port to ss.
            prefix = f"{ip}/128" if ":" in ip else f"{ip}/32"
            for port in sorted(tcp_ports):
                tools.run([ss, "-K", "-n", "-t", "state", "established", f"( sport = :{port} )", "dst", prefix],
                          f"closing {ip}'s connections to {port}", check=False)
    nft, table = tools.config.get("nft"), tools.config.get("nftTable")
    if nft and table and udp_ports and ips:
        lines = []
        for ip in ips:
            family = "6" if ":" in ip else "4"
            for port in sorted(udp_ports):
                lines.append(f"add element inet {table} cut{family} {{ {ip} . {port} timeout {UDP_CUT_SECONDS}s }}")
        tools.run([nft, "-f", "-"], "dropping UDP of the users cut off", stdin="\n".join(lines) + "\n", check=False)


def run_steps(tools: Tools, steps: dict, new: dict, template: dict | None) -> list[str]:
    """Carry out a plan without "restart". What was done, line by line."""
    done = []
    by_tag = {ib["tag"]: ib for ib in new.get("inbounds") or []}
    # Where the users going away are connected from, before XRay forgets them.
    leaving: dict[str, list[str]] = {}
    for change in steps["users"].values():
        for email in change["remove"]:
            if email not in leaving:
                leaving[email] = online_ips(tools, email)
    tcp_ports: dict[str, set[int]] = {}
    udp_ports: dict[str, set[int]] = {}
    for tag, change in sorted(steps["users"].items()):
        inbound = by_tag[tag]
        if change["remove"]:
            tools.xray_api("rmu", f"-tag={tag}", *change["remove"], what=f"removing users from {tag}")
            ports = udp_ports if udp_inbound(inbound) else tcp_ports
            for email in change["remove"]:
                ports.setdefault(email, set()).add(int(inbound["port"]))
            done.append(f"{tag}: -{','.join(change['remove'])}")
        if change["add"]:
            key = USER_LISTS[inbound["protocol"]]
            partial = copy.deepcopy(inbound)
            partial["settings"][key] = change["add"]
            tools.xray_api_file("adu", {"inbounds": [partial]}, f"adding users to {tag}")
            done.append(f"{tag}: +{','.join(c['email'] for c in change['add'])}")
    # A user whose secret or level changed was removed and added: their old sessions go too.
    for email, ips in sorted(leaving.items()):
        if ips:
            cut(tools, ips, tcp_ports.get(email, set()), udp_ports.get(email, set()))
            done.append(f"cut {email} ({', '.join(ips)})")
    for tag in steps["outbounds"]["remove"]:
        tools.xray_api("rmo", tag, what=f"removing outbound {tag}")
    if steps["outbounds"]["add"]:
        tools.xray_api_file("ado", {"outbounds": steps["outbounds"]["add"]}, "adding serverSource outbounds")
    if steps["outbounds"]["remove"] or steps["outbounds"]["add"]:
        done.append("serverSource outbounds")
    if steps["rules"] is not None:
        routing = {key: value for key, value in ((template or {}).get("routing") or {}).items() if key != "rules"}
        routing["rules"] = steps["rules"]
        tools.xray_api_file("adrules", {"routing": routing}, "replacing the routing rules")
        done.append("routing rules")
    ip, interface = tools.config.get("ip"), tools.config.get("selfInterface")
    if ip and interface:
        for family, address in steps["addresses"]["remove"]:
            prefix = "32" if family == "4" else "128"
            tools.run([ip, f"-{family}", "addr", "del", f"{address}/{prefix}", "dev", interface],
                      f"removing {address}", check=False)
        for family, address in steps["addresses"]["add"]:
            prefix = "32" if family == "4" else "128"
            extra = ["nodad"] if family == "6" else []
            tools.run([ip, f"-{family}", "addr", "add", f"{address}/{prefix}", "dev", interface, *extra],
                      f"adding {address}")
        if steps["addresses"]["remove"] or steps["addresses"]["add"]:
            done.append("serverSource addresses")
    return done


def sync_config(runtime_dir: str, steps: dict, new: dict) -> None:
    """The running XRay's config.json, as it now runs: what proxy-ctl and people read. In
    place, so its owner, mode and ACLs stay."""
    path = os.path.join(runtime_dir, "config.json")
    config = load_json(path)
    if not isinstance(config, dict):
        return
    by_tag = {ib["tag"]: ib for ib in new.get("inbounds") or []}
    for inbound in config.get("inbounds") or []:
        tag = inbound.get("tag")
        if tag in steps["users"]:
            key = USER_LISTS[inbound["protocol"]]
            inbound.setdefault("settings", {})[key] = copy.deepcopy(by_tag[tag]["settings"][key])
    if steps["rules"] is not None:
        config.setdefault("routing", {})["rules"] = steps["rules"]
    gone = set(steps["outbounds"]["remove"])
    if gone or steps["outbounds"]["add"]:
        config["outbounds"] = [ob for ob in config.get("outbounds") or [] if ob.get("tag") not in gone]
        config["outbounds"] += copy.deepcopy(steps["outbounds"]["add"])
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle)


def _certificate_paths(config: dict | None) -> list[tuple[str, str, str]]:
    paths = []
    for inbound in (config or {}).get("inbounds") or []:
        tls = inbound.get("tls") or {}
        for key in ("certificate_path", "key_path"):
            if isinstance(tls.get(key), str):
                paths.append((inbound.get("tag", ""), key, tls[key]))
    return paths


def sync_sing_box(tools: Tools, runtime_dir: str, old: dict | None, new: dict | None) -> list[str]:
    """sing-box's config written again and the server reloaded, when its part changed. A
    certificate the start script swapped for a copy keeps its copy (proxy-inbounds-scripts.nix)."""
    if old == new:
        return []
    unit = tools.config.get("singBoxUnit")
    # From or to none at all: the start script writes it then, with any certificate copies.
    if not unit or new is None or old is None:
        return restart(tools, [tools.config["unit"]], "sing-box's listeners changed")
    path = os.path.join(runtime_dir, "sing-box.json")
    current = load_json(path)
    swapped = {}
    for (tag, key, rendered), (_, _, running) in zip(_certificate_paths(old), _certificate_paths(current), strict=False):
        swapped[(tag, key, rendered)] = running
    config = copy.deepcopy(new)
    for inbound in config.get("inbounds") or []:
        tls = inbound.get("tls") or {}
        for key in ("certificate_path", "key_path"):
            running = swapped.get((inbound.get("tag", ""), key, tls.get(key)))
            if running:
                tls[key] = running
    if not tools.dry_run:
        # In place, so its owner, mode and ACLs stay.
        fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(config, handle)
    try:
        tools.run([tools.config["systemctl"], "try-reload-or-restart", unit], f"reloading {unit}")
    except ApplyError as exc:
        return restart(tools, [tools.config["unit"]], str(exc))
    return ["sing-box listeners"]


def write_outputs(tools: Tools, rendered_path: str) -> None:
    script = tools.config.get("outputsScript")
    if script:
        tools.run([script, rendered_path], "writing the share links and subscriptions")


def save_rendering(runtime_dir: str, rendered: dict) -> str:
    path = os.path.join(runtime_dir, "rendered.json")
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(rendered, handle)
    os.replace(tmp, path)
    return path


def load_json(path: str):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def restart(tools: Tools, units: list[str], reason: str) -> list[str]:
    systemctl = tools.config["systemctl"]
    tools.run([systemctl, "try-restart", *units], f"restarting {', '.join(units)}")
    return [f"restarted {', '.join(units)}: {reason}"]


def apply_xray(tools: Tools, spec: dict) -> list[str]:
    """The XRay side; restarts the inbounds when the API cannot do it."""
    config = tools.config
    runtime_dir = config["runtimeDir"]
    unit = config["unit"]
    old = load_json(os.path.join(runtime_dir, "rendered.json"))
    args = load_json(os.path.join(runtime_dir, "render-args.json"))
    if not isinstance(old, dict) or not isinstance(args, dict):
        return restart(tools, [unit], "nothing rendered to compare with")
    template = load_json(config["template"]) if config.get("template") else None
    try:
        server_address = args.get("serverAddress") or spec.get("serverAddress") or ""
        # As the start script checks them, but the ports XRay holds now are its own.
        held = {int(ib["port"]) for ib in old.get("inbounds") or [] if isinstance(ib.get("port"), int)}
        new, warnings = render(spec, server_address, args.get("onionAddress", ""), template, check_ports=held or True)
    except (ValueError, OSError) as exc:
        return restart(tools, [unit], f"cannot render: {exc}")
    for warning in warnings:
        print(f"proxy-suite: warning: {warning}", file=sys.stderr)
    steps = plan(old, new)
    if steps["restart"]:
        return restart(tools, [unit], "; ".join(steps["restart"]))
    sing_box_changed = old.get("singBox") != new.get("singBox")
    if is_noop(steps) and not sing_box_changed:
        return []
    try:
        done = run_steps(tools, steps, new, template)
    except ApplyError as exc:
        return restart(tools, [unit], f"the API failed: {exc}")
    # After XRay has its new clients: sing-box hands users to them straight away.
    if sing_box_changed:
        try:
            done += sync_sing_box(tools, runtime_dir, old.get("singBox"), new.get("singBox"))
        except OSError as exc:
            return done + restart(tools, [unit], f"cannot write sing-box's config: {exc}")
    path = save_rendering(runtime_dir, new)
    try:
        sync_config(runtime_dir, steps, new)
    except (OSError, ValueError, KeyError) as exc:
        print(f"proxy-suite: config.json not updated: {exc}", file=sys.stderr)
    if steps["outputs"]:
        try:
            write_outputs(tools, path)
            done.append("links and subscriptions")
        except ApplyError as exc:
            print(f"proxy-suite: {exc}", file=sys.stderr)
    return done


# --- AmneziaWG ------------------------------------------------------------------------


STRIPPED_INTERFACE_KEYS = {"address", "dns", "mtu", "table", "preup", "postup", "predown", "postdown", "saveconfig"}


def strip_config(text: str) -> str:
    """awg-quick strip: what `awg setconf` takes, without awg-quick's own keys."""
    lines, section = [], ""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            section = stripped.lower()
        elif section == "[interface]" and "=" in stripped:
            if stripped.split("=", 1)[0].strip().lower() in STRIPPED_INTERFACE_KEYS:
                continue
        lines.append(line)
    return "\n".join(lines) + "\n"


def interface_part(text: str) -> str:
    out, section = [], ""
    for line in strip_config(text).splitlines():
        if line.strip().startswith("["):
            section = line.strip().lower()
        if section == "[interface]":
            out.append(line.strip())
    return "\n".join(out)


def apply_awg(tools: Tools, spec: dict) -> list[str]:
    """Write the AmneziaWG listeners' configs again and sync the interfaces whose peers
    changed. A change to an interface itself restarts their unit."""
    config = tools.config
    awg = config.get("awg")
    if not awg or not any(listener.get("type") == "amneziawg" for listener in spec["listeners"]):
        return []
    import awg_inbound

    awg_dir = config["awgRuntimeDir"]
    if not os.path.isdir(awg_dir):
        return restart(tools, [config["awgUnit"]], "the AmneziaWG listeners are not running")
    before = {}
    for listener in spec["listeners"]:
        if listener.get("type") == "amneziawg":
            path = os.path.join(awg_dir, f"{listener['amneziaWg']['interfaceName']}.conf")
            try:
                with open(path, encoding="utf-8") as handle:
                    before[listener["amneziaWg"]["interfaceName"]] = handle.read()
            except OSError:
                before[listener["amneziaWg"]["interfaceName"]] = None
    merged, _, _ = inbound_runtime.merge(spec)
    if tools.dry_run:
        return []
    prepared = awg_inbound.prepare(merged, awg, awg_dir)
    if {entry["interface"] for entry in prepared} != set(before):
        return restart(tools, [config["awgUnit"]], "AmneziaWG listeners added or removed")
    done = []
    for entry in prepared:
        with open(entry["config"], encoding="utf-8") as handle:
            text = handle.read()
        old = before.get(entry["interface"])
        if old == text:
            continue
        if old is None or interface_part(old) != interface_part(text):
            return done + restart(tools, [config["awgUnit"]], f"interface {entry['interface']} changed")
        stripped = entry["config"] + ".stripped"
        fd = os.open(stripped, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(strip_config(text))
        try:
            tools.run([awg, "syncconf", entry["interface"], stripped], f"syncing {entry['interface']}")
        except ApplyError as exc:
            return done + restart(tools, [config["awgUnit"]], str(exc))
        finally:
            os.unlink(stripped)
        done.append(f"{entry['interface']}: peers synced")
    return done


# --- entry ----------------------------------------------------------------------------


def apply(config: dict, spec: dict, dry_run: bool = False) -> list[str]:
    """Both sides, under the apply lock. With the inbounds stopped (no runtime directory)
    there is nothing to change in place: try-restart, which leaves them stopped."""
    tools = Tools(config, dry_run)
    if not os.path.isdir(config["runtimeDir"]):
        return apply_awg(tools, spec) + restart(tools, [config["unit"]], "the inbounds are not running")
    lock_path = os.path.join(config["runtimeDir"], "apply.lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        return apply_awg(tools, spec) + apply_xray(tools, spec)
    finally:
        os.close(fd)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--config", required=True, help="apply.json, from the module")
    parser.add_argument("--spec", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    with open(args.config, encoding="utf-8") as handle:
        config = json.load(handle)
    with open(args.spec, encoding="utf-8") as handle:
        spec = json.load(handle)
    try:
        for line in apply(config, spec, args.dry_run):
            print(line)
    except (ApplyError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
