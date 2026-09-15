{
  lib,
  cfg,
  derived,
  tgWsProxyCfg,
  builtinTags,
  outboundTags,
  effectiveOutboundTags ? outboundTags,
  subscriptionTags,
  invalidRoutingTargets,
  effectivePerAppRoutingProfileNames,
  hasProxychainsProfiles,
  hasTunProfiles,
  hasTproxyProfiles,
  hasZapretProfiles,
}:

let
  inherit (derived)
    constants
    proxyCfg
    proxyEnabled
    singBoxEnabled
    xrayEnabled
    hybridEnabled
    pureXrayEnabled
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    zapretCfg
    zapretEngine
    ;

  mkAssertion = assertion: message: { inherit assertion message; };
  requireEnabled =
    featureEnabled: dependencyEnabled: message:
    mkAssertion (!featureEnabled || dependencyEnabled) message;
  requireAvailable =
    featureUsed: dependencyEnabled: message:
    mkAssertion (!featureUsed || dependencyEnabled) message;
  uniqueValues =
    condition: values: message:
    mkAssertion (!condition || builtins.length values == builtins.length (lib.unique values)) message;
  exactlyOneOf =
    condition: values: message:
    mkAssertion (
      !condition || builtins.length (builtins.filter (value: value != null) values) == 1
    ) message;
  notEqualWhen =
    condition: left: right: message:
    mkAssertion (!(condition && left == right)) message;
  forbiddenValues =
    condition: value: disallowed: message:
    mkAssertion (!(condition && builtins.elem value disallowed)) message;

  featureAssertions = [
    # Declaring no outbound at all is legal: they can be added at runtime with
    # `proxy-ctl proxy outbounds add`. Only a warning here; the backend still
    # refuses to start with nothing to dial.
    (uniqueValues proxyEnabled effectiveOutboundTags "proxy-suite: outbound tags must be unique")
    (uniqueValues proxyEnabled subscriptionTags
      "proxy-suite: subscription tags must be unique because they are used as cache keys and outbound tag prefixes"
    )
    (mkAssertion (
      !proxyEnabled || builtins.all (tag: !builtins.elem tag builtinTags) effectiveOutboundTags
    ) "proxy-suite: outbound tags must not use reserved names: proxy, direct, block")
    (requireEnabled cfg.sshProxy.asOutbound cfg.sshProxy.enable
      "proxy-suite: sshProxy.asOutbound requires sshProxy.enable = true"
    )
    (requireEnabled cfg.sshProxy.asOutbound proxyEnabled
      "proxy-suite: sshProxy.asOutbound requires proxy.enable = true"
    )
    (mkAssertion (
      !cfg.warp.enable || cfg.warp.asOutbound != null || cfg.warp.asAmneziaWg
    ) "proxy-suite: warp.enable = true needs warp.asOutbound or warp.asAmneziaWg")
    # One key, one session: the second peer on a WARP key takes the session over.
    (mkAssertion (!(cfg.warp.enable && cfg.warp.asOutbound != null && cfg.warp.asAmneziaWg))
      "proxy-suite: warp.asOutbound and warp.asAmneziaWg share one WARP key and would knock each other off; enable one"
    )
    # Daemon configs are readable by the service group; users must not share it.
    (mkAssertion (cfg.userControl.group != derived.constants.serviceUser)
      "proxy-suite: userControl.group must not be ${derived.constants.serviceUser}, the group that can read backend configs"
    )
    (mkAssertion (cfg.userControl.scopes == [ ] || cfg.userControl.enable)
      "proxy-suite: userControl.scopes is set but userControl.enable is false, so the group gets nothing"
    )
    (requireEnabled (cfg.warp.enable && cfg.warp.asOutbound != null) proxyEnabled
      "proxy-suite: warp.asOutbound requires proxy.enable = true"
    )
    (requireEnabled (
      cfg.warp.enable && cfg.warp.asOutbound == "interface"
    ) cfg.amneziaWg.enable ''proxy-suite: warp.asOutbound = "interface" requires amneziaWg.enable = true'')
    (requireEnabled (
      cfg.warp.enable && cfg.warp.asAmneziaWg
    ) cfg.amneziaWg.enable "proxy-suite: warp.asAmneziaWg requires amneziaWg.enable = true")
    (requireEnabled proxyCfg.autoProxy.enable proxyEnabled
      "proxy-suite: proxy.autoProxy.enable requires proxy.enable = true"
    )
    (mkAssertion (!(proxyCfg.autoProxy.enable && pureXrayEnabled))
      "proxy-suite: proxy.autoProxy needs the sing-box backend: learned routes are local rule-sets that sing-box reloads from disk, and pure XRay has no equivalent"
    )
    (mkAssertion
      (!cfg.sshProxy.enable || (cfg.sshProxy.server.user != null && cfg.sshProxy.server.host != null))
      "proxy-suite: sshProxy.server.user and sshProxy.server.host are required when sshProxy.enable = true"
    )
    # SingBox dials SSH itself and verifies host keys by value, with no
    # knownHostsFile and no trust-on-first-use fallback. An empty list accepts
    # any host key, so refuse rather than silently downgrade the tunnel.
    (mkAssertion
      (!derived.sshProxyNativeOutbound || cfg.sshProxy.hostKey != [ ] || cfg.sshProxy.hostKeyFile != null)
      "proxy-suite: sshProxy.hostKey or sshProxy.hostKeyFile is required when sshProxy.asOutbound = true with a SingBox or hybrid backend, because SingBox verifies host keys by value and an empty list accepts any key. Point hostKeyFile at a known-hosts file, or list every key from `ssh-keyscan -p <server.port> <server.host>` in hostKey -- the host key algorithm is negotiated, so a single pinned key fails the handshake when the server picks another algorithm."
    )
    (mkAssertion (!proxyEnabled || invalidRoutingTargets == [ ])
      "proxy-suite: routing.rules reference unknown outbound tag(s): ${lib.concatStringsSep ", " invalidRoutingTargets}"
    )
    (mkAssertion (
      !(pureXrayEnabled && proxyCfg.selection == "selector")
    ) "proxy-suite: proxy.selection = \"selector\" requires proxy.backend = \"sing-box\" or \"hybrid\"")
    (mkAssertion
      (!(pureXrayEnabled && (proxyCfg.dns.local.type == "tls" || proxyCfg.dns.remote.type == "tls")))
      "proxy-suite: proxy.dns.*.type = \"tls\" is not supported with proxy.backend = \"xray\"; use udp/tcp DNS for XRay"
    )
    (mkAssertion (
      !pureXrayEnabled
      || (
        proxyCfg.dns.strategy == null
        && proxyCfg.dns.clientSubnet == null
        && !proxyCfg.dns.fakeIp.enable
        && proxyCfg.dns.singBox.servers == [ ]
        && proxyCfg.dns.singBox.rules == [ ]
      )
    ) "proxy-suite: proxy.dns.strategy, clientSubnet, fakeIp and singBox require proxy.backend = \"sing-box\" or \"hybrid\"")
    (requireEnabled globalTun.enable proxyEnabled
      "proxy-suite: proxy.tun.enable requires proxy.enable = true"
    )
    (requireEnabled globalTproxy.enable proxyEnabled
      "proxy-suite: proxy.tproxy.enable requires proxy.enable = true"
    )
    (requireEnabled (
      proxyCfg.autostart == "tun"
    ) globalTun.enable ''proxy-suite: proxy.autostart = "tun" requires proxy.tun.enable = true'')
    (requireEnabled (proxyCfg.autostart == "tproxy") globalTproxy.enable
      ''proxy-suite: proxy.autostart = "tproxy" requires proxy.tproxy.enable = true''
    )
  ];

  perAppRoutingAssertions = [
    (requireAvailable (perAppRoutingCfg.profiles != [ ]) perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.profiles requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingCfg.proxychains.enable perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.proxychains.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingCfg.proxychains.enable proxyEnabled
      "proxy-suite: perAppRouting.proxychains.enable requires proxy.enable = true"
    )
    (uniqueValues true effectivePerAppRoutingProfileNames
      "proxy-suite: perAppRouting profile names must be unique"
    )
    (requireAvailable hasProxychainsProfiles perAppRoutingCfg.proxychains.enable
      "proxy-suite: route=proxychains in perAppRouting.profiles requires perAppRouting.proxychains.enable = true"
    )
    (requireAvailable hasProxychainsProfiles proxyEnabled
      "proxy-suite: route=proxychains in perAppRouting.profiles requires proxy.enable = true"
    )
    (requireEnabled perAppRoutingTun.enable perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.tun.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingTun.enable proxyEnabled
      "proxy-suite: perAppRouting.tun.enable requires proxy.enable = true"
    )
    (requireAvailable hasTunProfiles perAppRoutingTun.enable
      "proxy-suite: route=tun in perAppRouting.profiles requires perAppRouting.tun.enable = true"
    )
    (requireAvailable hasTunProfiles proxyEnabled
      "proxy-suite: route=tun in perAppRouting.profiles requires proxy.enable = true"
    )
    (requireEnabled perAppRoutingTproxy.enable perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.tproxy.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingTproxy.enable proxyEnabled
      "proxy-suite: perAppRouting.tproxy.enable requires proxy.enable = true"
    )
    (requireAvailable hasTproxyProfiles perAppRoutingTproxy.enable
      "proxy-suite: route=tproxy in perAppRouting.profiles requires perAppRouting.tproxy.enable = true"
    )
    (requireAvailable hasTproxyProfiles proxyEnabled
      "proxy-suite: route=tproxy in perAppRouting.profiles requires proxy.enable = true"
    )
    (requireEnabled perAppZapretCfg.enable perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.zapret.enable requires perAppRouting.enable = true"
    )
    (requireAvailable hasZapretProfiles perAppZapretCfg.enable
      "proxy-suite: route=zapret in perAppRouting.profiles requires perAppRouting.zapret.enable = true"
    )
  ];

  localProxyAuthCfg = proxyCfg.listener.auth;
  localProxyAuthUsed =
    localProxyAuthCfg.username != null
    || localProxyAuthCfg.password != null
    || localProxyAuthCfg.passwordFile != null;
  localProxyAuthAssertions = [
    (mkAssertion (
      !proxyEnabled || !localProxyAuthUsed || localProxyAuthCfg.username != null
    ) "proxy-suite: proxy.listener.auth requires username when password or passwordFile is set")
    (exactlyOneOf (proxyEnabled && localProxyAuthUsed) [
      localProxyAuthCfg.password
      localProxyAuthCfg.passwordFile
    ] "proxy-suite: proxy.listener.auth requires exactly one of password or passwordFile")
  ];

  secretAssertions = [
    (exactlyOneOf tgWsProxyCfg.enable [
      tgWsProxyCfg.secret
      tgWsProxyCfg.secretFile
    ] "proxy-suite: tgWsProxy requires exactly one of secret or secretFile")
  ];

  outboundAssertions = lib.concatMap (ob: [
    (exactlyOneOf proxyEnabled
      [
        ob.urlFile
        ob.url
        ob.singBoxJson
        ob.xrayJson
        ob.json
      ]
      "proxy-suite: outbound '${ob.tag}': set exactly one of urlFile, url, singBoxJson, xrayJson, or json"
    )
    (mkAssertion (
      !singBoxEnabled || hybridEnabled || ob.xrayJson == null
    ) "proxy-suite: outbound '${ob.tag}': xrayJson requires proxy.backend = xray or hybrid")
    (mkAssertion (
      !xrayEnabled || hybridEnabled || (ob.singBoxJson == null && ob.json == null)
    ) "proxy-suite: outbound '${ob.tag}': singBoxJson/json require proxy.backend = sing-box or hybrid")
    (mkAssertion (
      !(ob.backend == "xray") || xrayEnabled
    ) "proxy-suite: outbound '${ob.tag}': backend = \"xray\" requires proxy.backend = xray or hybrid")
    (mkAssertion (!(ob.backend == "sing-box") || singBoxEnabled)
      "proxy-suite: outbound '${ob.tag}': backend = \"sing-box\" requires proxy.backend = sing-box or hybrid"
    )
    (mkAssertion (
      ob.detour != ob.tag
    ) "proxy-suite: outbound '${ob.tag}': detour cannot name the outbound itself")
  ])
  proxyCfg.outbounds
  ++ map (
    e:
    mkAssertion (
      !builtins.elem e.detour [
        "proxy"
        "direct"
        "block"
      ]
    ) "proxy-suite: '${e.tag}': detour must name a real outbound, not proxy, direct or block"
  ) (builtins.filter (e: e.detour != null) (proxyCfg.outbounds ++ proxyCfg.subscriptions));

  proxyInboundsCfg = derived.proxyInboundsCfg;
  proxyInboundsEnabled = derived.proxyInboundsEnabled;
  proxyInbounds = derived.proxyInbounds;
  proxyInboundsNeedLocalProxy = proxyInboundsEnabled && derived.proxyInboundsNeedLocalProxy;

  # A pinned outbound is rendered by the XRay renderer inside the inbound
  # service, so a sing-box-only definition cannot serve as one.
  singBoxOnlyPinnedTags = map (ob: ob.tag) (
    builtins.filter (ob: ob.singBoxJson != null || ob.json != null) derived.proxyInboundViaOutbounds
  );

  proxyInboundAssertions = [
    (mkAssertion (!proxyInboundsEnabled || derived.invalidInboundViaTargets == [ ])
      "proxy-suite: inbounds via targets, or the hops they chain through, are not defined in proxy.outbounds: ${lib.concatStringsSep ", " derived.invalidInboundViaTargets}. Subscription proxies, warp, ssh-proxy and AmneziaWG outbounds cannot be named here because the inbound service does not run them; use via = \"proxy\" to reach those."
    )
    (mkAssertion (!proxyInboundsEnabled || singBoxOnlyPinnedTags == [ ])
      "proxy-suite: inbounds via targets a sing-box-only outbound: ${lib.concatStringsSep ", " singBoxOnlyPinnedTags}. The inbound service runs XRay, so a pinned outbound needs url, urlFile, or xrayJson."
    )
    (requireEnabled (proxyInboundsEnabled && derived.proxyInboundViaTags != [ ]) proxyEnabled
      "proxy-suite: inbounds pins a listener to a proxy.outbounds tag, which requires proxy.enable = true"
    )
    (requireEnabled proxyInboundsEnabled (
      proxyInbounds != [ ]
    ) "proxy-suite: inbounds.enable requires at least one entry in inbounds.listeners")
    (requireEnabled proxyInboundsNeedLocalProxy proxyEnabled
      "proxy-suite: inbounds.routing.via = \"proxy\" relays through the local proxy stack, which requires proxy.enable = true. Use via = \"direct\" for a plain exit node."
    )
    (requireEnabled proxyInboundsNeedLocalProxy derived.hasAvailableOutbounds
      "proxy-suite: inbounds.routing.via = \"proxy\" relays through the local proxy stack, so at least one proxy.outbounds or proxy.subscriptions entry is required"
    )
    (uniqueValues proxyInboundsEnabled (map (
      ib: ib.listener.port
    ) proxyInbounds) "proxy-suite: inbounds.listeners must each use a distinct port")
    (requireEnabled (proxyInboundsEnabled && proxyInboundsCfg.subscriptions.enable)
      proxyInboundsCfg.shareLinks
      "proxy-suite: inbounds.subscriptions are made of the share links, so they need inbounds.shareLinks = true"
    )
    (mkAssertion
      (
        !proxyInboundsEnabled
        || !proxyEnabled
        || !builtins.elem proxyCfg.listener.port derived.proxyInboundPorts
      )
      "proxy-suite: a proxyInbounds listener port collides with proxy.listener.port (${toString proxyCfg.listener.port})"
    )
    (mkAssertion
      (
        !proxyInboundsEnabled
        || !globalTproxy.enable
        || !builtins.elem globalTproxy.port derived.proxyInboundPorts
      )
      "proxy-suite: a proxyInbounds listener port collides with proxy.tproxy.port (${toString globalTproxy.port})"
    )
    (mkAssertion
      (
        !proxyInboundsEnabled
        || !lib.any (port: builtins.elem port derived.proxyInboundPorts) (
          [ derived.constants.inboundStatsApiPort ]
          ++ builtins.attrValues derived.constants.xrayDnsBridgePorts
        )
      )
      "proxy-suite: a proxyInbounds listener port collides with a port proxy-suite uses internally (the inbounds' stats API on ${toString derived.constants.inboundStatsApiPort}, or 18533-18535)"
    )
  ]
  ++ lib.concatMap (
    ib:
    let
      l = ib.listener;
      prefix = "proxy-suite: inbounds listener '${ib.tag}'";
      needsUuid = builtins.elem l.type [
        "vless"
        "vmess"
      ];
      needsPassword = builtins.elem l.type [
        "trojan"
        "shadowsocks"
        "socks"
        "http"
      ];
      tlsTerminated = l.tls.enable || l.type == "trojan";
      multiUserShadowsocks = l.type == "shadowsocks" && builtins.length l.users > 1;
      eachUser =
        condition: fields: message:
        mkAssertion (
          !condition
          || lib.all (user: builtins.length (builtins.filter (f: user.${f} != null) fields) == 1) l.users
        ) message;
    in
    [
      (exactlyOneOf proxyInboundsEnabled [
        l.type
        l.xrayJson
        l.jsonFile
      ] "${prefix}: set exactly one of type, xrayJson, or jsonFile")
      (mkAssertion (
        !proxyInboundsEnabled || !(l.tls.enable && l.reality.enable)
      ) "${prefix}: tls.enable and reality.enable are mutually exclusive")
      (mkAssertion (
        !proxyInboundsEnabled || l.type == null || l.users != [ ]
      ) "${prefix}: at least one entry in users is required")
      # XRay refuses to start on a repeated email, which is the user's name.
      (uniqueValues (proxyInboundsEnabled && l.type != null) (builtins.filter (n: n != "") (
        map (user: user.name) l.users
      )) "${prefix}: users must each have a distinct name")
      (eachUser (proxyInboundsEnabled && needsUuid) [
        "uuid"
        "uuidFile"
      ] "${prefix}: ${toString l.type} users each need exactly one of uuid or uuidFile")
      (eachUser (proxyInboundsEnabled && needsPassword) [
        "password"
        "passwordFile"
      ] "${prefix}: ${toString l.type} users each need exactly one of password or passwordFile")
      (mkAssertion (
        !proxyInboundsEnabled || !multiUserShadowsocks || lib.hasPrefix "2022-blake3-aes-" l.method
      ) "${prefix}: shadowsocks with more than one user needs a 2022-blake3-aes-* method")
      (exactlyOneOf (proxyInboundsEnabled && multiUserShadowsocks)
        [
          l.serverPassword
          l.serverPasswordFile
        ]
        "${prefix}: shadowsocks with more than one user needs exactly one of serverPassword or serverPasswordFile"
      )
      (mkAssertion (
        !proxyInboundsEnabled
        || !l.reality.enable
        || builtins.elem l.transport.type [
          "raw"
          "xhttp"
          "grpc"
        ]
      ) "${prefix}: reality only runs over the raw, xhttp and grpc transports")
      (mkAssertion (
        !proxyInboundsEnabled || l.xrayJson == null || (l.xrayJson.port or l.port) == l.port
      ) "${prefix}: xrayJson.port and port differ; the firewall and the port checks go by port")
      (mkAssertion (
        !proxyInboundsEnabled
        || !proxyInboundsCfg.shareLinks
        || !l.reality.enable
        || builtins.elem l.type [
          "vless"
          "trojan"
        ]
      ) "${prefix}: share links carry reality only for vless and trojan; set inbounds.shareLinks = false to serve it anyway")
      (mkAssertion (
        !proxyInboundsEnabled
        || !proxyInboundsCfg.shareLinks
        || !l.tls.enable
        || !builtins.elem l.type [
          "shadowsocks"
          "socks"
        ]
      ) "${prefix}: share links cannot carry tls for ${toString l.type}; set inbounds.shareLinks = false to serve it anyway")
      (exactlyOneOf (proxyInboundsEnabled && l.reality.enable) [
        l.reality.privateKey
        l.reality.privateKeyFile
      ] "${prefix}: reality needs exactly one of privateKey or privateKeyFile")
      (mkAssertion (
        !proxyInboundsEnabled || !l.reality.enable || l.reality.serverNames != [ ]
      ) "${prefix}: reality.serverNames must not be empty")
      (requireAvailable (proxyInboundsEnabled && l.reality.enable && proxyInboundsCfg.shareLinks)
        (l.reality.publicKey != null)
        "${prefix}: reality.publicKey is required to generate share links. Run `xray x25519` to print it alongside the private key, or set inbounds.shareLinks = false."
      )
      (mkAssertion (
        !proxyInboundsEnabled
        || !tlsTerminated
        || l.reality.enable
        || (l.tls.certificateFile != null && l.tls.keyFile != null)
      ) "${prefix}: TLS termination needs both tls.certificateFile and tls.keyFile")
      (mkAssertion (
        !proxyInboundsEnabled || l.flow == null || (l.type == "vless" && l.transport.type == "raw")
      ) "${prefix}: flow is only valid on a vless listener with transport.type = \"raw\"")
      (mkAssertion (
        !proxyInboundsEnabled
        || l.tls.alpn == null
        || !builtins.elem "h3" l.tls.alpn
        || (l.transport.type == "xhttp" && l.tls.enable && !l.reality.enable)
      ) "${prefix}: tls.alpn \"h3\" is served only by the xhttp transport with tls.enable (not REALITY)")
    ]
  ) proxyInbounds;

  subscriptionAssertions = lib.concatMap (sub: [
    (exactlyOneOf proxyEnabled [
      sub.urlFile
      sub.url
    ] "proxy-suite: subscription '${sub.tag}': set exactly one of urlFile or url")
  ]) proxyCfg.subscriptions;

  globalTunAutoRouteTable = constants.tunAutoRouteTableIndex;
  globalZapretQnum = constants.zapretGlobalQnum.${zapretEngine};
  collisionAssertions = map (item: notEqualWhen item.condition item.left item.right item.message) [
    {
      condition = globalTun.enable && perAppRoutingTun.enable;
      left = globalTun.interface;
      right = perAppRoutingTun.interface;
      message = "proxy-suite: proxy.tun.interface and perAppRouting.tun.interface must differ";
    }
    {
      condition = globalTun.enable && perAppRoutingTun.enable;
      left = globalTun.address;
      right = perAppRoutingTun.address;
      message = "proxy-suite: proxy.tun.address and perAppRouting.tun.address must differ";
    }
    {
      condition = globalTun.enable && perAppRoutingTun.enable;
      left = perAppRoutingTun.routeTable;
      right = globalTunAutoRouteTable;
      message = "proxy-suite: perAppRouting.tun.routeTable must differ from the global TUN auto-route table ${toString globalTunAutoRouteTable}";
    }
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: perAppRouting.tun.fwmark must differ from proxy.tproxy.fwmark when global TProxy is enabled";
    }
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: perAppRouting.tun.fwmark must differ from proxy.tproxy.proxyMark when global TProxy is enabled";
    }
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.routeTable;
      right = globalTproxy.routeTable;
      message = "proxy-suite: perAppRouting.tun.routeTable must differ from proxy.tproxy.routeTable when global TProxy is enabled";
    }
    {
      condition = perAppZapretCfg.enable && zapretCfg.enable;
      left = perAppZapretCfg.qnum;
      right = globalZapretQnum;
      message = "proxy-suite: perAppRouting.zapret.qnum must differ from the global zapret instance's NFQUEUE ${toString globalZapretQnum}";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.fwmark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: perAppRouting.tproxy.fwmark must differ from proxy.tproxy.fwmark";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.fwmark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: perAppRouting.tproxy.fwmark must differ from proxy.tproxy.proxyMark";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.routeTable;
      right = globalTproxy.routeTable;
      message = "proxy-suite: perAppRouting.tproxy.routeTable must differ from proxy.tproxy.routeTable";
    }
    {
      condition = perAppRoutingTun.enable && perAppRoutingTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = perAppRoutingTproxy.fwmark;
      message = "proxy-suite: perAppRouting.tun.fwmark and perAppRouting.tproxy.fwmark must differ";
    }
    {
      condition = perAppRoutingTun.enable && perAppRoutingTproxy.enable;
      left = perAppRoutingTun.routeTable;
      right = perAppRoutingTproxy.routeTable;
      message = "proxy-suite: perAppRouting.tun.routeTable and perAppRouting.tproxy.routeTable must differ";
    }
    {
      condition = perAppZapretCfg.enable;
      left = perAppZapretCfg.filterMark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: perAppRouting.zapret.filterMark must differ from proxy.tproxy.fwmark";
    }
    {
      condition = perAppZapretCfg.enable;
      left = perAppZapretCfg.filterMark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: perAppRouting.zapret.filterMark must differ from proxy.tproxy.proxyMark";
    }
    {
      condition = perAppRoutingTun.enable && perAppZapretCfg.enable;
      left = perAppRoutingTun.fwmark;
      right = perAppZapretCfg.filterMark;
      message = "proxy-suite: perAppRouting.tun.fwmark and perAppRouting.zapret.filterMark must differ";
    }
    {
      condition = perAppRoutingTproxy.enable && perAppZapretCfg.enable;
      left = perAppRoutingTproxy.fwmark;
      right = perAppZapretCfg.filterMark;
      message = "proxy-suite: perAppRouting.tproxy.fwmark and perAppRouting.zapret.filterMark must differ";
    }
    {
      condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && globalTproxy.enable;
      left = tgWsProxyCfg.fwmark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: tgWsProxy.fwmark must differ from proxy.tproxy.fwmark";
    }
    {
      condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && globalTproxy.enable;
      left = tgWsProxyCfg.fwmark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: tgWsProxy.fwmark must differ from proxy.tproxy.proxyMark";
    }
    {
      condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && perAppRoutingTun.enable;
      left = tgWsProxyCfg.fwmark;
      right = perAppRoutingTun.fwmark;
      message = "proxy-suite: tgWsProxy.fwmark must differ from perAppRouting.tun.fwmark";
    }
    {
      condition =
        tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && perAppRoutingTproxy.enable;
      left = tgWsProxyCfg.fwmark;
      right = perAppRoutingTproxy.fwmark;
      message = "proxy-suite: tgWsProxy.fwmark must differ from perAppRouting.tproxy.fwmark";
    }
    {
      condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && perAppZapretCfg.enable;
      left = tgWsProxyCfg.fwmark;
      right = perAppZapretCfg.filterMark;
      message = "proxy-suite: tgWsProxy.fwmark must differ from perAppRouting.zapret.filterMark";
    }
  ];

  perAppZapretDesyncMarks = [
    67108864
    134217728
  ];
  positiveNumberAssertions =
    map (item: mkAssertion (!item.condition || item.value > 0) item.message)
      [
        {
          condition = globalTun.enable;
          value = globalTun.mtu;
          message = "proxy-suite: proxy.tun.mtu must be greater than zero";
        }
        {
          condition = perAppRoutingTun.enable;
          value = perAppRoutingTun.mtu;
          message = "proxy-suite: perAppRouting.tun.mtu must be greater than zero";
        }
        {
          condition = globalTproxy.enable;
          value = globalTproxy.fwmark;
          message = "proxy-suite: proxy.tproxy.fwmark must be greater than zero";
        }
        {
          condition = globalTproxy.enable;
          value = globalTproxy.proxyMark;
          message = "proxy-suite: proxy.tproxy.proxyMark must be greater than zero";
        }
        {
          condition = globalTproxy.enable;
          value = globalTproxy.routeTable;
          message = "proxy-suite: proxy.tproxy.routeTable must be greater than zero";
        }
        {
          condition = perAppRoutingTun.enable;
          value = perAppRoutingTun.fwmark;
          message = "proxy-suite: perAppRouting.tun.fwmark must be greater than zero";
        }
        {
          condition = perAppRoutingTun.enable;
          value = perAppRoutingTun.routeTable;
          message = "proxy-suite: perAppRouting.tun.routeTable must be greater than zero";
        }
        {
          condition = perAppRoutingTproxy.enable;
          value = perAppRoutingTproxy.fwmark;
          message = "proxy-suite: perAppRouting.tproxy.fwmark must be greater than zero";
        }
        {
          condition = perAppRoutingTproxy.enable;
          value = perAppRoutingTproxy.routeTable;
          message = "proxy-suite: perAppRouting.tproxy.routeTable must be greater than zero";
        }
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.filterMark;
          message = "proxy-suite: perAppRouting.zapret.filterMark must be greater than zero";
        }
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.qnum;
          message = "proxy-suite: perAppRouting.zapret.qnum must be greater than zero";
        }
        {
          condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy;
          value = tgWsProxyCfg.fwmark;
          message = "proxy-suite: tgWsProxy.fwmark must be greater than zero";
        }
      ];

  forbiddenValueAssertions =
    map (item: forbiddenValues item.condition item.value item.disallowed item.message)
      [
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.filterMark;
          disallowed = [
            536870912
            1073741824
          ];
          message = "proxy-suite: perAppRouting.zapret.filterMark must not use zapret internal desync mark bits";
        }
        {
          condition = perAppZapretCfg.enable;
          value = globalTproxy.fwmark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: proxy.tproxy.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppZapretCfg.enable;
          value = globalTproxy.proxyMark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: proxy.tproxy.proxyMark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppRoutingTun.enable && perAppZapretCfg.enable;
          value = perAppRoutingTun.fwmark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: perAppRouting.tun.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppRoutingTproxy.enable && perAppZapretCfg.enable;
          value = perAppRoutingTproxy.fwmark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: perAppRouting.tproxy.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.filterMark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: perAppRouting.zapret.filterMark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && perAppZapretCfg.enable;
          value = tgWsProxyCfg.fwmark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: tgWsProxy.fwmark must not use per-app-zapret internal desync mark bits";
        }
      ];
in
featureAssertions
++ perAppRoutingAssertions
++ localProxyAuthAssertions
++ secretAssertions
++ outboundAssertions
++ proxyInboundAssertions
++ subscriptionAssertions
++ collisionAssertions
++ positiveNumberAssertions
++ forbiddenValueAssertions
