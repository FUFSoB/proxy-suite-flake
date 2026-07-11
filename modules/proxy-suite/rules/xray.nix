# XRay routing rule definitions.
{
  lib,
  r,
  direct,
  tgWsProxyCfg,
  customRules,
  customRuleCategory,
  selectionMode,
}:

let
  xrayTarget =
    tag:
    if tag == "proxy" && selectionMode == "urltest" then
      { balancerTag = "proxy"; }
    else
      { outboundTag = tag; };

  mkXrayRule =
    ruleTag: fields: tag:
    (
      {
        type = "field";
        inherit ruleTag;
      }
      // fields
      // (xrayTarget tag)
    );

  xrayDomainRules =
    ruleTag: tag: domains:
    lib.optional (domains != [ ]) (
      mkXrayRule ruleTag {
        domain = map (domain: "domain:${domain}") domains;
      } tag
    );

  xrayIPRules =
    ruleTag: tag: ips:
    lib.optional (ips != [ ]) (
      mkXrayRule ruleTag {
        ip = ips;
      } tag
    );

  xrayGeositeRules =
    ruleTag: tag: geosites:
    lib.optional (geosites != [ ]) (
      mkXrayRule ruleTag {
        domain = map (name: "geosite:${name}") geosites;
      } tag
    );

  xrayGeoIPRules =
    ruleTag: tag: geoips:
    lib.optional (geoips != [ ]) (
      mkXrayRule ruleTag {
        ip = map (name: "geoip:${name}") geoips;
      } tag
    );

  xrayCustomRuleTag = category: kind: "custom-${category}-${kind}";

  mkXrayCustomRuleEntries =
    rule:
    lib.flatten [
      (xrayDomainRules (xrayCustomRuleTag (customRuleCategory rule.outbound) "domain") rule.outbound
        rule.domains
      )
      (xrayIPRules (xrayCustomRuleTag (customRuleCategory rule.outbound) "ip") rule.outbound rule.ips)
      (xrayGeositeRules (xrayCustomRuleTag (customRuleCategory rule.outbound) "geosite") rule.outbound
        rule.geosites
      )
      (xrayGeoIPRules (xrayCustomRuleTag (customRuleCategory rule.outbound) "geoip") rule.outbound
        rule.geoips
      )
    ];

  xrayCustomRouteRules = map (rule: {
    category = customRuleCategory rule.outbound;
    entries = mkXrayCustomRuleEntries rule;
  }) customRules;

  xrayProxyPrimaryRules = lib.flatten [
    (xrayDomainRules "proxy-domain" "proxy" r.proxy.domains)
    (xrayIPRules "proxy-ip" "proxy" r.proxy.ips)
  ];

  xrayDirectRules = lib.flatten [
    (xrayDomainRules "direct-domain" "direct" direct.domains)
    (xrayIPRules "direct-ip" "direct" direct.ips)
    (xrayGeositeRules "direct-geosite" "direct" direct.geosites)
    (xrayGeoIPRules "direct-geoip" "direct" direct.geoips)
  ];

  xraySafetyDirectRules = [
    (mkXrayRule "direct-private" { ip = [ "geoip:private" ]; } "direct")
  ]
  ++
    lib.optional
      (tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && tgWsProxyCfg.dcIps != { })
      (
        mkXrayRule "direct-tg-relay" { ip = lib.unique (builtins.attrValues tgWsProxyCfg.dcIps); } "direct"
      );

  xrayBlockRules = lib.flatten [
    (xrayDomainRules "block-domain" "block" r.block.domains)
    (xrayIPRules "block-ip" "block" r.block.ips)
    (xrayGeositeRules "block-geosite" "block" r.block.geosites)
    (xrayGeoIPRules "block-geoip" "block" r.block.geoips)
  ];

  xrayProxyGeoRules = lib.flatten [
    (xrayGeositeRules "proxy-geosite" "proxy" r.proxy.geosites)
    (xrayGeoIPRules "proxy-geoip" "proxy" r.proxy.geoips)
  ];

  xrayRoutingRules =
    lib.concatMap (item: item.entries) xrayCustomRouteRules
    ++ xrayProxyPrimaryRules
    ++ xrayDirectRules
    ++ xraySafetyDirectRules
    ++ xrayProxyGeoRules
    ++ xrayBlockRules;

  xrayRouteModeRules = {
    common = [ ];
    custom = xrayCustomRouteRules;
    proxyPrimary = xrayProxyPrimaryRules;
    direct = xrayDirectRules;
    safetyDirect = xraySafetyDirectRules;
    block = xrayBlockRules;
    proxyGeo = xrayProxyGeoRules;
  };
in
{
  inherit
    xrayRoutingRules
    xrayRouteModeRules
    ;
}
