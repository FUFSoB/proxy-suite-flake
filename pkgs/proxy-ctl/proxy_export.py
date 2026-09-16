"""The running backend config, made into a client config another device can import.

Pure functions: a config dict in, (config, warnings) out. What only makes sense on
this host goes: tproxy/tun and probe listeners, routing marks, the Clash API, loopback
hops (the hybrid XRay sidecar, the WARP tunnel, the SSH listener), and rule-sets that
live in local state. Geodata rule-sets are pointed at their upstream downloads.
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
XRAY_SOCKS_PORT = 10808
XRAY_HTTP_PORT = 10809


def _server(ob):
    settings = ob.get("settings") or {}
    for key in ("vnext", "servers"):
        if settings.get(key):
            return settings[key][0].get("address", "")
    return ob.get("server") or settings.get("address") or ""


def _loopback(ob):
    return bool(LOOPBACK.match(str(_server(ob))))


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
    loopback hops, and whatever chains through something left behind."""
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
    """The tag `only` has in the backend: as given, prefixed by the XRay wrapper, or the
    outbound collapsed into "proxy"."""
    for tag in (only, prefix + only, "proxy"):
        if tag in tags:
            return tag
    raise ValueError(f"no outbound {only} in the running config")


def portable_sing_box(cfg, only=None):
    cfg = copy.deepcopy(cfg)
    obs = cfg.get("outbounds") or []
    exits = [o for o in obs if o.get("type") not in SING_BOX_SYSTEM]
    keep = _backend_tag({o["tag"] for o in exits}, only) if only else None

    dropped, warnings = _dropped(exits, keep)
    dropped |= {o["tag"] for o in obs if o["tag"].startswith("proxy-suite-test")}

    obs = [portable_outbound(o) for o in obs if o["tag"] not in dropped]
    for o in obs:
        if o.get("type") in GROUPS:
            # Not the hops `keep` chains through: they stay only to be chained through.
            o["outbounds"] = [t for t in o.get("outbounds") or [] if t not in dropped and (not keep or t == keep)]
            if o.get("default") in dropped:
                o.pop("default")
    tags = {o["tag"] for o in obs}
    survivors = [o["tag"] for o in obs if o.get("type") not in SING_BOX_SYSTEM]
    if not survivors:
        raise ValueError("no outbound here can be used from another device")
    # `keep` is dropped when it is itself a loopback hop, kept in the chain only to be
    # chained through; a rule still pointing at it stops sing-box on the other device
    # with "default outbound not found".
    target = "proxy" if "proxy" in tags else keep if keep in tags else survivors[0]
    # A group left empty (every exit it had was dropped) routes through what remains.
    for o in obs:
        if o.get("type") in GROUPS and not o["outbounds"]:
            o["outbounds"] = [target if target != o["tag"] else "direct"]
    cfg["outbounds"] = obs

    inbound = next((i for i in cfg.get("inbounds") or [] if i.get("tag") == "mixed-in"), {})
    cfg["inbounds"] = [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": inbound.get("listen_port", 2080)}]

    route = cfg.setdefault("route", {})
    rule_sets, gone = [], set()
    for rs in route.get("rule_set") or []:
        match = GEODATA_PATH.search(rs.get("path") or "") if rs.get("type") == "local" else None
        if match:
            kind, name = match.groups()
            rule_sets.append({"type": "remote", "tag": rs["tag"], "format": "binary",
                              "url": GEODATA_URL.format(kind=kind, name=name), "download_detour": target})
        elif rs.get("type") == "local":
            gone.add(rs["tag"])
        else:
            rule_sets.append(rs)
    route["rule_set"] = rule_sets

    def usable(rule):
        return not set(rule.get("inbound") or []) - {"mixed-in"} and not set(rule.get("rule_set") or []) & gone

    def retarget(rule, key):
        if rule.get(key) in dropped:
            rule[key] = target
        return rule

    route["rules"] = [retarget(r, "outbound") for r in route.get("rules") or [] if usable(r)]
    if route.get("final") in dropped:
        route["final"] = target
    route.pop("default_mark", None)
    route.pop("default_interface", None)
    route["auto_detect_interface"] = True

    dns = cfg.get("dns") or {}
    for server in dns.get("servers") or []:
        retarget(server, "detour")
    if "rules" in dns:
        dns["rules"] = [r for r in dns["rules"] if usable(r)]

    experimental = cfg.get("experimental") or {}
    experimental.pop("clash_api", None)
    if not experimental:
        cfg.pop("experimental", None)
    return cfg, warnings


def portable_xray(cfg, only=None):
    cfg = copy.deepcopy(cfg)
    obs = cfg.get("outbounds") or []
    exits = [o for o in obs if o.get("protocol") not in XRAY_SYSTEM]
    keep = _backend_tag({o["tag"] for o in exits}, only, "proxy-suite-ob-") if only else None

    dropped, warnings = _dropped(exits, keep)
    obs = [portable_outbound(o) for o in obs if o["tag"] not in dropped]
    remaining = [o["tag"] for o in obs if o.get("protocol") not in XRAY_SYSTEM]
    if not remaining:
        raise ValueError("no outbound here can be used from another device")
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
        if set(rule.get("inboundTag") or []) - {"mixed-in"}:
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


def portable(cfg, only=None):
    """sing-box or XRay, by the config's own shape."""
    if any("protocol" in o for o in cfg.get("outbounds") or []):
        return portable_xray(cfg, only)
    return portable_sing_box(cfg, only)
