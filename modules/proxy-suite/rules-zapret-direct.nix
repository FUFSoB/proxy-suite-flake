{
  lib,
  pkgs,
  cfg,
  zapret,
  zapret2Sources ? { },
}:

let
  r = cfg.proxy.routing;
  derived = import ./derived.nix { inherit lib cfg; };
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

  # Only the system-wide instance handles traffic the proxy would send direct.
  globalEnabled = zapretCfg.enable && zapretCfg.global.enable;
  syncZapretDirectDomains = globalEnabled && zapretCfg.directSync.enable;
  # Each engine syncs its own lists: zapret2 runs none of zapret-discord-youtube's, and
  # sending them direct would keep those sites (YouTube, Google...) off the proxy even
  # where zapret2 cannot fix them and its proxyFallback routes them to the proxy.
  zapret2 = zapretCfg.engine == "zapret2";
  syncDiscordYoutubeDomains = syncZapretDirectDomains && !zapret2;
  syncZapretDirectUpstreamIps = globalEnabled && !zapret2 && zapretCfg.directSync.upstreamIps;
  syncZapretDirectUserIps = globalEnabled && !zapret2 && zapretCfg.directSync.userIps;
  syncZapretDirectAnyIps = syncZapretDirectUpstreamIps || syncZapretDirectUserIps;

  zapretDefaultDomainFiles = [
    "list-general.txt"
    "list-google.txt"
  ]
  ++ lib.optionals zapretCfg.zapret-discord-youtube.includeExtraUpstreamLists [
    "list-instagram.txt"
    "list-soundcloud.txt"
    "list-twitter.txt"
  ];

  zapretDefaultDomains =
    if syncDiscordYoutubeDomains then
      lib.unique (
        lib.concatMap (file: parseListFile "${zapretSrc}/hostlists/${file}") zapretDefaultDomainFiles
      )
    else
      [ ];
  zapretDefaultIps =
    if syncZapretDirectUpstreamIps then parseListFile "${zapretSrc}/hostlists/ipset-all.txt" else [ ];
  zapretUserIps = if syncZapretDirectUserIps then zapretCfg.zapret-discord-youtube.ips else [ ];
  zapretCustomDomains =
    if syncDiscordYoutubeDomains then
      lib.unique (
        lib.concatMap (
          rule: lib.optionals rule.enableDirectSync (zapretDomainGroups.effectiveRuleDomains rule)
        ) zapretCfg.zapret-discord-youtube.hostlistRules
      )
    else
      [ ];
  zapretCustomUserIps =
    if syncZapretDirectUserIps then
      lib.unique (
        lib.concatMap (
          rule: lib.optionals rule.enableDirectSync rule.ips
        ) zapretCfg.zapret-discord-youtube.hostlistRules
      )
    else
      [ ];
  zapretCustomDefaultIps =
    if syncZapretDirectUpstreamIps then
      lib.unique (
        lib.concatMap (
          rule: lib.optionals rule.enableDirectSync (zapretDomainGroups.expandDefaultIps rule.defaultIps)
        ) zapretCfg.zapret-discord-youtube.hostlistRules
      )
    else
      [ ];
  zapretExcludedDomains =
    if syncDiscordYoutubeDomains then parseListFile "${zapretSrc}/hostlists/list-exclude.txt" else [ ];
  # zapret2's own pinned domains; what it pins and learns at runtime comes in as a
  # rule-set (derived.nix zapret2DirectSync).
  zapret2Domains = lib.optionals (syncZapretDirectDomains && zapret2) zapretCfg.zapret2.domains;
  # The sites its strategy source's profiles take from the start (YouTube, Discord...).
  # The client's sing-box gets them in that rule-set too, after what zapret2 cannot fix,
  # which then reaches the proxy; a static direct rule here would come first and keep them
  # off it. XRay has no runtime rule-sets and no proxy fallback, nor have the inbounds.
  zapret2SiteDomains = lib.optionals (syncZapretDirectDomains && zapret2) (
    import ./zapret2/site-domains.nix {
      inherit
        lib
        pkgs
        cfg
        zapret2Sources
        ;
    }
  );
  staticSiteDomains = lib.optionals derived.pureXrayEnabled zapret2SiteDomains;
  zapret2ExcludedDomains = lib.optionals (
    syncZapretDirectDomains && zapret2
  ) zapretCfg.zapret2.excludeDomains;
  zapretExcludedIps = lib.unique (
    (
      if syncZapretDirectUpstreamIps then
        parseListFile "${zapretSrc}/hostlists/ipset-exclude.txt"
      else
        [ ]
    )
    ++ (if syncZapretDirectUserIps then zapretCfg.zapret-discord-youtube.excludeIps else [ ])
  );

  # A zapret hostlist marks an exact-match entry with "^" (nfqws syntax, used by
  # list-general.txt for the DoH resolvers). No proxy backend has such a prefix, so
  # "^dns.google" copied straight through matches nothing and the entry silently
  # stops bypassing; as a plain suffix it covers the name itself, which is the point.
  # The generated nfqws hostlists keep the prefix: only the routing sync drops it.
  stripExactPrefix = lib.removePrefix "^";

  zapretDirectDomains =
    if syncZapretDirectDomains then
      subtractItems
        (lib.unique (
          map stripExactPrefix (
            zapretDefaultDomains
            ++ lib.optionals syncDiscordYoutubeDomains zapretCfg.zapret-discord-youtube.domains
            ++ zapretCustomDomains
            ++ zapret2Domains
          )
        ))
        (
          lib.unique (
            map stripExactPrefix (
              zapretExcludedDomains
              ++ lib.optionals syncDiscordYoutubeDomains zapretCfg.zapret-discord-youtube.excludeDomains
              ++ zapret2ExcludedDomains
            )
          )
        )
    else
      [ ];
  zapretDirectIps =
    if syncZapretDirectAnyIps then
      subtractItems (lib.unique (
        zapretDefaultIps ++ zapretUserIps ++ zapretCustomUserIps ++ zapretCustomDefaultIps
      )) zapretExcludedIps
    else
      [ ];
in
{
  # The zapret-derived portion on its own. proxyInbounds routes these to the
  # direct outbound so the host's own zapret handles the DPI bypass for inbound
  # clients, instead of paying for a proxy hop it does not need.
  zapretDirect = {
    domains = lib.unique (zapretDirectDomains ++ zapret2SiteDomains);
    ips = zapretDirectIps;
  };

  direct = {
    domains = lib.unique (r.direct.domains ++ zapretDirectDomains ++ staticSiteDomains);
    ips = lib.unique (r.direct.ips ++ zapretDirectIps);
    geosites = lib.unique (r.direct.geosites ++ lib.optional r.directRu "category-ru");
    geoips = lib.unique (r.direct.geoips ++ lib.optional r.directRu "ru");
  };
}
