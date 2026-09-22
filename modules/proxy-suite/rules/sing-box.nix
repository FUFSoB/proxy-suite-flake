# sing-box routing rules and local rule-set definitions.
{
  lib,
  r,
  direct,
  tgWsProxyCfg,
  customRules,
  customRuleCategory,
  onionOutbound,
  geodata,
  ruleSets,
}:

let
  mkRule =
    field: tag: items:
    lib.optional (items != [ ]) {
      ${field} = items;
      outbound = tag;
    };
  mkDomainRule = mkRule "domain_suffix";
  mkIPRule = mkRule "ip_cidr";
  mkRulesetRule = mkRule "rule_set";

  mkCustomRuleEntries =
    rule:
    lib.flatten [
      (mkDomainRule rule.outbound rule.domains)
      (mkIPRule rule.outbound rule.ips)
      (mkRulesetRule rule.outbound (map (s: "geosite-${s}") rule.geosites))
      (mkRulesetRule rule.outbound (map (s: "geoip-${s}") rule.geoips))
      (mkRulesetRule rule.outbound (map remoteTag rule.ruleSets))
    ];

  allGeositeNames = lib.unique (
    r.proxy.geosites
    ++ direct.geosites
    ++ r.block.geosites
    ++ lib.concatMap (rule: rule.geosites) customRules
  );

  allGeoIPNames = lib.unique (
    r.proxy.geoips ++ direct.geoips ++ r.block.geoips ++ lib.concatMap (rule: rule.geoips) customRules
  );

  mkRuleSet = kind: pkg: name: {
    tag = "${kind}-${name}";
    type = "local";
    format = "binary";
    path = "${pkg}/share/sing-box/rule-set/${kind}-${name}.srs";
  };

  geositeRuleSets = map (mkRuleSet "geosite" geodata.singBox.geosite) allGeositeNames;
  geoIPRuleSets = map (mkRuleSet "geoip" geodata.singBox.geoip) allGeoIPNames;

  # Downloaded at runtime; sing-box reloads a local rule set when its file changes.
  # DNS rules read each one's domain-only copy (see derived.ruleSets).
  remoteTag = name: "ruleset-${name}";
  remoteDnsTag = name: "ruleset-${name}-dns";
  remoteRuleSets = lib.concatMap (rs: [
    {
      tag = remoteTag rs.name;
      type = "local";
      inherit (rs) format path;
    }
    {
      tag = remoteDnsTag rs.name;
      type = "local";
      format = "source";
      path = rs.dnsPath;
    }
  ]) ruleSets;

  commonRules = [
    {
      network = [
        "tcp"
        "udp"
      ];
      port = 53;
      action = "hijack-dns";
    }
    { action = "sniff"; }
  ]
  ++ lib.optional (onionOutbound != null) {
    domain_suffix = [ "onion" ];
    outbound = onionOutbound;
  };

  customRouteRules = map (rule: {
    category = customRuleCategory rule.outbound;
    entries = mkCustomRuleEntries rule;
  }) customRules;

  proxyPrimaryRules = lib.flatten [
    (mkDomainRule "proxy" r.proxy.domains)
    (mkIPRule "proxy" r.proxy.ips)
  ];

  directRules = lib.flatten [
    (mkDomainRule "direct" direct.domains)
    (mkIPRule "direct" direct.ips)
    (mkRulesetRule "direct" (map (s: "geosite-${s}") direct.geosites))
    (mkRulesetRule "direct" (map (s: "geoip-${s}") direct.geoips))
    (mkRulesetRule "direct" (map remoteTag r.direct.ruleSets))
  ];

  tgWsProxyRelayDirectRules =
    lib.optional
      (tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && tgWsProxyCfg.dcIps != { })
      {
        ip_cidr = lib.unique (builtins.attrValues tgWsProxyCfg.dcIps);
        outbound = "direct";
      };

  safetyDirectRules = [
    {
      ip_is_private = true;
      outbound = "direct";
    }
  ]
  ++ tgWsProxyRelayDirectRules;

  blockRules = lib.flatten [
    (mkDomainRule "block" r.block.domains)
    (mkIPRule "block" r.block.ips)
    (mkRulesetRule "block" (map (s: "geosite-${s}") r.block.geosites))
    (mkRulesetRule "block" (map (s: "geoip-${s}") r.block.geoips))
    (mkRulesetRule "block" (map remoteTag r.block.ruleSets))
  ];

  proxyGeoRules = lib.flatten [
    (mkRulesetRule "proxy" (map (s: "geosite-${s}") r.proxy.geosites))
    (mkRulesetRule "proxy" (map (s: "geoip-${s}") r.proxy.geoips))
    (mkRulesetRule "proxy" (map remoteTag r.proxy.ruleSets))
  ];

  singBoxRoutingRules =
    commonRules
    ++ lib.concatMap (item: item.entries) customRouteRules
    ++ proxyPrimaryRules
    ++ directRules
    ++ safetyDirectRules
    ++ blockRules
    ++ proxyGeoRules;

  # DNS follows the routing: a name that goes through the proxy is looked up through it, so
  # the ISP's resolver never sees it and cannot spoof the answer; a direct one is looked up
  # locally. In the routing's order; block entries resolve however the final says.
  mkDnsRules =
    server: domains: geosites: names:
    let
      tags = map (s: "geosite-${s}") geosites ++ map remoteDnsTag names;
    in
    lib.optional (domains != [ ]) {
      domain_suffix = domains;
      inherit server;
    }
    ++ lib.optional (tags != [ ]) {
      rule_set = tags;
      inherit server;
    };
  dnsServerFor = category: if category == "direct" then "local" else "remote";
  singBoxDnsRules =
    lib.concatMap (
      rule:
      lib.optionals (customRuleCategory rule.outbound != "block") (
        mkDnsRules (dnsServerFor (customRuleCategory rule.outbound)) rule.domains rule.geosites (
          rule.ruleSets or [ ]
        )
      )
    ) customRules
    ++ mkDnsRules "remote" r.proxy.domains [ ] [ ]
    ++ mkDnsRules "local" direct.domains direct.geosites r.direct.ruleSets
    ++ mkDnsRules "remote" [ ] r.proxy.geosites r.proxy.ruleSets;

  singBoxRouteModeRules = {
    common = commonRules;
    custom = customRouteRules;
    proxyPrimary = proxyPrimaryRules;
    direct = directRules;
    safetyDirect = safetyDirectRules;
    block = blockRules;
    proxyGeo = proxyGeoRules;
  };
in
{
  inherit
    geositeRuleSets
    geoIPRuleSets
    remoteRuleSets
    singBoxRoutingRules
    singBoxRouteModeRules
    singBoxDnsRules
    ;
}
