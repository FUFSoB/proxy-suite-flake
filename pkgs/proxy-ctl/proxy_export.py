"""The running backend config, made into a client config another device can import.

Pure functions: a config dict in, (config, warnings) out. What only makes sense on
this host goes: tproxy/tun and probe listeners, routing marks, the Clash API, loopback
hops (the hybrid XRay sidecar, the WARP tunnel, the SSH listener), AmneziaWG interface
outbounds, and rule-sets that live in local state. Geodata rule-sets are pointed at their
upstream downloads.
"""

import copy
import re

LOOPBACK = re.compile(r"^(127\.|::1$|localhost$)")
GROUPS = ("selector", "urltest")
SING_BOX_SYSTEM = ("direct", "block", "dns", *GROUPS)
XRAY_SYSTEM = ("freedom", "blackhole", "dns")
GEODATA_PATH = re.compile(r"/share/sing-box/rule-set/(geosite|geoip)-([^/]+)\.srs$")
# ponytail: guessed from the file name, so wrong for custom geodata packages; take the
# URL from an option if someone ships one.
GEODATA_URL = "https://raw.githubusercontent.com/SagerNet/sing-{kind}/rule-set/{kind}-{name}.srs"
# SagerNet's geoip is countries only: telegram, google and the like (which this host takes
# from XRay's geoip.dat, pkgs/sing-geoip-extended.nix) come from MetaCubeX's instead.
GEOIP_EXTRA_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/{name}.srs"
# An autonomous system's address list (asn.nix): inlined, as no download has it.
ASN_PATH = re.compile(r"/asn-([0-9]+)\.json$")
XRAY_SOCKS_PORT = 10808
XRAY_HTTP_PORT = 10809


class NothingPortable(ValueError):
    """No outbound is left to export; warnings says why each one stayed behind."""

    def __init__(self, warnings):
        super().__init__("no outbound here can be used from another device")
        self.warnings = warnings


def _server(ob):
    settings = ob.get("settings") or {}
    for key in ("vnext", "servers"):
        if settings.get(key):
            return settings[key][0].get("address", "")
    return ob.get("server") or settings.get("address") or ""


def _loopback(ob):
    return bool(LOOPBACK.match(str(_server(ob))))


def interface_bound(ob):
    """Direct out through an interface of this host (an AmneziaWG "interface" outbound):
    without the interface it would be plain direct on the other device."""
    if ob.get("type") == "direct":
        return bool(ob.get("bind_interface"))
    if ob.get("protocol") == "freedom":
        return bool(((ob.get("streamSettings") or {}).get("sockopt") or {}).get("interface"))
    return False


def _listed(value):
    """A sing-box listable field: one value or a list of them."""
    return [value] if isinstance(value, str) else value or []


def portable_outbound(ob):
    """One outbound without what ties it to this host: routing marks and interfaces."""
    ob = copy.deepcopy(ob)
    ob.pop("routing_mark", None)
    ob.pop("bind_interface", None)
    sockopt = (ob.get("streamSettings") or {}).get("sockopt") or {}
    sockopt.pop("mark", None)
    sockopt.pop("interface", None)
    return ob


def _hop(ob):
    """The outbound this one chains through: detour on sing-box, dialerProxy on XRay."""
    return ob.get("detour") or ((ob.get("streamSettings") or {}).get("sockopt") or {}).get("dialerProxy")


def _dropped(exits, keep):
    """Exits that stay behind, and why: all but `keep` and the hops it chains through,
    loopback hops, interface outbounds, and whatever chains through something left behind."""
    hops = {o["tag"]: _hop(o) for o in exits}
    chain, tag = set(), keep
    while tag and tag not in chain:
        chain.add(tag)
        tag = hops.get(tag)
    dropped, warnings = set(), []
    for o in exits:
        if keep and o["tag"] not in chain:
            dropped.add(o["tag"])
        elif _loopback(o):
            dropped.add(o["tag"])
            warnings.append(f"left out {o['tag']}: this host reaches it through a local hop")
        elif interface_bound(o):
            dropped.add(o["tag"])
            warnings.append(f"left out {o['tag']}: it goes out through an interface of this host")
    grew = True
    while grew:
        grew = False
        for tag, hop in hops.items():
            if tag not in dropped and hop in dropped:
                dropped.add(tag)
                warnings.append(f"left out {tag}: it chains through {hop}")
                grew = True
    return dropped, warnings


