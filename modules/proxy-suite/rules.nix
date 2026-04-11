# Routing rules and rule-set definitions for sing-box
{ lib, pkgs, cfg }:

let
  r = cfg.singBox.routing;
  sb = cfg.singBox;

  mkDomainRule =
    tag: domains:
    lib.optional (domains != [ ]) {
      domain_suffix = domains;
      outbound = tag;
    };

  mkIPRule =
    tag: ips:
    lib.optional (ips != [ ]) {
      ip_cidr = ips;
      outbound = tag;
    };

  mkRulesetRule =
    tag: tags:
    lib.optional (tags != [ ]) {
      rule_set = tags;
      outbound = tag;
    };

  # In "first" mode the start script renames the first outbound to "proxy",
  # so any per-outbound routing tag that isn't direct/block/proxy must map
  # to "proxy" instead of the original tag (which won't exist in sing-box).
  builtinTags = [ "proxy" "direct" "block" ];
  resolveTag =
    tag:
    if sb.selection == "first" && !builtins.elem tag builtinTags then "proxy" else tag;

  # Collect per-outbound routing attached directly to outbound definitions.
  perOutboundRules = lib.concatMap (ob:
    let
      ro = ob.routing;
      hasAny = ro.domains != [ ] || ro.ips != [ ] || ro.geosites != [ ] || ro.geoips != [ ];
    in
    lib.optional hasAny {
      outbound = resolveTag ob.tag;
      inherit (ro) domains ips geosites geoips;
    }
  ) sb.outbounds;

  # All custom rules in priority order: per-outbound first, then explicit routing.rules.
  customRules = perOutboundRules ++ map (rule: rule // { outbound = resolveTag rule.outbound; }) r.rules;

  # Build sing-box routing rule entries from a custom rule record.
  mkCustomRuleEntries =
    rule: lib.flatten [
      (mkDomainRule rule.outbound rule.domains)
      (mkIPRule rule.outbound rule.ips)
      (mkRulesetRule rule.outbound (map (s: "geosite-${s}") rule.geosites))
      (mkRulesetRule rule.outbound (map (s: "geoip-${s}") rule.geoips))
    ];

  # All geosite names referenced anywhere (for rule-set file definitions).
  allGeositeNames = lib.unique (
    r.proxy.geosites
    ++ r.direct.geosites
    ++ r.block.geosites
    ++ lib.concatMap (rule: rule.geosites) customRules
  );

  # All geoip names referenced anywhere.
  allGeoIPNames = lib.unique (
    r.proxy.geoips
    ++ r.direct.geoips
    ++ r.block.geoips
    ++ lib.concatMap (rule: rule.geoips) customRules
  );

  geositeRuleSets = map (name: {
    tag = "geosite-${name}";
    type = "local";
    format = "binary";
    path = "${pkgs.sing-geosite}/share/sing-box/rule-set/geosite-${name}.srs";
  }) allGeositeNames;

  geoIPRuleSets = map (name: {
    tag = "geoip-${name}";
    type = "local";
    format = "binary";
    path = "${pkgs.sing-geoip}/share/sing-box/rule-set/geoip-${name}.srs";
  }) allGeoIPNames;

  routingRules = lib.flatten [
    {
      network = [ "tcp" "udp" ];
      port = 53;
      action = "hijack-dns";
    }
    { action = "sniff"; }

    # Per-outbound and explicit rules come first — they take priority.
    (lib.concatMap mkCustomRuleEntries customRules)

    # Global proxy lists
    (mkDomainRule "proxy" r.proxy.domains)
    (mkIPRule "proxy" r.proxy.ips)

    # Global direct lists
    (mkDomainRule "direct" r.direct.domains)
    (mkIPRule "direct" r.direct.ips)
    (mkRulesetRule "direct" (map (s: "geosite-${s}") r.direct.geosites))
    (mkRulesetRule "direct" (map (s: "geoip-${s}") r.direct.geoips))

    { ip_is_private = true; outbound = "direct"; }

    # Global proxy geo lists
    (mkRulesetRule "proxy" (map (s: "geosite-${s}") r.proxy.geosites))
    (mkRulesetRule "proxy" (map (s: "geoip-${s}") r.proxy.geoips))

    # Block
    (mkDomainRule "block" r.block.domains)
    (mkIPRule "block" r.block.ips)
    (mkRulesetRule "block" (map (s: "geosite-${s}") r.block.geosites))
    (mkRulesetRule "block" (map (s: "geoip-${s}") r.block.geoips))
  ];

in
{
  inherit
    geositeRuleSets
    geoIPRuleSets
    routingRules
    ;
}
