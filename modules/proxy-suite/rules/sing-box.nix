# sing-box routing rules and local rule-set definitions.
{
  lib,
  r,
  direct,
  tgWsProxyCfg,
  customRules,
  customRuleCategory,
  geodata,
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
  ];

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
  ];

  proxyGeoRules = lib.flatten [
    (mkRulesetRule "proxy" (map (s: "geosite-${s}") r.proxy.geosites))
    (mkRulesetRule "proxy" (map (s: "geoip-${s}") r.proxy.geoips))
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
    server: domains: geosites:
    lib.optional (domains != [ ]) {
      domain_suffix = domains;
      inherit server;
    }
    ++ lib.optional (geosites != [ ]) {
      rule_set = map (s: "geosite-${s}") geosites;
      inherit server;
    };
  dnsServerFor = category: if category == "direct" then "local" else "remote";
  singBoxDnsRules =
    lib.concatMap (
      rule:
      lib.optionals (customRuleCategory rule.outbound != "block") (
        mkDnsRules (dnsServerFor (customRuleCategory rule.outbound)) rule.domains rule.geosites
      )
    ) customRules
    ++ mkDnsRules "remote" r.proxy.domains [ ]
    ++ mkDnsRules "local" direct.domains direct.geosites
    ++ mkDnsRules "remote" [ ] r.proxy.geosites;

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
    singBoxRoutingRules
    singBoxRouteModeRules
    singBoxDnsRules
    ;
}