def _backend_tag(tags, only, prefix=""):
    """The tag `only` has in the backend: as given, or prefixed by the XRay wrapper."""
    for tag in (only, prefix + only):
        if tag in tags:
            return tag
    raise ValueError(f"no outbound {only} in the running config")


def _geodata_url(kind, name):
    if kind == "geoip" and not re.fullmatch(r"[a-z]{2}", name):
        return GEOIP_EXTRA_URL.format(name=name)
    return GEODATA_URL.format(kind=kind, name=name)


def portable_sing_box(cfg, only=None, read_local=None):
    """read_local: path -> a local source rule set's "rules", or None; the ones it reads (ASNs'
    address lists) go along inline."""
    cfg = copy.deepcopy(cfg)
    obs = cfg.get("outbounds") or []
    exits = [o for o in obs if o.get("type") not in SING_BOX_SYSTEM or interface_bound(o)]
    keep = _backend_tag({o["tag"] for o in exits}, only) if only else None
    interfaces = {o["bind_interface"] for o in exits if interface_bound(o)}

    dropped, warnings = _dropped(exits, keep)
    dropped |= {o["tag"] for o in obs if o["tag"].startswith("proxy-suite-test")}

    obs = [portable_outbound(o) for o in obs if o["tag"] not in dropped]
    groups = {o["tag"]: o for o in obs if o.get("type") in GROUPS}
    for o in groups.values():
        # Not the hops `keep` chains through: they stay only to be chained through.
        o["outbounds"] = [t for t in o.get("outbounds") or [] if t not in dropped and (not keep or t == keep)]
        # sing-box stops with "default outbound not found" on one no longer in the group.
        if o.get("default") not in o["outbounds"]:
            o.pop("default", None)
    tags = {o["tag"] for o in obs}
    survivors = [o["tag"] for o in obs if o.get("type") not in SING_BOX_SYSTEM]
    if not survivors:
        raise NothingPortable(warnings)
    # `keep` is dropped when it is itself a loopback hop, kept in the chain only to be
    # chained through; a rule still pointing at it stops sing-box on the other device
    # with "default outbound not found".
    fallback = keep if keep in tags else survivors[0]
    target = "proxy" if "proxy" in tags else fallback
    # A group left empty (every exit it had was dropped, or none of them was `keep`) routes
    # through what remains: "proxy", or an exit when "proxy" leads to it (a loop). Never
    # "direct": rules and DNS go through "proxy", and would all go direct.
    under_proxy, todo = set(), ["proxy"]
    while todo:
        tag = todo.pop()
        if tag in groups and tag not in under_proxy:
            under_proxy.add(tag)
            todo += groups[tag]["outbounds"]
    for o in groups.values():
        if not o["outbounds"]:
            o["outbounds"] = [fallback if o["tag"] in under_proxy else target]
    cfg["outbounds"] = obs

    inbound = next((i for i in cfg.get("inbounds") or [] if i.get("tag") == "mixed-in"), {})
    cfg["inbounds"] = [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": inbound.get("listen_port", 2080)}]

    def retarget(rule, key):
        if rule.get(key) in dropped:
            rule[key] = target
        return rule

    route = cfg.setdefault("route", {})
    rule_sets, gone = [], set()
    for rs in route.get("rule_set") or []:
        match = GEODATA_PATH.search(rs.get("path") or "") if rs.get("type") == "local" else None
        inline = None
        if not match and rs.get("type") == "local" and read_local and ASN_PATH.search(rs.get("path") or ""):
            inline = read_local(rs["path"])
        if match:
            kind, name = match.groups()
            rule_sets.append({"type": "remote", "tag": rs["tag"], "format": "binary",
                              "url": _geodata_url(kind, name), "download_detour": target})
        elif isinstance(inline, list):
            rule_sets.append({"type": "inline", "tag": rs["tag"], "rules": inline})
        elif rs.get("type") == "local":
            gone.add(rs["tag"])
        else:
            # A remote one downloads through an outbound, which may be one left behind.
            rule_sets.append(retarget(rs, "download_detour"))
    route["rule_set"] = rule_sets

    def usable(rule):
        # A logical rule goes whole when a rule in it would: without that one, an "and"
        # matches more than it did here.
        if rule.get("type") == "logical":
            return all(usable(r) for r in rule.get("rules") or [])
        return not set(_listed(rule.get("inbound"))) - {"mixed-in"} and not set(_listed(rule.get("rule_set"))) & gone

    route["rules"] = [retarget(r, "outbound") for r in route.get("rules") or [] if usable(r)]
    if route.get("final") in dropped:
        route["final"] = target
    route.pop("default_mark", None)
    route.pop("default_interface", None)
    route["auto_detect_interface"] = True

    dns = cfg.get("dns") or {}
    # An interface outbound's own resolver (awg-dns-<tag>) is bound to that interface too.
    bound = {s.get("tag") for s in dns.get("servers") or [] if s.get("bind_interface") in interfaces}
    if "servers" in dns:
        dns["servers"] = [retarget(s, "detour") for s in dns["servers"] if s.get("tag") not in bound]
        # A server's own mark, as an outbound's: this host's policy routing alone reads it.
        for s in dns["servers"]:
            s.pop("routing_mark", None)
    if "rules" in dns:
        dns["rules"] = [r for r in dns["rules"] if usable(r) and r.get("server") not in bound]
    if dns.get("final") in bound:
        dns.pop("final")

    experimental = cfg.get("experimental") or {}
    experimental.pop("clash_api", None)
    if not experimental:
        cfg.pop("experimental", None)
    return cfg, warnings


def portable_xray(cfg, only=None):
    cfg = copy.deepcopy(cfg)
    obs = cfg.get("outbounds") or []
    exits = [o for o in obs if o.get("protocol") not in XRAY_SYSTEM or interface_bound(o)]
    keep = _backend_tag({o["tag"] for o in exits}, only, "proxy-suite-ob-") if only else None

    dropped, warnings = _dropped(exits, keep)
    obs = [portable_outbound(o) for o in obs if o["tag"] not in dropped]
    remaining = [o["tag"] for o in obs if o.get("protocol") not in XRAY_SYSTEM]
    if not remaining:
        raise NothingPortable(warnings)
    # As in portable_sing_box: `keep` is gone when it was a loopback hop.
    target = keep if keep in remaining else remaining[0]
    cfg["outbounds"] = obs

    mixed = next((i for i in cfg.get("inbounds") or [] if i.get("tag") == "mixed-in"), {})
    sniffing = mixed.get("sniffing") or {"enabled": True, "destOverride": ["http", "tls", "quic"]}
    cfg["inbounds"] = [
        {"tag": "mixed-in", "protocol": "socks", "listen": "127.0.0.1", "port": XRAY_SOCKS_PORT,
         "settings": {"auth": "noauth", "udp": True}, "sniffing": sniffing},
        {"tag": "http-in", "protocol": "http", "listen": "127.0.0.1", "port": XRAY_HTTP_PORT, "sniffing": sniffing},
    ]

    routing = cfg.setdefault("routing", {})
    balanced = bool(routing.get("balancers"))
    rules = []
    for rule in routing.get("rules") or []:
        # "local" and "remote" are DNS servers' own queries: a proxy's name resolves direct.
        if set(rule.get("inboundTag") or []) - {"mixed-in", "local", "remote"}:
            continue
        if rule.get("outboundTag") in dropped:
            if balanced:
                rule.pop("outboundTag")
                rule["balancerTag"] = "proxy"
            else:
                rule["outboundTag"] = target
        rules.append(rule)
    routing["rules"] = rules
    if keep:
        # The selector is a tag prefix, which would also pick the hops `keep` chains through.
        for balancer in routing.get("balancers") or []:
            balancer["selector"] = [target]
    for key in ("api", "stats", "policy"):
        cfg.pop(key, None)
    return cfg, warnings


def portable(cfg, only=None, read_local=None):
    """sing-box or XRay, by the config's own shape."""
    if any("protocol" in o for o in cfg.get("outbounds") or []):
        return portable_xray(cfg, only)
    return portable_sing_box(cfg, only, read_local)
