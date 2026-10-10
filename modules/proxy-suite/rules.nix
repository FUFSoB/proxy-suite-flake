# Routing rules and rule-set definitions for sing-box
{
  lib,
  pkgs,
  cfg,
  zapret,
}:

let
  derived = import ./derived.nix { inherit lib cfg; };
  r = cfg.proxy.routing;
  proxyCfg = derived.proxyCfg;
  tgWsProxyCfg = cfg.tgWsProxy;
  zapretDirect = import ./rules-zapret-direct.nix {
    inherit
      lib
      cfg
      zapret
      ;
  };
  inherit (zapretDirect) direct;
  zapretDirectRules = zapretDirect.zapretDirect;

  customRuleCategory =
    outbound:
    if outbound == "direct" then
      "direct"
    else if outbound == "block" then
      "block"
    else
      "proxy";

  # Pure XRay's urltest prefixes every outbound for its balancer.
  resolveTag =
    tag:
    if
      derived.pureXrayEnabled
      && derived.selectionMode == "urltest"
      && !builtins.elem tag derived.builtinTags
    then
      "proxy-suite-ob-${tag}"
    else
      tag;

  # Collect per-outbound routing attached directly to outbound definitions.
  perOutboundRules = lib.concatMap (
    ob:
    let
      ro = ob.routing;
      hasAny =
        ro.domains != [ ] || ro.ips != [ ] || ro.geosites != [ ] || ro.geoips != [ ] || ro.ruleSets != [ ];
    in
    lib.optional hasAny {
      outbound = resolveTag ob.tag;
      inherit (ro)
        domains
        ips
        geosites
        geoips
        ruleSets
        ;
    }
  ) proxyCfg.outbounds;

  # .onion names go to Tor in every route mode: nothing else can reach them.
  onionOutbound = if derived.torRouteOnion then resolveTag derived.torOutboundTag else null;

  # All custom rules in priority order: per-outbound first, then explicit routing.rules.
  customRules =
    perOutboundRules ++ map (rule: rule // { outbound = resolveTag rule.outbound; }) r.rules;

  singBoxRules = import ./rules/sing-box.nix {
    inherit
      lib
      r
      direct
      tgWsProxyCfg
      customRules
      customRuleCategory
      onionOutbound
      ;
    inherit (cfg) geodata;
    inherit (derived) ruleSets proxyInboundsLoopback;
    hopPorts = lib.optionals cfg.host.privileged derived.hopPorts;
  };
  inherit (singBoxRules)
    geositeRuleSets
    geoIPRuleSets
    remoteRuleSets
    singBoxRoutingRules
    singBoxRouteModeRules
    singBoxDnsRules
    ;

  xrayRules = import ./rules/xray.nix {
    inherit
      lib
      r
      direct
      tgWsProxyCfg
      customRules
      customRuleCategory
      onionOutbound
      ;
    inherit (derived) selectionMode proxyInboundsLoopback;
  };
  inherit (xrayRules) xrayRoutingRules xrayRouteModeRules;

  routingRules = singBoxRoutingRules;
  routeModeRules = singBoxRouteModeRules;

  # The configuration's sections in match order, each at a fixed priority that runtime
  # routing rules (`proxy-ctl proxy rules`) sort among; `proxy rules list` and the Routing tab
  # show them. Tags as the user wrote them, not as the backend spells them.
  matchFields = rule: {
    domains = rule.domains or [ ];
    ips = rule.ips or [ ];
    geosites = rule.geosites or [ ];
    geoips = rule.geoips or [ ];
    ruleSets = rule.ruleSets or [ ];
  };
  routingSections = [
    {
      id = "rules";
      priority = 100;
      label = "routing.rules";
      entries =
        lib.concatMap (
          ob:
          let
            m = matchFields ob.routing;
          in
          lib.optional (lib.any (v: v != [ ]) (builtins.attrValues m)) (m // { target = ob.tag; })
        ) proxyCfg.outbounds
        ++ map (rule: matchFields rule // { target = rule.outbound; }) r.rules;
    }
    {
      id = "proxy";
      priority = 200;
      label = "routing.proxy: domains and ips";
      entries = [
        (matchFields { inherit (r.proxy) domains ips; } // { target = "proxy"; })
      ];
    }
    {
      id = "block";
      priority = 300;
      label = "routing.block";
      entries = [ (matchFields r.block // { target = "block"; }) ];
    }
    {
      id = "direct";
      priority = 400;
      label = "routing.direct, private addresses";
      entries = [ (matchFields (direct // { inherit (r.direct) ruleSets; }) // { target = "direct"; }) ];
    }
    {
      id = "proxyGeo";
      priority = 500;
      label = "routing.proxy: geosites, geoips and rule sets";
      entries = [
        (matchFields { inherit (r.proxy) geosites geoips ruleSets; } // { target = "proxy"; })
      ];
    }
  ];

in
{
  inherit
    direct
    zapretDirectRules
    geositeRuleSets
    geoIPRuleSets
    remoteRuleSets
    singBoxRoutingRules
    singBoxRouteModeRules
    singBoxDnsRules
    xrayRoutingRules
    xrayRouteModeRules
    routeModeRules
    routingRules
    routingSections
    ;
}
