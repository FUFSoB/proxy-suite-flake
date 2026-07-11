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

  customRuleCategory =
    outbound:
    if outbound == "direct" then
      "direct"
    else if outbound == "block" then
      "block"
    else
      "proxy";

  # In "first" mode the start script renames the first outbound to "proxy",
  # so any per-outbound routing tag that isn't direct/block/proxy must map
  # to "proxy" instead of the original tag (which won't exist in sing-box).
  resolveTag =
    tag:
    if derived.collapseNamedOutbounds && !builtins.elem tag derived.builtinTags then
      "proxy"
    else if
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

  # All custom rules in priority order: per-outbound first, then explicit routing.rules.
  customRules =
    perOutboundRules ++ map (rule: rule // { outbound = resolveTag rule.outbound; }) r.rules;

  singBoxRules = import ./rules/sing-box.nix {
    inherit
      lib
      pkgs
      r
      direct
      tgWsProxyCfg
      customRules
      customRuleCategory
      ;
  };
  inherit (singBoxRules)
    geositeRuleSets
    geoIPRuleSets
    singBoxRoutingRules
    singBoxRouteModeRules
    ;

  xrayRules = import ./rules/xray.nix {
    inherit
      lib
      r
      direct
      tgWsProxyCfg
      customRules
      customRuleCategory
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
    geositeRuleSets
    geoIPRuleSets
    singBoxRoutingRules
    singBoxRouteModeRules
    xrayRoutingRules
    xrayRouteModeRules
    routeModeRules
    routingRules
    ;
}
