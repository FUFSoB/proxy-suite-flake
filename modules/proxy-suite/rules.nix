# Routing rules and rule-set definitions for sing-box
{
  lib,
  pkgs,
  cfg,
  zapret,
}:

let
  r = cfg.singBox.routing;
  singBoxCfg = cfg.singBox;
  zapretCfg = cfg.zapret;

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
      lib.unique (lib.concatMap (rule: lib.optionals rule.enableDirectSync rule.domains) zapretCfg.hostlistRules)
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

  mkRule = field: tag: items:
    lib.optional (items != [ ]) { ${field} = items; outbound = tag; };
  mkDomainRule  = mkRule "domain_suffix";
  mkIPRule      = mkRule "ip_cidr";
  mkRulesetRule = mkRule "rule_set";

  # In "first" mode the start script renames the first outbound to "proxy",
  # so any per-outbound routing tag that isn't direct/block/proxy must map
  # to "proxy" instead of the original tag (which won't exist in sing-box).
  builtinTags = [
    "proxy"
    "direct"
    "block"
  ];
  resolveTag =
    tag: if singBoxCfg.selection == "first" && !builtins.elem tag builtinTags then "proxy" else tag;

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
  ) singBoxCfg.outbounds;

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
      network = [
        "tcp"
        "udp"
      ];
      port = 53;
      action = "hijack-dns";
    }
    { action = "sniff"; }

    # Per-outbound and explicit rules come first – they take priority.
    (lib.concatMap mkCustomRuleEntries customRules)

    # Global proxy lists
    (mkDomainRule "proxy" r.proxy.domains)
    (mkIPRule "proxy" r.proxy.ips)

    # Global direct lists
    (mkDomainRule "direct" direct.domains)
    (mkIPRule "direct" direct.ips)
    (mkRulesetRule "direct" (map (s: "geosite-${s}") direct.geosites))
    (mkRulesetRule "direct" (map (s: "geoip-${s}") direct.geoips))

    {
      ip_is_private = true;
      outbound = "direct";
    }

    # Block (before proxy geosets so block can override them)
    (mkDomainRule "block" r.block.domains)
    (mkIPRule "block" r.block.ips)
    (mkRulesetRule "block" (map (s: "geosite-${s}") r.block.geosites))
    (mkRulesetRule "block" (map (s: "geoip-${s}") r.block.geoips))

    # Global proxy geo lists
    (mkRulesetRule "proxy" (map (s: "geosite-${s}") r.proxy.geosites))
    (mkRulesetRule "proxy" (map (s: "geoip-${s}") r.proxy.geoips))
  ];

in
{
  inherit
    direct
    geositeRuleSets
    geoIPRuleSets
    routingRules
    ;
}
