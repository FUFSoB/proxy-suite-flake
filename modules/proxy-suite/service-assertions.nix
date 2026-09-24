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
  # The shape of nearly every dependency assertion: "<used> requires <dependency> = true".
  requires =
    used: dependency: usedLabel: dependencyLabel:
    mkAssertion (!used || dependency) "proxy-suite: ${usedLabel} requires ${dependencyLabel} = true";
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
  # Two values that must not coincide; the message names the config that conflicts them.
  distinct =
    condition: left: right: message:
    notEqualWhen condition left right "proxy-suite: ${message}";
  positive =
    condition: value: label:
    mkAssertion (!condition || value > 0) "proxy-suite: ${label} must be greater than zero";

  # Every loopback listener proxy-suite opens with a fixed port of its own, which
  # the autoProxy prober's range must stay clear of.
  reservedLoopbackPorts =
    builtins.attrValues constants.xrayDnsBridgePorts
    ++ [ constants.outboundTestPort ]
    ++ lib.optionals derived.warpOutboundEnabled [
      derived.warpCfg.tunnelPort
      derived.warpCfg.directPort
    ]
    ++ lib.concatMap (ob: [
      ob.tunnelPort
      ob.directPort
    ]) derived.awgTunnelOutbounds
    ++ lib.optional derived.torOutboundEnabled derived.torCfg.socksPort
    ++ map (j: j.port) derived.whitelistBypassJoiners
    ++ lib.optionals derived.proxyInboundsEnabled (
      map (listener: listener.internalPort) derived.proxyInboundsAwg
    );

  # A rootless host (home-manager, nix-on-droid) runs everything as the user: nothing
  # that programs routing, firewalls or interfaces, and no privileged ports.
  rootless = !constants.privileged;
  hostKind = cfg.host.kind;
  rootlessForbids =
    used: feature:
    mkAssertion (
      !(rootless && used)
    ) "proxy-suite: ${feature} needs root, which services on a ${hostKind} host do not have";
  rootlessPorts =
    lib.optional proxyEnabled {
      name = "proxy.listener.port";
      port = proxyCfg.listener.port;
    }
    ++ lib.optional tgWsProxyCfg.enable {
      name = "tgWsProxy.listener.port";
      port = tgWsProxyCfg.listener.port;
    }
    ++ lib.optional cfg.sshProxy.enable {
      name = "sshProxy.listener.port";
      port = cfg.sshProxy.listener.port;
    }
    ++ lib.optionals cfg.inbounds.enable (
      lib.mapAttrsToList (name: listener: {
        name = "inbounds.listeners.${name}.port";
        inherit (listener) port;
      }) cfg.inbounds.listeners
    );
  rootlessAssertions = [
    (rootlessForbids (proxyEnabled && globalTun.enable) "proxy.tun")
    (rootlessForbids (proxyEnabled && globalTproxy.enable) "proxy.tproxy")
    (rootlessForbids cfg.killSwitch.enable "killSwitch")
    (rootlessForbids (perAppRoutingCfg.enable && perAppRoutingTun.enable) "perAppRouting.tun")
    (rootlessForbids (perAppRoutingCfg.enable && perAppRoutingTproxy.enable) "perAppRouting.tproxy")
    (rootlessForbids perAppZapretCfg.enable "perAppRouting.zapret")
    (rootlessForbids zapretCfg.enable "zapret")
    (rootlessForbids (
      derived.awgGlobalProfiles != { } || derived.awgInterfaceOutbounds != [ ]
    ) ''an AmneziaWG interface (a global profile, or asOutbound = "interface"; use "userspace")'')
    (mkAssertion (!(rootless && cfg.userControl.enable))
      "proxy-suite: userControl has nothing to grant on a ${hostKind} host, whose services already belong to the user"
    )
    (mkAssertion
      (
        !(
          rootless
          && cfg.sshProxy.enable
          && cfg.sshProxy.serviceUser != null
          && cfg.sshProxy.serviceUser != constants.serviceUser
        )
      )
      "proxy-suite: sshProxy.serviceUser cannot switch users on a ${hostKind} host; leave it at its default"
    )
  ]
  ++ map (
    item:
    mkAssertion (!(rootless && item.port < 1024))
      "proxy-suite: ${item.name} = ${toString item.port} is a privileged port, which services on a ${hostKind} host cannot bind; pick one from 1024 up"
  ) rootlessPorts;

  unknownRuleSets = lib.unique (
    builtins.filter (name: !proxyCfg.routing.ruleSets ? ${name}) (
      lib.concatMap (category: proxyCfg.routing.${category}.ruleSets) [
        "proxy"
        "direct"
        "block"
      ]
      ++ lib.concatMap (rule: rule.ruleSets) proxyCfg.routing.rules
      ++ lib.concatMap (ob: ob.routing.ruleSets) proxyCfg.outbounds
    )
  );

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
    (requireEnabled (
      cfg.warp.enable && cfg.warp.asOutbound != null
    ) proxyEnabled "proxy-suite: warp.asOutbound requires proxy.enable = true")
    (requireEnabled
      (
        cfg.warp.enable
        && builtins.elem cfg.warp.asOutbound [
          "userspace"
          "interface"
        ]
      )
      cfg.amneziaWg.enable
      ''proxy-suite: warp.asOutbound = "${toString cfg.warp.asOutbound}" requires amneziaWg.enable = true''
    )
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
    (mkAssertion (!proxyEnabled || unknownRuleSets == [ ])
      "proxy-suite: routing refers to rule set(s) proxy.routing.ruleSets does not declare: ${lib.concatStringsSep ", " unknownRuleSets}"
    )
    (mkAssertion (!(pureXrayEnabled && proxyCfg.routing.ruleSets != { }))
      "proxy-suite: proxy.routing.ruleSets are sing-box rule sets, which proxy.backend = \"xray\" cannot read; use \"sing-box\" or \"hybrid\""
    )
    (mkAssertion (
      !(pureXrayEnabled && proxyCfg.selection == "selector")
    ) "proxy-suite: proxy.selection = \"selector\" requires proxy.backend = \"sing-box\" or \"hybrid\"")
    (mkAssertion
      (!(pureXrayEnabled && (proxyCfg.dns.local.type == "tls" || proxyCfg.dns.remote.type == "tls")))
      "proxy-suite: proxy.dns.*.type = \"tls\" is not supported with proxy.backend = \"xray\"; use udp/tcp DNS for XRay"
    )
    (mkAssertion
      (
        !pureXrayEnabled
        || (
          proxyCfg.dns.strategy == null
          && proxyCfg.dns.clientSubnet == null
          && !proxyCfg.dns.fakeIp.enable
          && proxyCfg.dns.singBox.servers == [ ]
          && proxyCfg.dns.singBox.rules == [ ]
        )
      )
      "proxy-suite: proxy.dns.strategy, clientSubnet, fakeIp and singBox require proxy.backend = \"sing-box\" or \"hybrid\""
    )
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
    (requireEnabled (
      globalTproxy.lanInterfaces != [ ]
    ) globalTproxy.enable "proxy-suite: proxy.tproxy.lanInterfaces requires proxy.tproxy.enable = true")
    (requireEnabled cfg.killSwitch.enable derived.killSwitchEnabled
      "proxy-suite: killSwitch.enable needs a global tunnel to guard: proxy.tun, proxy.tproxy or a global amneziaWg profile"
    )
    (mkAssertion
      (
        !derived.killSwitchEnabled
        || derived.awgGlobalProfiles == { }
        || !builtins.elem constants.awgGlobalFwmark (
          [
            globalTproxy.fwmark
            globalTproxy.proxyMark
            globalTproxy.routeTable
            constants.tunAutoRouteTableIndex
          ]
          ++ lib.optionals perAppRoutingTun.enable [
            perAppRoutingTun.fwmark
            perAppRoutingTun.routeTable
          ]
          ++ lib.optionals perAppRoutingTproxy.enable [
            perAppRoutingTproxy.fwmark
            perAppRoutingTproxy.routeTable
          ]
          ++ lib.optional tgWsProxyCfg.enable tgWsProxyCfg.fwmark
        )
      )
      "proxy-suite: global AmneziaWG profiles mark and route with ${toString constants.awgGlobalFwmark}, which a proxy.tproxy, perAppRouting or tgWsProxy mark or table also uses"
    )
  ];

  # Each case reads "<used> requires <dependency> = true", with option paths as labels.
  perAppRoutingAssertions = [
    (requires (
      perAppRoutingCfg.profiles != [ ]
    ) perAppRoutingCfg.enable "perAppRouting.profiles" "perAppRouting.enable")
    (requires perAppRoutingCfg.proxychains.enable perAppRoutingCfg.enable
      "perAppRouting.proxychains.enable"
      "perAppRouting.enable"
    )
    (requires perAppRoutingCfg.proxychains.enable proxyEnabled "perAppRouting.proxychains.enable"
      "proxy.enable"
    )
    (uniqueValues true effectivePerAppRoutingProfileNames
      "proxy-suite: perAppRouting profile names must be unique"
    )
    (requires hasProxychainsProfiles perAppRoutingCfg.proxychains.enable
      "route=proxychains in perAppRouting.profiles"
      "perAppRouting.proxychains.enable"
    )
    (requires hasProxychainsProfiles proxyEnabled "route=proxychains in perAppRouting.profiles"
      "proxy.enable"
    )
    (requires perAppRoutingTun.enable perAppRoutingCfg.enable "perAppRouting.tun.enable"
      "perAppRouting.enable"
    )
    (requires perAppRoutingTun.enable proxyEnabled "perAppRouting.tun.enable" "proxy.enable")
    (requires hasTunProfiles perAppRoutingTun.enable "route=tun in perAppRouting.profiles"
      "perAppRouting.tun.enable"
    )
    (requires hasTunProfiles proxyEnabled "route=tun in perAppRouting.profiles" "proxy.enable")
    (requires perAppRoutingTproxy.enable perAppRoutingCfg.enable "perAppRouting.tproxy.enable"
      "perAppRouting.enable"
    )
    (requires perAppRoutingTproxy.enable proxyEnabled "perAppRouting.tproxy.enable" "proxy.enable")
    (requires hasTproxyProfiles perAppRoutingTproxy.enable "route=tproxy in perAppRouting.profiles"
      "perAppRouting.tproxy.enable"
    )
    (requires hasTproxyProfiles proxyEnabled "route=tproxy in perAppRouting.profiles" "proxy.enable")
    (requires perAppZapretCfg.enable perAppRoutingCfg.enable "perAppRouting.zapret.enable"
      "perAppRouting.enable"
    )
    (requires hasZapretProfiles perAppZapretCfg.enable "route=zapret in perAppRouting.profiles"
      "perAppRouting.zapret.enable"
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

  outboundAssertions =
    lib.concatMap (ob: [
      (exactlyOneOf proxyEnabled [
        ob.urlFile
        ob.url
        ob.singBoxJson
        ob.xrayJson
      ] "proxy-suite: outbound '${ob.tag}': set exactly one of urlFile, url, singBoxJson, or xrayJson")
      (mkAssertion (
        !singBoxEnabled || hybridEnabled || ob.xrayJson == null
      ) "proxy-suite: outbound '${ob.tag}': xrayJson requires proxy.backend = xray or hybrid")
      (mkAssertion (
        !xrayEnabled || hybridEnabled || ob.singBoxJson == null
      ) "proxy-suite: outbound '${ob.tag}': singBoxJson requires proxy.backend = sing-box or hybrid")
      (mkAssertion (
        !(ob.backend == "xray") || xrayEnabled
      ) "proxy-suite: outbound '${ob.tag}': backend = \"xray\" requires proxy.backend = xray or hybrid")
      (mkAssertion (!(ob.backend == "sing-box") || singBoxEnabled)
        "proxy-suite: outbound '${ob.tag}': backend = \"sing-box\" requires proxy.backend = sing-box or hybrid"
      )
      (mkAssertion (
        ob.detour != ob.tag
      ) "proxy-suite: outbound '${ob.tag}': detour cannot name the outbound itself")
    ]) proxyCfg.outbounds
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
    builtins.filter (ob: ob.singBoxJson != null) derived.proxyInboundViaOutbounds
  );

  proxyInboundAssertions = [
    (mkAssertion (!proxyInboundsEnabled || derived.invalidInboundViaTargets == [ ])
      "proxy-suite: inbounds via targets, or the hops they chain through, are not defined in proxy.outbounds: ${lib.concatStringsSep ", " derived.invalidInboundViaTargets}. Subscription proxies, warp, tor, ssh-proxy and AmneziaWG outbounds cannot be named here because the inbound service does not run them; use via = \"proxy\" to reach those."
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
          map (listener: listener.internalPort) derived.proxyInboundsAwg
          ++ builtins.attrValues derived.constants.xrayDnsBridgePorts
        )
      )
      "proxy-suite: a proxyInbounds listener port collides with a port proxy-suite uses internally (the AmneziaWG listeners' loopback inbounds from 18700, or 18533-18535)"
    )
    # The prober opens one loopback listener per exit from probeBasePort; the WARP
    # and AmneziaWG tunnels open two each from their own bases. They all bind
    # 127.0.0.1, so an overlap leaves whichever unit starts second dead.
    (mkAssertion
      (
        !(proxyEnabled && proxyCfg.autoProxy.enable)
        || !lib.any (
          port:
          port >= proxyCfg.autoProxy.probeBasePort
          && port < proxyCfg.autoProxy.probeBasePort + proxyCfg.autoProxy.maxExits
        ) reservedLoopbackPorts
      )
      "proxy-suite: proxy.autoProxy.probeBasePort ${toString proxyCfg.autoProxy.probeBasePort} and the next ${toString proxyCfg.autoProxy.maxExits} ports cover one proxy-suite already listens on (${
        lib.concatMapStringsSep ", " toString reservedLoopbackPorts
      }); move probeBasePort"
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
        "hysteria2"
        "shadowsocks"
        "socks"
        "http"
      ];
      tlsTerminated = l.tls.enable || l.type == "trojan" || l.type == "hysteria2";
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
      (mkAssertion
        (
          !proxyInboundsEnabled
          || !proxyInboundsCfg.shareLinks
          || !l.reality.enable
          || builtins.elem l.type [
            "vless"
            "trojan"
          ]
        )
        "${prefix}: share links carry reality only for vless and trojan; set inbounds.shareLinks = false to serve it anyway"
      )
      (mkAssertion
        (
          !proxyInboundsEnabled
          || !proxyInboundsCfg.shareLinks
          || !l.tls.enable
          || !builtins.elem l.type [
            "shadowsocks"
            "socks"
          ]
        )
        "${prefix}: share links cannot carry tls for ${toString l.type}; set inbounds.shareLinks = false to serve it anyway"
      )
      (exactlyOneOf (proxyInboundsEnabled && l.reality.enable) [
        l.reality.privateKey
        l.reality.privateKeyFile
      ] "${prefix}: reality needs exactly one of privateKey or privateKeyFile")
      (mkAssertion (
        !proxyInboundsEnabled || !l.reality.enable || l.reality.serverNames != [ ]
      ) "${prefix}: reality.serverNames must not be empty")
      (requireEnabled (proxyInboundsEnabled && l.reality.enable && proxyInboundsCfg.shareLinks)
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
      (mkAssertion
        (
          !proxyInboundsEnabled
          || l.tls.alpn == null
          || !builtins.elem "h3" l.tls.alpn
          || l.type == "hysteria2"
          || (l.transport.type == "xhttp" && l.tls.enable && !l.reality.enable)
        )
        "${prefix}: tls.alpn \"h3\" is served only by hysteria2, and by the xhttp transport with tls.enable (not REALITY)"
      )
      # hysteria2 is its own QUIC transport, under a certificate of its own.
      (mkAssertion
        (!proxyInboundsEnabled || l.type != "hysteria2" || (!l.reality.enable && l.transport.type == "raw"))
        "${prefix}: hysteria2 takes no reality or transport; it needs tls.certificateFile and tls.keyFile"
      )
      (mkAssertion (
        !proxyInboundsEnabled || l.hysteria.masquerade == null || l.type == "hysteria2"
      ) "${prefix}: hysteria.masquerade is for hysteria2 listeners only")
    ]
  ) proxyInbounds;

  # AmneziaWG listeners run an interface each and give their clients addresses in a subnet.
  awgListeners = builtins.filter (ib: ib.listener.type == "amneziawg") proxyInbounds;
  awgListenersEnabled = proxyInboundsEnabled && awgListeners != [ ];

  # "a.b.c.d/n" as { base; size; } (base is the address itself, not yet masked), or null.
  parseIPv4 =
    value:
    let
      match = builtins.match "([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})(/([0-9]{1,2}))?" value;
      octets = map lib.toInt (lib.take 4 match);
      prefix = if builtins.elemAt match 5 == null then 32 else lib.toInt (builtins.elemAt match 5);
    in
    if match == null || lib.any (octet: octet > 255) octets || prefix > 32 then
      null
    else
      {
        base = lib.foldl (acc: octet: acc * 256 + octet) 0 octets;
        size = lib.foldl (acc: _: acc * 2) 1 (lib.range 1 (32 - prefix));
      };
  # Same network once both are cut down to the larger of the two.
  ipv4Overlap =
    a: b:
    let
      size = lib.max a.size b.size;
    in
    a.base / size == b.base / size;

  awgInterfaces =
    map (ib: ib.listener.amneziaWg.interfaceName) awgListeners
    ++ lib.optionals cfg.amneziaWg.enable (
      lib.mapAttrsToList (_: profile: profile.interfaceName) cfg.amneziaWg.profiles
    );
  otherInterfaces =
    lib.optional (proxyEnabled && globalTun.enable) globalTun.interface
    ++ lib.optional (perAppRoutingCfg.enable && perAppRoutingTun.enable) perAppRoutingTun.interface;

  awgInboundAssertions = [
    (rootlessForbids awgListenersEnabled "an AmneziaWG listener in inbounds.listeners")
    (uniqueValues awgListenersEnabled awgInterfaces
      "proxy-suite: AmneziaWG inbounds listeners and amneziaWg.profiles must each use a distinct interfaceName"
    )
    (mkAssertion
      (!awgListenersEnabled || !lib.any (name: builtins.elem name otherInterfaces) awgInterfaces)
      "proxy-suite: an AmneziaWG inbounds listener's interfaceName is taken by proxy.tun or perAppRouting.tun"
    )
    (mkAssertion (
      !awgListenersEnabled
      || lib.all (
        ib: lib.all (other: ib.tag == other.tag || !ipv4Overlap ib.subnet other.subnet) awgSubnets
      ) awgSubnets
    ) "proxy-suite: AmneziaWG inbounds listeners must each use a subnet of their own")
    (mkAssertion
      (
        !awgListenersEnabled
        || !builtins.elem derived.constants.awgInboundFwmark (
          [
            globalTproxy.fwmark
            globalTproxy.proxyMark
          ]
          ++ lib.optional perAppRoutingTun.enable perAppRoutingTun.fwmark
          ++ lib.optional perAppRoutingTproxy.enable perAppRoutingTproxy.fwmark
          ++ lib.optional tgWsProxyCfg.enable tgWsProxyCfg.fwmark
        )
      )
      "proxy-suite: AmneziaWG inbounds listeners mark their diverted packets with ${toString derived.constants.awgInboundFwmark}, which a proxy.tproxy, perAppRouting or tgWsProxy fwmark also uses"
    )
    (mkAssertion
      (
        !awgListenersEnabled
        || !builtins.elem derived.constants.awgInboundRouteTable (
          [
            globalTproxy.routeTable
            derived.constants.tunAutoRouteTableIndex
          ]
          ++ lib.optional perAppRoutingTun.enable perAppRoutingTun.routeTable
          ++ lib.optional perAppRoutingTproxy.enable perAppRoutingTproxy.routeTable
        )
      )
      "proxy-suite: AmneziaWG inbounds listeners route with table ${toString derived.constants.awgInboundRouteTable}, which proxy.tproxy.routeTable or a perAppRouting routeTable also uses"
    )
  ]
  ++ lib.concatMap (
    ib:
    let
      l = ib.listener;
      awg = l.amneziaWg;
      prefix = "proxy-suite: inbounds listener '${ib.tag}'";
      subnet = parseIPv4 awg.subnet;
      addresses = builtins.filter (address: address != null) (map (user: user.address) l.users);
      inSubnet =
        address:
        let
          parsed = parseIPv4 address;
          offset = parsed.base - parsed.base / subnet.size * subnet.size;
        in
        parsed != null
        && parsed.size == 1
        && ipv4Overlap parsed subnet
        && !builtins.elem offset [
          0
          1
          (subnet.size - 1)
        ];
    in
    lib.optionals (proxyInboundsEnabled && l.type == "amneziawg") [
      (mkAssertion (lib.all (user: user.name != "")
        l.users
      ) "${prefix}: AmneziaWG users each need a name, which their keys and address are kept under")
      (mkAssertion (builtins.stringLength awg.interfaceName <= 15)
        "${prefix}: amneziaWg.interfaceName '${awg.interfaceName}' is longer than the kernel's 15 characters"
      )
      (mkAssertion (
        !l.tls.enable && !l.reality.enable && l.flow == null && l.transport.type == "raw"
      ) "${prefix}: AmneziaWG takes no tls, reality, flow or transport")
      (mkAssertion (
        subnet != null && subnet.size >= 4
      ) "${prefix}: amneziaWg.subnet '${awg.subnet}' must be an IPv4 CIDR of /30 or wider")
      (mkAssertion (subnet == null || lib.all inSubnet addresses)
        "${prefix}: each user address must be a host address inside amneziaWg.subnet, other than its first (this host's)"
      )
      (uniqueValues true addresses "${prefix}: users must each have a distinct address")
      (mkAssertion (lib.all (
        user: user.publicKey == null || user.privateKeyFile == null
      ) l.users) "${prefix}: a user sets publicKey or privateKeyFile, not both")
    ]
  ) awgListeners;
  awgSubnets = builtins.filter (entry: entry.subnet != null) (
    map (ib: {
      inherit (ib) tag;
      subnet = parseIPv4 ib.listener.amneziaWg.subnet;
    }) awgListeners
  );

  subscriptionAssertions = lib.concatMap (sub: [
    (exactlyOneOf proxyEnabled [
      sub.urlFile
      sub.url
    ] "proxy-suite: subscription '${sub.tag}': set exactly one of urlFile or url")
  ]) proxyCfg.subscriptions;

  globalTunAutoRouteTable = constants.tunAutoRouteTableIndex;
  globalZapretQnum = constants.zapretGlobalQnum.${zapretEngine};
  collisionAssertions =
    let
      bothTun = globalTun.enable && perAppRoutingTun.enable;
      perAppTunWithTproxy = perAppRoutingTun.enable && globalTproxy.enable;
      bothPerApp = perAppRoutingTun.enable && perAppRoutingTproxy.enable;
      tgWsBypass = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy;
    in
    [
      (distinct bothTun globalTun.interface perAppRoutingTun.interface
        "proxy.tun.interface and perAppRouting.tun.interface must differ"
      )
      (distinct bothTun globalTun.address perAppRoutingTun.address
        "proxy.tun.address and perAppRouting.tun.address must differ"
      )
      (distinct bothTun perAppRoutingTun.routeTable globalTunAutoRouteTable
        "perAppRouting.tun.routeTable must differ from the global TUN auto-route table ${toString globalTunAutoRouteTable}"
      )
      (distinct perAppTunWithTproxy perAppRoutingTun.fwmark globalTproxy.fwmark
        "perAppRouting.tun.fwmark must differ from proxy.tproxy.fwmark when global TProxy is enabled"
      )
      (distinct perAppTunWithTproxy perAppRoutingTun.fwmark globalTproxy.proxyMark
        "perAppRouting.tun.fwmark must differ from proxy.tproxy.proxyMark when global TProxy is enabled"
      )
      (distinct perAppTunWithTproxy perAppRoutingTun.routeTable globalTproxy.routeTable
        "perAppRouting.tun.routeTable must differ from proxy.tproxy.routeTable when global TProxy is enabled"
      )
      (distinct (perAppZapretCfg.enable && zapretCfg.enable) perAppZapretCfg.qnum globalZapretQnum
        "perAppRouting.zapret.qnum must differ from the global zapret instance's NFQUEUE ${toString globalZapretQnum}"
      )
      (distinct perAppRoutingTproxy.enable perAppRoutingTproxy.fwmark globalTproxy.fwmark
        "perAppRouting.tproxy.fwmark must differ from proxy.tproxy.fwmark"
      )
      (distinct perAppRoutingTproxy.enable perAppRoutingTproxy.fwmark globalTproxy.proxyMark
        "perAppRouting.tproxy.fwmark must differ from proxy.tproxy.proxyMark"
      )
      (distinct perAppRoutingTproxy.enable perAppRoutingTproxy.routeTable globalTproxy.routeTable
        "perAppRouting.tproxy.routeTable must differ from proxy.tproxy.routeTable"
      )
      (distinct bothPerApp perAppRoutingTun.fwmark perAppRoutingTproxy.fwmark
        "perAppRouting.tun.fwmark and perAppRouting.tproxy.fwmark must differ"
      )
      (distinct bothPerApp perAppRoutingTun.routeTable perAppRoutingTproxy.routeTable
        "perAppRouting.tun.routeTable and perAppRouting.tproxy.routeTable must differ"
      )
      (distinct perAppZapretCfg.enable perAppZapretCfg.filterMark globalTproxy.fwmark
        "perAppRouting.zapret.filterMark must differ from proxy.tproxy.fwmark"
      )
      (distinct perAppZapretCfg.enable perAppZapretCfg.filterMark globalTproxy.proxyMark
        "perAppRouting.zapret.filterMark must differ from proxy.tproxy.proxyMark"
      )
      (distinct (perAppRoutingTun.enable && perAppZapretCfg.enable) perAppRoutingTun.fwmark
        perAppZapretCfg.filterMark
        "perAppRouting.tun.fwmark and perAppRouting.zapret.filterMark must differ"
      )
      (distinct (perAppRoutingTproxy.enable && perAppZapretCfg.enable) perAppRoutingTproxy.fwmark
        perAppZapretCfg.filterMark
        "perAppRouting.tproxy.fwmark and perAppRouting.zapret.filterMark must differ"
      )
      (distinct (
        tgWsBypass && globalTproxy.enable
      ) tgWsProxyCfg.fwmark globalTproxy.fwmark "tgWsProxy.fwmark must differ from proxy.tproxy.fwmark")
      (distinct (tgWsBypass && globalTproxy.enable) tgWsProxyCfg.fwmark globalTproxy.proxyMark
        "tgWsProxy.fwmark must differ from proxy.tproxy.proxyMark"
      )
      (distinct (tgWsBypass && perAppRoutingTun.enable) tgWsProxyCfg.fwmark perAppRoutingTun.fwmark
        "tgWsProxy.fwmark must differ from perAppRouting.tun.fwmark"
      )
      (distinct (tgWsBypass && perAppRoutingTproxy.enable) tgWsProxyCfg.fwmark perAppRoutingTproxy.fwmark
        "tgWsProxy.fwmark must differ from perAppRouting.tproxy.fwmark"
      )
      (distinct (tgWsBypass && perAppZapretCfg.enable) tgWsProxyCfg.fwmark perAppZapretCfg.filterMark
        "tgWsProxy.fwmark must differ from perAppRouting.zapret.filterMark"
      )
    ];

  perAppZapretDesyncMarks = [
    67108864
    134217728
  ];
  positiveNumberAssertions = [
    (positive globalTun.enable globalTun.mtu "proxy.tun.mtu")
    (positive perAppRoutingTun.enable perAppRoutingTun.mtu "perAppRouting.tun.mtu")
    (positive globalTproxy.enable globalTproxy.fwmark "proxy.tproxy.fwmark")
    (positive globalTproxy.enable globalTproxy.proxyMark "proxy.tproxy.proxyMark")
    (positive globalTproxy.enable globalTproxy.routeTable "proxy.tproxy.routeTable")
    (positive perAppRoutingTun.enable perAppRoutingTun.fwmark "perAppRouting.tun.fwmark")
    (positive perAppRoutingTun.enable perAppRoutingTun.routeTable "perAppRouting.tun.routeTable")
    (positive perAppRoutingTproxy.enable perAppRoutingTproxy.fwmark "perAppRouting.tproxy.fwmark")
    (positive perAppRoutingTproxy.enable perAppRoutingTproxy.routeTable
      "perAppRouting.tproxy.routeTable"
    )
    (positive perAppZapretCfg.enable perAppZapretCfg.filterMark "perAppRouting.zapret.filterMark")
    (positive perAppZapretCfg.enable perAppZapretCfg.qnum "perAppRouting.zapret.qnum")
    (positive (
      tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy
    ) tgWsProxyCfg.fwmark "tgWsProxy.fwmark")
  ];

  forbiddenValueAssertions =
    let
      # zapret's own desync marks: v1's pair, and the bits nfqws2 sets for per-app zapret.
      zapretInternalMarks = [
        536870912
        1073741824
      ];
      noDesyncBits =
        condition: value: label:
        forbiddenValues condition value perAppZapretDesyncMarks
          "proxy-suite: ${label} must not use per-app-zapret internal desync mark bits";
      tgWsBypass = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy;
    in
    [
      (forbiddenValues perAppZapretCfg.enable perAppZapretCfg.filterMark zapretInternalMarks
        "proxy-suite: perAppRouting.zapret.filterMark must not use zapret internal desync mark bits"
      )
      (noDesyncBits perAppZapretCfg.enable globalTproxy.fwmark "proxy.tproxy.fwmark")
      (noDesyncBits perAppZapretCfg.enable globalTproxy.proxyMark "proxy.tproxy.proxyMark")
      (noDesyncBits (
        perAppRoutingTun.enable && perAppZapretCfg.enable
      ) perAppRoutingTun.fwmark "perAppRouting.tun.fwmark")
      (noDesyncBits (
        perAppRoutingTproxy.enable && perAppZapretCfg.enable
      ) perAppRoutingTproxy.fwmark "perAppRouting.tproxy.fwmark")
      (noDesyncBits perAppZapretCfg.enable perAppZapretCfg.filterMark "perAppRouting.zapret.filterMark")
      (noDesyncBits (tgWsBypass && perAppZapretCfg.enable) tgWsProxyCfg.fwmark "tgWsProxy.fwmark")
    ];

  torCfg = cfg.tor;
  torOnionListeners =
    if torCfg.onionService.listeners == null then [ ] else torCfg.onionService.listeners;
  torOnionUnfit = map (ib: ib.tag) (
    builtins.filter (ib: !derived.proxyInboundOnionCapable ib) derived.torOnionInbounds
  );
  torOnionVirtualPorts = map (
    ib: if ib.listener.sharePort != null then ib.listener.sharePort else ib.listener.port
  ) derived.torOnionInbounds;
  whitelistBypassCfg = cfg.whitelistBypass;
  whitelistBypassAssertions = [
    (requireEnabled (
      derived.whitelistBypassJoiners != [ ]
    ) proxyEnabled "proxy-suite: whitelistBypass.joiners requires proxy.enable = true")
    (requireEnabled
      (
        whitelistBypassCfg.enable
        && lib.any (c: c.upstream == "proxy") (builtins.attrValues whitelistBypassCfg.creators)
      )
      proxyEnabled
      ''proxy-suite: whitelistBypass.creators.<name>.upstream = "proxy" requires proxy.enable = true''
    )
  ];

  torSnowflake = lib.any (line: lib.hasPrefix "snowflake " line) torCfg.bridges.lines;
  torAssertions = [
    (mkAssertion (
      !torCfg.enable || torCfg.asOutbound || torCfg.onionService.enable
    ) "proxy-suite: tor.enable = true needs tor.asOutbound or tor.onionService.enable")
    (requireEnabled (
      torCfg.enable && torCfg.asOutbound
    ) proxyEnabled "proxy-suite: tor.asOutbound requires proxy.enable = true")
    (requireEnabled (
      torCfg.enable && torCfg.upstream == "proxy"
    ) proxyEnabled ''proxy-suite: tor.upstream = "proxy" requires proxy.enable = true'')
    # Tor as the one outbound would be what the local proxy dials Tor's own relays through.
    (mkAssertion
      (
        !(
          derived.torOutboundEnabled
          && torCfg.upstream == "proxy"
          && lib.subtractLists [ derived.torOutboundTag ] effectiveOutboundTags == [ ]
          && !derived.hasSubscriptions
        )
      )
      ''proxy-suite: tor.upstream = "proxy" needs an outbound besides "tor" to reach Tor through; with tor the only one, Tor would dial its relays through itself''
    )
    (mkAssertion (!(torCfg.enable && torCfg.upstream == "proxy" && torSnowflake))
      ''proxy-suite: tor.bridges.lines has a snowflake bridge, which cannot follow tor.upstream = "proxy"; use obfs4, webtunnel or meek_lite bridges, or upstream = "direct"''
    )
    (mkAssertion (!(derived.torOutboundEnabled && builtins.elem derived.torOutboundTag outboundTags))
      "proxy-suite: the outbound tag \"tor\" belongs to tor.asOutbound; rename the proxy.outbounds entry"
    )
    (requireEnabled (
      torCfg.enable && torCfg.onionService.enable
    ) cfg.inbounds.enable "proxy-suite: tor.onionService.enable requires inbounds.enable = true")
    (mkAssertion
      (
        !derived.torOnionEnabled
        || builtins.all (tag: builtins.hasAttr tag cfg.inbounds.listeners) torOnionListeners
      )
      "proxy-suite: tor.onionService.listeners names listeners not in inbounds.listeners: ${
        lib.concatStringsSep ", " (
          builtins.filter (tag: !builtins.hasAttr tag cfg.inbounds.listeners) torOnionListeners
        )
      }"
    )
    (mkAssertion (!derived.torOnionEnabled || derived.torOnionInbounds != [ ])
      "proxy-suite: tor.onionService has no listener to serve: amneziawg, h3-only xhttp and raw JSON listeners cannot go over an onion"
    )
    (mkAssertion (!derived.torOnionEnabled || torOnionUnfit == [ ])
      "proxy-suite: tor.onionService.listeners cannot serve ${lib.concatStringsSep ", " torOnionUnfit}: an onion carries TCP only, so not amneziawg or h3-only xhttp, and raw JSON listeners have no known protocol"
    )
    (uniqueValues derived.torOnionEnabled torOnionVirtualPorts
      "proxy-suite: tor.onionService listeners must each share a distinct port (sharePort, or port)"
    )
    (mkAssertion
      (
        !derived.torOutboundEnabled
        || !(
          (proxyEnabled && proxyCfg.listener.port == torCfg.socksPort)
          || (proxyInboundsEnabled && builtins.elem torCfg.socksPort derived.proxyInboundPorts)
          || builtins.elem torCfg.socksPort (
            builtins.attrValues constants.xrayDnsBridgePorts ++ [ constants.outboundTestPort ]
          )
        )
      )
      "proxy-suite: tor.socksPort ${toString torCfg.socksPort} collides with another proxy-suite listener"
    )
  ];
in
rootlessAssertions
++ featureAssertions
++ torAssertions
++ whitelistBypassAssertions
++ perAppRoutingAssertions
++ localProxyAuthAssertions
++ secretAssertions
++ outboundAssertions
++ proxyInboundAssertions
++ awgInboundAssertions
++ subscriptionAssertions
++ collisionAssertions
++ positiveNumberAssertions
++ forbiddenValueAssertions
