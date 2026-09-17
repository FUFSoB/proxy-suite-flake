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
      hasAny = ro.domains != [ ] || ro.ips != [ ] || ro.geosites != [ ] || ro.geoips != [ ];
    in
    lib.optional hasAny {
      outbound = resolveTag ob.tag;
      inherit (ro)
        domains
        ips
        geosites
        geoips
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
  };
  inherit (singBoxRules)
    geositeRuleSets
    geoIPRuleSets
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
    inherit (derived) selectionMode;
  };
  inherit (xrayRules) xrayRoutingRules xrayRouteModeRules;

  routingRules = singBoxRoutingRules;
  routeModeRules = singBoxRouteModeRules;

in
{
  inherit
    direct
    zapretDirectRules
    geositeRuleSets
    geoIPRuleSets
    singBoxRoutingRules
    singBoxRouteModeRules
    singBoxDnsRules
    xrayRoutingRules
    xrayRouteModeRules
    routeModeRules
    routingRules
    ;
}
