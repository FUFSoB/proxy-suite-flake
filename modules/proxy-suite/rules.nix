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
  zapretCfg = cfg.zapret;
  tgWsProxyCfg = cfg.tgWsProxy;

  trim = lib.strings.trim;
  hasPrefix = lib.strings.hasPrefix;
  splitString = lib.strings.splitString;

  zapretSrc = if builtins.isAttrs zapret && zapret ? outPath then zapret.outPath else zapret;

  parseListFile =
    path:
    lib.unique (
      builtins.filter (line: line != "" && !(hasPrefix "#" line)) (
        map trim (splitString "\n" (builtins.replaceStrings [ "\r" ] [ "" ] (builtins.readFile path)))
      )
    );

  subtractItems = items: exclusions: builtins.filter (item: !(builtins.elem item exclusions)) items;

  syncZapretDirectDomains = zapretCfg.enable && zapretCfg.syncDirectRouting;
  syncZapretDirectUpstreamIps = zapretCfg.enable && zapretCfg.syncDirectRoutingUpstreamIps;
  syncZapretDirectUserIps = zapretCfg.enable && zapretCfg.syncDirectRoutingUserIps;
  syncZapretDirectAnyIps = syncZapretDirectUpstreamIps || syncZapretDirectUserIps;

  zapretDefaultDomainFiles = [
    "list-general.txt"
    "list-google.txt"
  ]
  ++ lib.optionals zapretCfg.includeExtraUpstreamLists [
    "list-instagram.txt"
    "list-soundcloud.txt"
    "list-twitter.txt"
  ];

  zapretDefaultDomains =
    if syncZapretDirectDomains then
      lib.unique (
        lib.concatMap (file: parseListFile "${zapretSrc}/hostlists/${file}") zapretDefaultDomainFiles
      )
    else
      [ ];
  zapretDefaultIps =
    if syncZapretDirectUpstreamIps then parseListFile "${zapretSrc}/hostlists/ipset-all.txt" else [ ];
  zapretUserIps = if syncZapretDirectUserIps then zapretCfg.ipsetAll else [ ];
  zapretCustomDomains =
    if syncZapretDirectDomains then
      lib.unique (
        lib.concatMap (rule: lib.optionals rule.enableDirectSync rule.domains) zapretCfg.hostlistRules
      )
    else
      [ ];
  zapretExcludedDomains =
    if syncZapretDirectDomains then parseListFile "${zapretSrc}/hostlists/list-exclude.txt" else [ ];
  zapretExcludedIps = lib.unique (
    (
      if syncZapretDirectUpstreamIps then
        parseListFile "${zapretSrc}/hostlists/ipset-exclude.txt"
      else
        [ ]
    )
    ++ (if syncZapretDirectUserIps then zapretCfg.ipsetExclude else [ ])
  );

  zapretDirectDomains =
    if syncZapretDirectDomains then
      subtractItems (lib.unique (zapretDefaultDomains ++ zapretCfg.listGeneral ++ zapretCustomDomains)) (
        lib.unique (zapretExcludedDomains ++ zapretCfg.listExclude)
      )
    else
      [ ];
  zapretDirectIps =
    if syncZapretDirectAnyIps then
      subtractItems (lib.unique (zapretDefaultIps ++ zapretUserIps)) zapretExcludedIps
    else
      [ ];

  direct = {
    domains = lib.unique (r.direct.domains ++ zapretDirectDomains);
    ips = lib.unique (r.direct.ips ++ zapretDirectIps);
    geosites = lib.unique (r.direct.geosites ++ lib.optional r.enableRuDirect "category-ru");
    geoips = lib.unique (r.direct.geoips ++ lib.optional r.enableRuDirect "ru");
  };

  mkRule =
    field: tag: items:
    lib.optional (items != [ ]) {
      ${field} = items;
      outbound = tag;
    };
  mkDomainRule = mkRule "domain_suffix";
  mkIPRule = mkRule "ip_cidr";
  mkRulesetRule = mkRule "rule_set";
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
    else if derived.xrayEnabled && derived.selectionMode == "urltest" && !builtins.elem tag derived.builtinTags then
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

  # Build sing-box routing rule entries from a custom rule record.
  mkCustomRuleEntries =
    rule:
    lib.flatten [
      (mkDomainRule rule.outbound rule.domains)
      (mkIPRule rule.outbound rule.ips)
      (mkRulesetRule rule.outbound (map (s: "geosite-${s}") rule.geosites))
      (mkRulesetRule rule.outbound (map (s: "geoip-${s}") rule.geoips))
    ];

  # All geosite names referenced anywhere (for rule-set file definitions).
  allGeositeNames = lib.unique (
    r.proxy.geosites
    ++ direct.geosites
    ++ r.block.geosites
    ++ lib.concatMap (rule: rule.geosites) customRules
  );

  # All geoip names referenced anywhere.
  allGeoIPNames = lib.unique (
    r.proxy.geoips ++ direct.geoips ++ r.block.geoips ++ lib.concatMap (rule: rule.geoips) customRules
  );

  mkRuleSet = kind: pkg: name: {
    tag = "${kind}-${name}";
    type = "local";
    format = "binary";
    path = "${pkg}/share/sing-box/rule-set/${kind}-${name}.srs";
  };

  geositeRuleSets = map (mkRuleSet "geosite" pkgs.sing-geosite) allGeositeNames;
  geoIPRuleSets = map (mkRuleSet "geoip" pkgs.sing-geoip) allGeoIPNames;

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

  customRouteRules = map (
    rule: {
      category = customRuleCategory rule.outbound;
      entries = mkCustomRuleEntries rule;
    }
  ) customRules;

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

  tgWsProxyRelayDirectRules = lib.optional (
    tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && tgWsProxyCfg.dcIps != { }
  ) {
    ip_cidr = lib.unique (builtins.attrValues tgWsProxyCfg.dcIps);
    outbound = "direct";
  };

  safetyDirectRules = [
    {
      ip_is_private = true;
      outbound = "direct";
    }
  ] ++ tgWsProxyRelayDirectRules;

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

  singBoxRouteModeRules = {
    common = commonRules;
    custom = customRouteRules;
    proxyPrimary = proxyPrimaryRules;
    direct = directRules;
    safetyDirect = safetyDirectRules;
    block = blockRules;
    proxyGeo = proxyGeoRules;
  };

  xrayTarget =
    tag:
    if tag == "proxy" && derived.selectionMode == "urltest" then
      { balancerTag = "proxy"; }
    else
      { outboundTag = tag; };

  mkXrayRule =
    ruleTag: fields: tag:
    ({
      type = "field";
      inherit ruleTag;
    }
    // fields
    // (xrayTarget tag));

  xrayDomainRules =
    ruleTag: tag: domains:
    lib.optional (domains != [ ]) (mkXrayRule ruleTag {
      domain = map (domain: "domain:${domain}") domains;
    } tag);

  xrayIPRules =
    ruleTag: tag: ips:
    lib.optional (ips != [ ]) (mkXrayRule ruleTag {
      ip = ips;
    } tag);

  xrayGeositeRules =
    ruleTag: tag: geosites:
    lib.optional (geosites != [ ]) (mkXrayRule ruleTag {
      domain = map (name: "geosite:${name}") geosites;
    } tag);

  xrayGeoIPRules =
    ruleTag: tag: geoips:
    lib.optional (geoips != [ ]) (mkXrayRule ruleTag {
      ip = map (name: "geoip:${name}") geoips;
    } tag);

  xrayCustomRuleTag = category: kind: "custom-${category}-${kind}";

  mkXrayCustomRuleEntries =
    rule:
    lib.flatten [
      (xrayDomainRules (xrayCustomRuleTag (customRuleCategory rule.outbound) "domain") rule.outbound rule.domains)
      (xrayIPRules (xrayCustomRuleTag (customRuleCategory rule.outbound) "ip") rule.outbound rule.ips)
      (xrayGeositeRules (xrayCustomRuleTag (customRuleCategory rule.outbound) "geosite") rule.outbound rule.geosites)
      (xrayGeoIPRules (xrayCustomRuleTag (customRuleCategory rule.outbound) "geoip") rule.outbound rule.geoips)
    ];

  xrayCustomRouteRules = map (
    rule: {
      category = customRuleCategory rule.outbound;
      entries = mkXrayCustomRuleEntries rule;
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
  ];

  xraySafetyDirectRules = [
    (mkXrayRule "direct-private" { ip = [ "geoip:private" ]; } "direct")
  ] ++ lib.optional (
    tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && tgWsProxyCfg.dcIps != { }
  ) (mkXrayRule "direct-tg-relay" { ip = lib.unique (builtins.attrValues tgWsProxyCfg.dcIps); } "direct");

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
