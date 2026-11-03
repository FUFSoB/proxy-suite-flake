# XRay routing rule definitions.
{
  lib,
  r,
  direct,
  tgWsProxyCfg,
  customRules,
  customRuleCategory,
  onionOutbound,
  selectionMode,
  proxyInboundsLoopback,
  browserDoh,
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

  # "asn:N", which XRay does not know: the start script puts the system's address list in its
  # place (backend-filter-xray.template.jq), and drops a rule left with none.
  xrayAsnRules =
    ruleTag: tag: asns:
    lib.optional (asns != [ ]) (
      mkXrayRule ruleTag {
        ip = map (n: "asn:${toString n}") asns;
      } tag
    );

  # XRay refuses a ruleTag twice: a category's 2nd+ rule takes its index among them.
  xrayCustomRuleTag =
    category: n: kind:
    "custom-${category}-${kind}" + lib.optionalString (n > 0) "-${toString n}";

  mkXrayCustomRuleEntries =
    n: rule:
    let
      tag = xrayCustomRuleTag (customRuleCategory rule.outbound) n;
    in
    lib.flatten [
      (xrayDomainRules (tag "domain") rule.outbound rule.domains)
      (xrayIPRules (tag "ip") rule.outbound rule.ips)
      (xrayGeositeRules (tag "geosite") rule.outbound rule.geosites)
      (xrayGeoIPRules (tag "geoip") rule.outbound rule.geoips)
      (xrayAsnRules (tag "asn") rule.outbound (rule.asns or [ ]))
    ];

  customCategories = map (rule: customRuleCategory rule.outbound) customRules;
  xrayCustomRouteRules = lib.imap0 (
    i: rule:
    let
      category = customRuleCategory rule.outbound;
    in
    {
      inherit category;
      entries = mkXrayCustomRuleEntries (lib.count (c: c == category) (lib.take i customCategories)) rule;
    }
  ) customRules;

  xrayProxyPrimaryRules = lib.flatten [
    (xrayDomainRules "proxy-domain" "proxy" r.proxy.domains)
    (xrayIPRules "proxy-ip" "proxy" r.proxy.ips)
  ];

  xrayDirectRules = lib.flatten [
    (xrayDomainRules "direct-domain" "direct" direct.domains)
    (xrayIPRules "direct-ip" "direct" direct.ips)
    (xrayGeositeRules "direct-geosite" "direct" direct.geosites)
    (xrayGeoIPRules "direct-geoip" "direct" direct.geoips)
    (xrayAsnRules "direct-asn" "direct" r.direct.asns)
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
    (xrayAsnRules "block-asn" "block" r.block.asns)
    # proxy.dns.browserDoh "block": what the TUN and TProxy pass to a DNS over HTTPS server.
    (lib.optional (browserDoh == "block") (
      mkXrayRule "block-doh" {
        inboundTag = xrayTransparentInbounds;
        domain = [ "geosite:category-doh" ];
      } "block"
    ))
  ];

  xrayProxyGeoRules = lib.flatten [
    (xrayGeositeRules "proxy-geosite" "proxy" r.proxy.geosites)
    (xrayGeoIPRules "proxy-geoip" "proxy" r.proxy.geoips)
    (xrayAsnRules "proxy-asn" "proxy" r.proxy.asns)
  ];

  # Sniffing (and the TUN's fake DNS) puts a name in place of where a client connected: a
  # TProxy LAN client's "Host: 127.0.0.1:2375", or a container's lvh.me through the TUN, must
  # not reach this host's loopback. Names resolved only at the dial are the direct
  # outbound's finalRules' (config-templates/xray.nix). No "::ffff:127.0.0.0/104": XRay
  # refuses its whole config over it.
  xrayTransparentInbounds = [
    "tproxy-in"
    "tproxy-in6"
    "tun-in"
  ];
  xrayLoopbackGuardRules = [
    (mkXrayRule "guard-loopback-ip" {
      inboundTag = xrayTransparentInbounds;
      ip = proxyInboundsLoopback;
    } "block")
    (mkXrayRule "guard-loopback-domain" {
      inboundTag = xrayTransparentInbounds;
      domain = [ "domain:localhost" ];
    } "block")
  ];

  # Kept by every route mode, like sing-box's common rules. .onion ahead of the guards: under
  # IPOnDemand (config-templates/xray.nix) their ip match looks the name up, and an onion name
  # must never reach a resolver. It resolves to no loopback, so the guards lose nothing.
  xrayCommonRules =
    lib.optional (onionOutbound != null) (
      mkXrayRule "tor-onion" { domain = [ "domain:onion" ]; } onionOutbound
    )
    ++ xrayLoopbackGuardRules;

  # Block ahead of the direct lists, as sing-box has it (rules/sing-box.nix).
  xrayRoutingRules =
    xrayCommonRules
    ++ lib.concatMap (item: item.entries) xrayCustomRouteRules
    ++ xrayProxyPrimaryRules
    ++ xrayBlockRules
    ++ xrayDirectRules
    ++ xraySafetyDirectRules
    ++ xrayProxyGeoRules;

  xrayRouteModeRules = {
    common = xrayCommonRules;
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
