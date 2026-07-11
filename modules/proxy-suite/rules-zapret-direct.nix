{
  lib,
  cfg,
  zapret,
}:

let
  r = cfg.proxy.routing;
  zapretCfg = cfg.zapret;
  zapretDomainGroups = import ./zapret-domain-groups.nix { inherit lib zapret; };

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
        lib.concatMap (
          rule: lib.optionals rule.enableDirectSync (zapretDomainGroups.effectiveRuleDomains rule)
        ) zapretCfg.hostlistRules
      )
    else
      [ ];
  zapretCustomUserIps =
    if syncZapretDirectUserIps then
      lib.unique (
        lib.concatMap (rule: lib.optionals rule.enableDirectSync rule.ips) zapretCfg.hostlistRules
      )
    else
      [ ];
  zapretCustomDefaultIps =
    if syncZapretDirectUpstreamIps then
      lib.unique (
        lib.concatMap (
          rule: lib.optionals rule.enableDirectSync (zapretDomainGroups.expandDefaultIps rule.defaultIps)
        ) zapretCfg.hostlistRules
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
      subtractItems (
        lib.unique (zapretDefaultIps ++ zapretUserIps ++ zapretCustomUserIps ++ zapretCustomDefaultIps)
      ) zapretExcludedIps
    else
      [ ];
in
{
  direct = {
    domains = lib.unique (r.direct.domains ++ zapretDirectDomains);
    ips = lib.unique (r.direct.ips ++ zapretDirectIps);
    geosites = lib.unique (r.direct.geosites ++ lib.optional r.enableRuDirect "category-ru");
    geoips = lib.unique (r.direct.geoips ++ lib.optional r.enableRuDirect "ru");
  };
}
