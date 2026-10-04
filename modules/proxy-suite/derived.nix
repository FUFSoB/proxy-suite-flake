{
  lib,
  cfg,
}:

let
  proxyCfg = cfg.proxy;
  # Host paths: /var/lib/proxy-suite and /run on a system install.
  inherit (cfg.host) stateDir runtimeDir;
  singBoxCfg = proxyCfg // {
    enable = singBoxEnabled;
    package = proxyCfg.singBox.package;
    clashApiPort = proxyCfg.singBox.clashApiPort;
  };
  xrayCfg = proxyCfg.xray;
  proxyEnabled = proxyCfg.enable;
  # "hybrid" runs both; the pure* flags are what backend-specific code branches on.
  singBoxEnabled = proxyEnabled && proxyCfg.backend != "xray";
  xrayEnabled = proxyEnabled && proxyCfg.backend != "sing-box";
  hybridEnabled = proxyEnabled && proxyCfg.backend == "hybrid";
  pureXrayEnabled = proxyEnabled && proxyCfg.backend == "xray";
  activeBackend = if proxyEnabled then proxyCfg.backend else null;
  perAppRoutingCfg = cfg.perAppRouting;
  globalTun = proxyCfg.tun;
  globalTproxy = proxyCfg.tproxy;
  # Forwarding for what gateway clients send that TProxy does not take (ping, the LAN itself).
  tproxyLanSysctl =
    lib.optionalAttrs (proxyEnabled && globalTproxy.enable && globalTproxy.lanInterfaces != [ ])
      (
        {
          "net.ipv4.ip_forward" = 1;
        }
        // lib.optionalAttrs proxyCfg.ipv6 {
          "net.ipv6.conf.all.forwarding" = 1;
        }
      );
  # proxy.routing.ruleSets, with the format settled and the file sing-box reads.
  ruleSets = lib.mapAttrsToList (
    name: rs:
    let
      format =
        if rs.format != null then
          rs.format
        else if lib.hasSuffix ".srs" (lib.head (lib.splitString "?" rs.url)) then
          "binary"
        else
          "source";
    in
    rs
    // {
      inherit name format;
      path = "${constants.ruleSetsDir}/${name}.${if format == "binary" then "srs" else "json"}";
      # Its domain rules only, for DNS rules: sing-box 1.14 refuses an IP-only rule set there,
      # and a legacy address filter would send every other name to that rule's server first.
      dnsPath = "${constants.ruleSetsDir}/${name}.dns.json";
    }
  ) proxyCfg.routing.ruleSets;
  ruleSetsEnabled = proxyEnabled && ruleSets != [ ];
  # Some global tunnel for it to guard.
  killSwitchEnabled =
    cfg.killSwitch.enable
    && (proxyEnabled && (globalTun.enable || globalTproxy.enable) || awgGlobalAvailable);
  perAppRoutingTun = cfg.perAppRouting.tun;
  perAppRoutingTproxy = cfg.perAppRouting.tproxy;
  zapretCfg = cfg.zapret;
  zapretEngine = cfg.zapret.engine;
  perAppZapretCfg = cfg.perAppRouting.zapret;
  userControlCfg = cfg.userControl;
  sshProxyCfg = cfg.sshProxy;
  sshProxyOutboundTag = "ssh-proxy";
  sshProxyOutboundEnabled = sshProxyCfg.enable && sshProxyCfg.asOutbound;
  # Only sing-box dials SSH natively; XRay and standalone tunnels use the OpenSSH unit.
  sshProxyNativeOutbound = sshProxyOutboundEnabled && !pureXrayEnabled;
  sshProxyUnitEnabled = sshProxyCfg.enable && !sshProxyNativeOutbound;
  # The local proxy as the other services dial it: a wildcard listener is reached on loopback.
  # (The secret itself stays with whoever needs it on disk: derived.nix has no pkgs.)
  localProxy =
    let
      auth = proxyCfg.listener.auth;
      host =
        if
          builtins.elem proxyCfg.listener.address [
            "0.0.0.0"
            "::"
            ""
          ]
        then
          "127.0.0.1"
        else
          proxyCfg.listener.address;
    in
    {
      inherit auth host;
      hostPart = if lib.hasInfix ":" host then "[${host}]" else host;
      authEnabled = auth.username != null && (auth.password != null || auth.passwordFile != null);
    };

  # WARP devices: one "warp" unless warp.devices or warp.instances name more. The first keeps
  # what a single device had (its registration unit, state dir and ports), so a registration
  # made before carries over.
  warpDeviceNames =
    if cfg.warp.instances != null then
      map (i: "warp-${toString i}") (lib.range 1 cfg.warp.instances)
    else if cfg.warp.devices != { } then
      builtins.attrNames cfg.warp.devices
    else
      [ "warp" ];
  warpDevices = lib.imap0 (
    index: tag:
    let
      device =
        cfg.warp.devices.${tag} or {
          configFile = null;
          endpoint = null;
        };
      first = index == 0;
      configFile =
        if device.configFile != null then
          device.configFile
        else if first then
          cfg.warp.configFile
        else
          null;
      stateSubdir = if first then "warp" else "warp/${tag}";
    in
    {
      inherit
        tag
        first
        configFile
        stateSubdir
        ;
      endpoint = if device.endpoint != null then device.endpoint else cfg.warp.endpoint;
      # Without a configFile, its registration unit registers with wgcf into its state dir.
      autoRegister = cfg.warp.enable && configFile == null;
      profilePath =
        if configFile != null then configFile else "${stateDir}/${stateSubdir}/wgcf-profile.conf";
      registerUnit = if first then "proxy-suite-warp" else "proxy-suite-warp-register-${tag}";
      tunnelUnit = if first then "proxy-suite-warp-tunnel" else "proxy-suite-warp-tunnel-${tag}";
      # Loopback SOCKS listener of the sing-box tunnel, which the outbound dials, and its
      # "direct-in" listener, which tells a blocked WARP from a dead uplink.
      tunnelPort = if first then 18538 else 18900 + 2 * (index - 1);
      directPort = if first then 18539 else 18901 + 2 * (index - 1);
    }
  ) warpDeviceNames;
  warpCfg =
    cfg.warp
    // (builtins.head warpDevices)
    // {
      devices = warpDevices;
      autoRegister = builtins.any (d: d.autoRegister) warpDevices;
      # Two or more: "warp" is a group of them (warp.nix).
      grouped = builtins.length warpDevices > 1;
    };
  warpOutboundTag = "warp";
  # The sing-box tunnel; "userspace" and "interface" come in through the AmneziaWG profile list.
  warpOutboundEnabled = warpCfg.enable && warpCfg.asOutbound == "singBox";
  torCfg = cfg.tor // {
    # tor's DataDirectory; the onion service keeps its keys and hostname under it.
    dataDir = "${stateDir}/tor";
    onionDir = "${stateDir}/tor/onion";
  };
  torOutboundTag = "tor";
  torOutboundEnabled = torCfg.enable && torCfg.asOutbound;
  torRouteOnion = torOutboundEnabled && torCfg.routeOnion && proxyEnabled;

  # Joiners in name order, each an outbound on a loopback SOCKS listener of its own.
  whitelistBypassCfg = cfg.whitelistBypass;
  whitelistBypassJoiners = lib.optionals whitelistBypassCfg.enable (
    lib.imap0 (
      i: tag:
      whitelistBypassCfg.joiners.${tag}
      // {
        inherit tag;
        port = 18700 + i;
      }
    ) (builtins.attrNames whitelistBypassCfg.joiners)
  );

  # Two ports per "singBox" or "userspace" AmneziaWG outbound, above the autoProxy prober's own
  # listeners (proxy.autoProxy.probeBasePort, 18540 by default, one per exit):
  # both bind loopback, so an overlap leaves whichever unit starts second dead.
  awgTunnelBasePort = 18600;

  # AmneziaWG profiles are either global (proxy-ctl awg on) or outbounds tagged with their name.
  awgProfiles = lib.optionalAttrs cfg.amneziaWg.enable cfg.amneziaWg.profiles;
  awgGlobalProfiles = lib.filterAttrs (_: profile: profile.asOutbound == null) awgProfiles;
  awgOutbounds = lib.imap0 (
    index: name:
    let
      profile = awgProfiles.${name};
    in
    {
      inherit name;
      tag = name;
      kind = profile.asOutbound;
      interface = profile.interfaceName;
      inherit (profile) domainStrategy;
      # Loopback listeners of a "singBox" or "userspace" tunnel, as warpCfg.tunnelPort/directPort
      # (only sing-box listens on directPort).
      tunnelPort = awgTunnelBasePort + 2 * index;
      directPort = awgTunnelBasePort + 1 + 2 * index;
      # Only an "interface" one routes by it, and by this mark the apps sent into it.
      routeTable = constants.awgOutboundRouteTableBase + index;
      perAppFwmark = constants.awgPerAppFwmarkBase + index;
      perAppDnsPort = constants.awgPerAppDnsBasePort + index;
    }
  ) (builtins.filter (name: awgProfiles.${name}.asOutbound != null) (builtins.attrNames awgProfiles));
  awgInterfaceOutbounds = builtins.filter (ob: ob.kind == "interface") awgOutbounds;
  # Added with proxy-ctl at runtime: global profiles (`awg add`), as template instances
  # sharing runtime.interfaceName, need root; outbounds (`proxy outbounds add`) run in
  # wireproxy template instances, which the supervisor cannot template.
  awgRuntimeEnabled = cfg.amneziaWg.enable && cfg.amneziaWg.runtime.enable;
  awgRuntimeGlobal = awgRuntimeEnabled && cfg.host.privileged;
  awgRuntimeOutbounds = awgRuntimeEnabled && proxyEnabled && cfg.host.serviceManager != "supervisor";
  # Of those, ones on an AmneziaWG interface of their own (`outbounds add --interface`): root only.
  awgRuntimeIfaceOutbounds = awgRuntimeOutbounds && cfg.host.privileged;
  # Some global profile may run: declared, or added at runtime.
  awgGlobalAvailable = awgGlobalProfiles != { } || awgRuntimeGlobal;
  # Profiles run behind a loopback SOCKS hop rather than an interface.
  awgTunnelOutbounds = builtins.filter (ob: ob.kind != "interface") awgOutbounds;
  # `proxy-ctl apps run --via <tag>` straight into an "interface" outbound: the marks it gives
  # the apps, which the other per-app and global chains let past.
  perAppViaInterfaceOutbounds = lib.optionals (
    cfg.perAppRouting.enable && cfg.host.privileged
  ) awgInterfaceOutbounds;
  perAppViaRuntime = cfg.perAppRouting.enable && awgRuntimeIfaceOutbounds;
  # Or a global profile (declared, or added with `awg add`), brought up for the apps alone.
  perAppViaProfiles =
    cfg.perAppRouting.enable && cfg.host.privileged && (awgGlobalProfiles != { } || awgRuntimeGlobal);
  # A per-app profile's `outbound`: "awg:<name>" a global profile, "outbound:<tag>" an
  # outbound, a bare name whichever it is. { kind; name; } with kind "awg", "outbound" or "".
  perAppViaTarget =
    outbound:
    let
      parts = builtins.match "(awg|outbound):(.*)" outbound;
    in
    if parts == null then
      {
        kind = "";
        name = outbound;
      }
    else
      {
        kind = builtins.head parts;
        name = builtins.elemAt parts 1;
      };
  # Whether it takes the app into an AmneziaWG interface directly ("interface" outbound, or a
  # global profile, perhaps one `awg add` adds), with no per-app method; and whether a bare
  # name is both a global profile and a declared outbound.
  perAppViaDirect =
    outbound:
    let
      target = perAppViaTarget outbound;
    in
    (target.kind != "awg" && builtins.any (ob: ob.tag == target.name) perAppViaInterfaceOutbounds)
    || (
      target.kind != "outbound"
      && perAppViaProfiles
      && (builtins.hasAttr target.name awgGlobalProfiles || target.kind == "awg")
    );
  perAppViaAmbiguous =
    outbound:
    let
      target = perAppViaTarget outbound;
    in
    target.kind == ""
    && builtins.hasAttr target.name awgGlobalProfiles
    && builtins.elem target.name (map (ob: ob.tag) proxyCfg.outbounds);
  # `apps run --via` any other outbound: a pin slot of per-app TProxy or TUN, which the
  # backend sends to that outbound through a selector (sing-box only, for its Clash API).
  perAppPinSlots = cfg.perAppRouting.via.pinSlots;
  perAppPinEnabled =
    cfg.perAppRouting.enable && singBoxEnabled && cfg.host.privileged && perAppPinSlots > 0;
  perAppPinTproxy = perAppPinEnabled && cfg.perAppRouting.tproxy.enable;
  perAppPinTun = perAppPinEnabled && cfg.perAppRouting.tun.enable;
  perAppViaMarks =
    map (ob: ob.perAppFwmark) perAppViaInterfaceOutbounds
    ++ lib.optionals perAppViaRuntime (
      lib.genList (slot: constants.awgRuntimeIfacePerAppFwmarkBase + slot) constants.awgRuntimeIfaceSlots
    )
    ++ lib.optionals perAppViaProfiles (
      lib.genList (slot: constants.awgAppPerAppFwmarkBase + slot) constants.awgAppSlots
    );

  proxyInboundsCfg = cfg.inbounds;
  proxyInboundsEnabled = proxyInboundsCfg.enable;

  # Listeners as a list, with `via` resolved against the default.
  # By order, then tag: the attrset yields tags alphabetically and the sort is stable.
  proxyInbounds = builtins.sort (a: b: a.listener.order < b.listener.order) (
    lib.mapAttrsToList (tag: listener: {
      inherit tag listener;
      via = if listener.via == null then proxyInboundsCfg.routing.via else listener.via;
    }) proxyInboundsCfg.listeners
  );

  # inbounds.runtime: listeners added with proxy-ctl may exit by these, so everything built
  # per exit (rules, outbounds, the local proxy, name resolution) is there for them too.
  proxyInboundsRuntimeEnabled = proxyInboundsEnabled && proxyInboundsCfg.runtime.enable;
  proxyInboundsRuntimeVias = lib.optionals proxyInboundsRuntimeEnabled (
    lib.unique ([ proxyInboundsCfg.routing.via ] ++ proxyInboundsCfg.runtime.vias ++ [ "block" ])
  );
  # Every exit a listener has or may get.
  proxyInboundsVias = map (ib: ib.via) proxyInbounds ++ proxyInboundsRuntimeVias;

  # inbounds.routing.serverSource: an address per inbound user (by XRay's email, the user's
  # name), which XRay sends that user's connections to this host from.
  proxyInboundsServerSource = proxyInboundsCfg.routing.serverSource;
  proxyInboundsSelfSources =
    let
      src = proxyInboundsServerSource;
      # The users XRay's listeners accept (by name, XRay's email): numbered by their order,
      # the rest after the highest order, by name.
      names = lib.unique (
        lib.concatMap (ib: map (user: user.name) ib.listener.users) (
          builtins.filter (ib: ib.listener.type != "amneziawg") proxyInbounds
        )
      );
      orderOf = name: proxyInboundsCfg.users.${name}.order;
      ordered = builtins.filter (name: orderOf name != null) names;
      highest = lib.foldl lib.max 0 (map orderOf ordered);
      numbered =
        map (name: {
          email = name;
          number = orderOf name;
        }) ordered
        ++ lib.imap1 (i: name: {
          email = name;
          number = highest + i;
        }) (lib.sort lib.lessThan (builtins.filter (name: orderOf name == null) names));
      octets =
        cidr:
        map lib.toInt (lib.take 4 (builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.([0-9]+)/[0-9]+" cidr));
      v4Int = cidr: lib.foldl (acc: o: acc * 256 + o) 0 (octets cidr);
      v4String =
        n:
        lib.concatMapStringsSep "." (shift: toString (lib.mod (n / shift) 256)) [
          16777216
          65536
          256
          1
        ];
      v6Prefix = cidr: builtins.head (lib.splitString "/" cidr);
    in
    lib.optionals (src.ipv4 != null || src.ipv6 != null) (
      map (
        { email, number }:
        {
          inherit email number;
          id = toString number;
          ipv4 = if src.ipv4 == null then null else v4String (v4Int src.ipv4 + number);
          ipv6 =
            if src.ipv6 == null then null else "${v6Prefix src.ipv6}${lib.toLower (lib.toHexString number)}";
        }
      ) (lib.sort (a: b: a.number < b.number) numbered)
    );

  # .onion names from clients go to the local proxy, whose rule hands them to Tor, whatever
  # the listener's via. AmneziaWG listeners never pass XRay's routing.
  proxyInboundsRouteOnion =
    torRouteOnion
    && (
      lib.any (ib: ib.via != "block" && ib.listener.type != "amneziawg") proxyInbounds
      || proxyInboundsRuntimeEnabled
    );

  # Whether any listener or inbounds.routing.proxy exception relays through the local SOCKS
  # listener.
  proxyInboundsNeedLocalProxy =
    builtins.elem "proxy" proxyInboundsVias
    || proxyInboundsRouteOnion
    || lib.any (field: proxyInboundsCfg.routing.proxy.${field} != [ ]) [
      "domains"
      "ips"
      "geosites"
      "geoips"
    ];

  # Names pass unresolved unless XRay dials itself (a direct listener, or pure XRay).
  proxyInboundsResolveInSingBox = !pureXrayEnabled && !builtins.elem "direct" proxyInboundsVias;

  # Even when XRay resolves (a direct listener), it hands sing-box the name, which sing-box
  # looks up again: guard there too.
  proxyInboundsGuardPrivate =
    proxyInboundsEnabled
    && proxyInboundsCfg.routing.blockPrivate
    && proxyInboundsNeedLocalProxy
    && !pureXrayEnabled;
  # The guard's resolved addresses are dialed in its order, so it follows WARP's preference.
  proxyInboundsGuardStrategy =
    if proxyCfg.dns.strategy == null && warpCfg.enable && warpCfg.asOutbound != null then
      warpCfg.domainStrategy
    else
      null;

  # Other vias name static outbounds, rendered into the inbound service's own config.
  proxyInboundViaTags = lib.unique (
    builtins.filter (via: !builtins.elem via builtinTags) proxyInboundsVias
  );
  # The pinned outbounds and every hop they chain through, which the inbound service renders
  # too. A hop that is not a static outbound (a subscription entry, warp) has no tag here.
  proxyInboundViaHops =
    tags:
    let
      hops = lib.unique (
        builtins.filter (hop: hop != null && !builtins.elem hop tags) (
          map (ob: ob.detour) (builtins.filter (ob: builtins.elem ob.tag tags) proxyCfg.outbounds)
        )
      );
    in
    if hops == [ ] then tags else proxyInboundViaHops (tags ++ hops);
  proxyInboundViaChain = proxyInboundViaHops proxyInboundViaTags;
  proxyInboundViaOutbounds = builtins.filter (
    ob: builtins.elem ob.tag proxyInboundViaChain
  ) proxyCfg.outbounds;

  # AmneziaWG listeners: the interface's TCP and UDP is diverted to a loopback XRay inbound,
  # one port per listener above the AmneziaWG outbound tunnels (awgTunnelBasePort).
  awgInboundBasePort = 18700;
  proxyInboundsAwg = lib.imap0 (
    index: ib:
    let
      awg = ib.listener.amneziaWg;
    in
    {
      inherit (ib) tag via;
      inherit (ib.listener) port;
      inherit (awg) mode subnet subnet6;
      interface = awg.interfaceName;
      internalPort = awgInboundBasePort + index;
      # Dual-stack when the clients have IPv6, so one inbound takes both families.
      internalListen = if awg.subnet6 != null then "::" else "127.0.0.1";
      stateFile = "${stateDir}/awg-inbounds/${ib.tag}/state.json";
    }
  ) (builtins.filter (ib: ib.listener.type == "amneziawg") proxyInbounds);

  proxyInboundUdpTypes = [
    "amneziawg"
    "hysteria2"
    "shadowsocks"
    "socks"
  ];
  proxyInboundPorts = lib.unique (map (ib: ib.listener.port) proxyInbounds);
  # Loopback listeners are fronted locally; their ports stay closed.
  proxyInboundsPublic = builtins.filter (
    ib:
    !(
      lib.hasPrefix "127." ib.listener.address
      || builtins.elem ib.listener.address [
        "::1"
        "localhost"
      ]
    )
  ) proxyInbounds;
  # QUIC listeners are UDP-only: hysteria2, and h3-only xhttp, which leaves the TCP port to a
  # web server.
  proxyInboundIsUdpOnly =
    l:
    l.type == "hysteria2"
    || l.type != null && l.transport.type == "xhttp" && l.tls.enable && l.tls.alpn == [ "h3" ];
  # What an onion service can carry: TCP to a listener with a known protocol.
  proxyInboundOnionCapable =
    ib:
    ib.listener.type != null && ib.listener.type != "amneziawg" && !proxyInboundIsUdpOnly ib.listener;
  torOnionEnabled = torCfg.enable && torCfg.onionService.enable && proxyInboundsEnabled;
  torOnionInbounds =
    if !torOnionEnabled then
      [ ]
    else if torCfg.onionService.listeners == null then
      builtins.filter proxyInboundOnionCapable proxyInbounds
    else
      builtins.filter (ib: builtins.elem ib.tag torCfg.onionService.listeners) proxyInbounds;
  proxyInboundFirewallPorts = lib.unique (
    map (ib: ib.listener.port) (
      builtins.filter (
        ib: !proxyInboundIsUdpOnly ib.listener && ib.listener.type != "amneziawg"
      ) proxyInboundsPublic
    )
  );
  # inbounds.runtime.ports, both protocols: what a runtime listener serves is not known here.
  proxyInboundRuntimePorts = lib.optionals (proxyInboundsRuntimeEnabled) proxyInboundsCfg.runtime.ports;
  proxyInboundRuntimeSinglePorts = builtins.filter builtins.isInt proxyInboundRuntimePorts;
  proxyInboundRuntimePortRanges = map (
    range:
    let
      bounds = map lib.toInt (lib.splitString "-" range);
    in
    {
      from = builtins.elemAt bounds 0;
      to = builtins.elemAt bounds 1;
    }
  ) (builtins.filter builtins.isString proxyInboundRuntimePorts);
  # A raw-JSON listener could serve anything, so open both protocols for it.
  proxyInboundFirewallUdpPorts = lib.unique (
    map (ib: ib.listener.port) (
      builtins.filter (
        ib:
        ib.listener.type == null
        || builtins.elem ib.listener.type proxyInboundUdpTypes
        || proxyInboundIsUdpOnly ib.listener
      ) proxyInboundsPublic
    )
  );

  selectionMode = proxyCfg.selection;
  builtinTags = [
    "proxy"
    "direct"
    "block"
  ];
  outboundTags = map (ob: ob.tag) proxyCfg.outbounds;
  effectiveOutboundTags =
    outboundTags
    ++ lib.optional sshProxyOutboundEnabled sshProxyOutboundTag
    ++ lib.optionals warpOutboundEnabled (map (d: d.tag) warpDevices)
    ++ lib.optional torOutboundEnabled torOutboundTag
    ++ map (j: j.tag) whitelistBypassJoiners
    ++ map (ob: ob.tag) awgOutbounds;
  subscriptionTags = map (sub: sub.tag) proxyCfg.subscriptions;
  groupTags = builtins.attrNames proxyCfg.groups;
  # proxy-suite-outbound-groups moves failover groups, and "failover" selection, along. Runtime
  # groups can be failover too, so it runs with every Clash API; with nothing to watch it idles.
  outboundGroupsWatch = proxyEnabled && clashApiEnabled;
  # proxy-suite-clash-api: the Clash API for those in the groups, as their scopes allow; the
  # secret itself stays root's. With listener.auth alone, userControl.group only reads.
  clashBrokerEnabled =
    proxyEnabled
    && clashApiEnabled
    && cfg.host.privileged
    && (userControlEnabled || localProxy.authEnabled);
  clashBrokerGroups =
    if userControlEnabled then userControlGroupScopes else { ${userControlCfg.group} = [ ]; };

  hasStaticOutbounds = proxyCfg.outbounds != [ ];
  hasSubscriptions = proxyCfg.subscriptions != [ ];
  hasAvailableOutbounds =
    hasStaticOutbounds
    || hasSubscriptions
    || sshProxyOutboundEnabled
    || warpOutboundEnabled
    || torOutboundEnabled
    || whitelistBypassJoiners != [ ]
    || awgOutbounds != [ ];
  collapseNamedOutbounds = selectionMode == "first";
  # Always on with sing-box: `proxy-ctl proxy outbounds test` needs it in every selection mode.
  clashApiEnabled = singBoxEnabled;
  perAppZapretEnabled = perAppZapretCfg.enable;
  # The system-wide instance; per-app zapret runs its own.
  zapretGlobalEnabled = zapretCfg.enable && zapretCfg.global.enable;
  zapretCutoffEnabled =
    zapretEngine == "zapret2" && zapretCfg.enable && zapretCfg.zapret2.cutoff.enable;
  # The cut-off networks no whitelisted name fixes go through the proxy outbound.
  zapretCutoffProxyFallback =
    zapretCutoffEnabled && zapretCfg.zapret2.cutoff.proxyFallback && hasAvailableOutbounds;
  # directSync for what zapret2 pins and learns at runtime: a rule-set the proxy reloads.
  # The fixed lists go in with the routing rules (rules-zapret-direct.nix).
  zapret2DirectSync = zapretEngine == "zapret2" && zapretGlobalEnabled && zapretCfg.directSync.enable;
  # What zapret2 cannot fix (detect.lua's verdicts) goes through the proxy outbound.
  zapret2ProxyFallback =
    zapretEngine == "zapret2"
    && zapretGlobalEnabled
    && zapretCfg.zapret2.proxyFallback
    && hasAvailableOutbounds;
  userControlEnabled = userControlCfg.enable;
  # Whether userControl.group, which owns proxy-suite's files, holds a scope; no scopes
  # listed means all of them. The groups in userControl.groups get theirs through ACLs.
  userControlAllows =
    scope:
    userControlEnabled && (userControlCfg.scopes == [ ] || builtins.elem scope userControlCfg.scopes);
  # Every group and what it may do, "none listed" spelled out as every scope.
  userControlGroupScopes = lib.optionalAttrs userControlEnabled (
    lib.mapAttrs (_: scopes: if scopes == [ ] then import ./options/user-control-scopes.nix else scopes)
      (
        lib.mapAttrs (_: g: g.scopes) userControlCfg.groups
        // {
          ${userControlCfg.group} = userControlCfg.scopes;
        }
      )
  );
  # The groups in userControl.groups that hold a scope.
  userControlExtraGroupsFor =
    scope:
    builtins.filter (g: g != userControlCfg.group && builtins.elem scope userControlGroupScopes.${g}) (
      builtins.attrNames userControlGroupScopes
    );
  # Whether any group holds it.
  userControlAnyAllows = scope: userControlAllows scope || userControlExtraGroupsFor scope != [ ];
  userControlExtraGroups = lib.optionals userControlEnabled (
    builtins.attrNames userControlCfg.groups
  );
  managerFlag = lib.optionalString (cfg.host.serviceManager == "systemd-user") " --user";
  constants = {
    inherit stateDir runtimeDir;
    inherit (cfg.host) privileged serviceManager;

    # Daemons (sing-box, XRay, the WARP tunnel, OpenSSH, tg-ws-proxy, wgcf) run as this
    # user. Its group is not the userControl group: backend configs hold credentials. Start
    # scripts still read secrets and program routing as root, then exec the daemon through
    # runAsServiceUser with only the capabilities it needs.
    # On a rootless host everything already runs as the user: no service user, and
    # nothing to hand files over to it.
    serviceUser = "proxy-suite-daemon";
    # Shell text that only matters when the services run as root.
    ifPrivileged = lib.optionalString cfg.host.privileged;
    # The commands scripts manage units and read their logs with: the units live in the
    # user's manager on a home-manager host, and in proxy-suitectl on nix-on-droid.
    systemctl = cfg.host.systemctl + managerFlag;
    journalctl = cfg.host.journalctl + managerFlag;
    runAsServiceUser =
      pkgs: caps:
      let
        keep = lib.concatMapStrings (cap: ",+${cap}") caps;
      in
      lib.optionalString cfg.host.privileged (
        "${pkgs.util-linux}/bin/setpriv --reuid=proxy-suite-daemon --regid=proxy-suite-daemon --clear-groups"
        + " --inh-caps=-all${keep} --ambient-caps=-all${keep} --bounding-set=-all${keep} --no-new-privs --"
      );
    # The same for a unit that needs no root at all; "+" ExecStartPre/ExecStopPost
    # commands still run privileged.
    unprivilegedServiceConfig =
      caps:
      let
        systemdCaps = map (cap: "CAP_${lib.toUpper cap}") caps;
      in
      lib.optionalAttrs cfg.host.privileged {
        User = "proxy-suite-daemon";
        Group = "proxy-suite-daemon";
        AmbientCapabilities = systemdCaps;
        CapabilityBoundingSet = systemdCaps;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "full";
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    # For a unit that stays root but works in a directory the userControl group writes to:
    # the file system read-only but for its own State-, Runtime- and private Tmp
    # directories, so a symlink the group plants there leads root's writes nowhere else.
    rootInSharedDirConfig = lib.optionalAttrs cfg.host.privileged {
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
    # POSIX ACLs for the groups in userControl.groups, which cannot own a file the way
    # userControl.group does. Shell text, for root.
    # grantFileAcl: after a file's chmod (which sets the ACL mask), `perm` for each group.
    grantFileAcl =
      pkgs: path: groups: perm:
      lib.optionalString (cfg.host.privileged && groups != [ ]) ''
        ${pkgs.acl}/bin/setfacl -m ${lib.concatMapStringsSep "," (g: "g:${g}:${perm}") groups} -- ${path}
      '';
    # grantDirAcl: a directory and all in it, for each group, and what is made in it later
    # (default entries). What was granted before is taken away first, so a group dropped
    # from the configuration loses access; -b keeps each file's effective bits. Nothing for
    # a directory not there yet. -P: never through a symlink a member left in it; a unit
    # running it keeps the rest of the file system read-only as well.
    # -n: each file keeps its mask, its group bits, so a group gets no more than the
    # file's own group would: nothing of a 0600 key. Recalculated, the mask would take
    # `perm` whole.
    grantDirAcl =
      pkgs: path: groups: perm:
      lib.optionalString cfg.host.privileged ''
        if [ -d ${path} ]; then
          ${pkgs.acl}/bin/setfacl -R -P -b -- ${path}
          ${lib.optionalString (groups != [ ]) ''
            ${pkgs.acl}/bin/setfacl -R -P -n -m ${
              lib.concatMapStringsSep "," (g: "g:${g}:${perm},d:g:${g}:${perm}") groups
            } -- ${path}
          ''}
        fi
      '';
    # Socket marks and IP_TRANSPARENT, TUN and auto_redirect, listeners below 1024, ICMP.
    backendCaps = [
      "net_admin"
      "net_bind_service"
      "net_raw"
    ];

    zapret2StateDir = "${stateDir}/zapret2";
    # The running global instance's strategy map, which proxy-ctl names state.tsv's rows by.
    zapret2StrategiesFile = "${runtimeDir}/proxy-suite-zapret/strategies.json";
    # Not under zapret2/, which the zapret scope's group writes to: root works here by
    # fixed names (the group asks for probes in requests/).
    zapret2CutoffDir = "${stateDir}/zapret2-cutoff";
    # The same for the rule-set of zapret2's runtime hosts: what is in it skips the proxy.
    zapret2DirectDir = "${stateDir}/zapret2-direct";
    # Conntrack bit on the cutoff probe's own connections, which zapret2 leaves alone.
    zapret2CutoffProbeCtMark = 33554432; # 0x2000000

    # NFQUEUE of the global zapret instance, per engine. Both are the engine's own
    # default, which proxy-suite never overrides; the per-app instance opens a
    # second queue and must not land on this one.
    zapretGlobalQnum = {
      zapret-discord-youtube = 200;
      zapret2 = 300;
    };

    autoProxyStateDir = "${stateDir}/autoproxy";

    # Runtime outbound control. The spool dirs hold one proxy URL per file and are
    # group-writable when userControl is on, so proxy-ctl edits them without sudo;
    # the pin outlives a reboot, unlike the per-boot route-mode override.
    pinnedOutboundFile = "${stateDir}/pinned-outbound";
    runtimeOutboundsDir = "${stateDir}/outbounds.d";
    runtimeSubscriptionsDir = "${stateDir}/subscriptions.d";
    # inbounds.runtime: users/<name>.json and listeners/<tag>.json (scripts/inbound_runtime.py).
    runtimeInboundsDir = "${stateDir}/inbounds.d";
    # Per-app profiles added with `proxy-ctl apps add`: <name>.json, next to the declared ones.
    runtimeAppsDir = "${stateDir}/apps.d";
    # Shell function for the scripts that read those spools as root. $1 a file: in a spool,
    # a regular file only, and never through a symlink, which would hand over any file root
    # can read (a share link or an error message then shows it), nor a FIFO, which would
    # hang the start. Declared files elsewhere (a sops symlink, say) are read as they are.
    readSourceFunction = pkgs: ''
      _proxy_suite_read_source() {
        case "$1" in
          ${stateDir}/outbounds.d/* | ${stateDir}/subscriptions.d/*)
            if [ ! -f "$1" ] || [ -L "$1" ]; then
              echo "proxy-suite: $1 is not a regular file" >&2
              return 1
            fi
            # A MiB at most: an entry is a URL or one outbound, and the start script holds
            # what it reads in shell variables.
            ${pkgs.coreutils}/bin/dd if="$1" iflag=nofollow,nonblock,fullblock bs=1M count=1 status=none
            ;;
          *) ${pkgs.coreutils}/bin/cat -- "$1" ;;
        esac
      }
    '';
    # Written by every backend start script; proxy-ctl reads the socks copy.
    outboundInventoryFile = "${runtimeDir}/proxy-suite-socks/outbounds.json";
    clashBrokerSocket = "${runtimeDir}/proxy-suite-clash/api.sock";

    inboundStatsApiSocket = "${runtimeDir}/proxy-suite-inbounds/api/stats.sock";
    # Mark and table sending the AmneziaWG listeners' diverted packets to the local stack,
    # clear of proxy.tproxy's and perAppRouting's (asserted).
    awgInboundFwmark = 20;
    awgInboundRouteTable = 103;
    awgInboundRulePriority = 8990;
    # A global AmneziaWG profile's own packets carry this mark (awg-quick's default table,
    # pinned so the kill switch knows it), and its unit runs with this group, whose lookups
    # (an Endpoint's name) get past the kill switch.
    awgGlobalFwmark = 51820;
    awgGlobalGroup = "proxy-suite-awg";
    # An "interface" AmneziaWG outbound's table (the base plus its index) and the rule
    # sending sockets bound to the interface there, clear of the tables above.
    awgOutboundRouteTableBase = 110;
    awgOutboundRulePriority = 8991;
    # A global AmneziaWG profile's rules keeping the host's UDP services on the main table.
    awgServerUdpRulePriority = 8989;
    # Apps run `--via` an "interface" AmneziaWG outbound: their mark (the base plus its
    # index) sends them to its table, ahead of every other rule here (the XRay TUN's from
    # 8992, sing-box's at tunAutoRouteRulePriority) and awg-quick's; the next rule turns
    # them away while that table has no route.
    awgPerAppFwmarkBase = 23040;
    awgPerAppRulePriority = 8986;
    awgPerAppUnreachablePriority = 8987;
    # Their lookups go to a forwarder on loopback (scripts/per_app_dns.py), one port each,
    # above the WARP devices' tunnels (18900 up, two each).
    awgPerAppDnsBasePort = 19100;
    # Global profiles and outbounds added with proxy-ctl: <name>.conf here, and
    # <tag>.awg with <tag>.port in runtimeOutboundsDir.
    runtimeAwgDir = "${stateDir}/amneziawg.d";
    # Loopback SOCKS listeners of the runtime AmneziaWG outbounds, one per slot.
    awgRuntimeTunnelBasePort = 18800;
    awgRuntimeTunnelSlots = 32;
    # Runtime "interface" outbounds: slot n in <tag>.iface is interface psawgr<n>, with the
    # table, per-app mark and per-app DNS port at these bases plus n, clear of the declared
    # outbounds' (asserted).
    awgRuntimeIfacePrefix = "psawgr";
    awgRuntimeIfaceSlots = 16;
    awgRuntimeIfaceTableBase = 150;
    awgRuntimeIfacePerAppFwmarkBase = 23040 + 64;
    awgRuntimeIfaceDnsBasePort = 19100 + 40;
    # Global profiles apps run through (proxy-suite-awg-app@): slot n is interface psawga<n>,
    # with the table, per-app mark and DNS port at these bases plus n.
    awgAppIfacePrefix = "psawga";
    awgAppSlots = 8;
    awgAppTableBase = 210;
    awgAppPerAppFwmarkBase = 23232;
    awgAppDnsBasePort = 19190;
    # Pin slots: slot n of per-app TProxy is the backend's listener at the port base plus n,
    # its mark and table at those bases plus n; one of per-app TUN is the source its packets
    # are SNATed to as they enter the TUN, by its own mark and table. Each is a selector
    # proxy-suite-pin-<route>-<n>, switched through the Clash API (the per-app TUN backend's
    # own).
    perAppPinRulePriority = 8988;
    perAppPinTproxyFwmarkBase = 23168;
    perAppPinTunFwmarkBase = 23200;
    perAppPinTproxyTableBase = 170;
    perAppPinTunTableBase = 190;
    perAppPinTproxyPortBase = 19160;
    perAppPinTunSource = slot: {
      ipv4 = "172.20.1.${toString (slot + 2)}";
      ipv6 = "fd66:21::${lib.toLower (lib.toHexString (slot + 2))}";
    };
    perAppTunClashApiPort = 19180;
    # sing-box's fake IP caches, one per TUN config; the start script hands it to the backend.
    fakeIpCacheDir = "${stateDir}/fakeip";
    # Downloaded proxy.routing.ruleSets, one file each, written by the service user.
    ruleSetsDir = "${stateDir}/rulesets";
    # Loopback listener behind the selector `proxy-ctl proxy outbounds test` switches.
    outboundTestPort = 18537;
    inboundStatsFile = "${stateDir}/inbound-stats.json";
    # Written by proxy-suite-tor as it starts, before it reaches the network.
    torOnionHostnameFile = "${stateDir}/tor/onion/hostname";
    # proxy-ctl tor status|newnym.
    torControlSocket = "${runtimeDir}/proxy-suite-tor/control/socket";

    # sing-box DNS server resolving through an "interface" AmneziaWG outbound.
    awgDnsServerTag = tag: "awg-dns-${tag}";

    tunAutoRouteTableIndex = 2022;
    tunAutoRouteRulePriority = 9000;
    # Pure-XRay global TUN, below 8998/8999 (AmneziaWG and tg-ws-proxy bypasses).
    # proxyMark sockets and proxy-suite's own daemons (the inbound XRay, replies to its
    # clients included) stay out of the TUN.
    xrayTunMarkBypassRulePriority = 8992;
    xrayTunServiceUserRulePriority = 8993;
    xrayTunPerAppTunRulePriority = 8995;
    # DNS stays in the TUN for fakedns, even to a LAN resolver.
    xrayTunDnsRulePriority = 8996;
    # Routes more specific than default (LAN, container bridges) skip the TUN, so
    # replies to connections from there leave the way they came.
    xrayTunMainRulePriority = 8997;

    globalTunIPv6Address = "fd66:19::1/64";
    globalTunIPv6RoutePrefix = "fd66:19::/64";
    perAppTunIPv6Address = "fd66:20::1/64";
    perAppTunIPv6RoutePrefix = "fd66:20::/64";

    xrayDnsBridgePorts = {
      socks = 18533;
      tun = 18534;
      perAppTun = 18535;
    };

    # One loopback VLESS inbound per stack's XRay sidecar, however many outbounds it carries.
    xraySidecarPorts = {
      socks = 33080;
      tun = 33180;
      perAppTun = 33280;
    };
  };

  # Subscription tags are deliberately not accepted: they only exist at runtime.
  invalidInboundViaTargets = builtins.filter (
    tag: !builtins.elem tag outboundTags
  ) proxyInboundViaChain;

  invalidRoutingTargets = lib.unique (
    map (rule: rule.outbound) (
      builtins.filter (
        rule: !builtins.elem rule.outbound (builtinTags ++ effectiveOutboundTags ++ groupTags)
      ) proxyCfg.routing.rules
    )
  );
in
{
  inherit
    proxyCfg
    localProxy
    singBoxCfg
    xrayCfg
    proxyEnabled
    singBoxEnabled
    xrayEnabled
    hybridEnabled
    pureXrayEnabled
    activeBackend
    perAppRoutingCfg
    globalTun
    globalTproxy
    tproxyLanSysctl
    killSwitchEnabled
    ruleSets
    ruleSetsEnabled
    perAppRoutingTun
    perAppRoutingTproxy
    zapretCfg
    zapretEngine
    perAppZapretCfg
    perAppZapretEnabled
    zapretGlobalEnabled
    zapretCutoffEnabled
    zapretCutoffProxyFallback
    zapret2DirectSync
    zapret2ProxyFallback
    userControlCfg
    userControlEnabled
    userControlAllows
    userControlGroupScopes
    userControlExtraGroupsFor
    userControlAnyAllows
    userControlExtraGroups
    sshProxyCfg
    sshProxyOutboundEnabled
    sshProxyNativeOutbound
    sshProxyUnitEnabled
    warpCfg
    warpOutboundEnabled
    warpDeviceNames
    torCfg
    torOutboundTag
    torOutboundEnabled
    torRouteOnion
    whitelistBypassCfg
    whitelistBypassJoiners
    torOnionEnabled
    torOnionInbounds
    proxyInboundOnionCapable
    awgGlobalProfiles
    awgGlobalAvailable
    awgRuntimeGlobal
    awgRuntimeOutbounds
    awgRuntimeIfaceOutbounds
    awgOutbounds
    awgInterfaceOutbounds
    awgTunnelOutbounds
    perAppViaInterfaceOutbounds
    perAppViaRuntime
    perAppViaProfiles
    perAppViaTarget
    perAppViaDirect
    perAppViaAmbiguous
    perAppViaMarks
    perAppPinSlots
    perAppPinEnabled
    perAppPinTproxy
    perAppPinTun
    proxyInboundsCfg
    proxyInboundsEnabled
    proxyInbounds
    proxyInboundsRuntimeEnabled
    proxyInboundsRuntimeVias
    proxyInboundRuntimePorts
    proxyInboundRuntimeSinglePorts
    proxyInboundRuntimePortRanges
    proxyInboundsAwg
    proxyInboundIsUdpOnly
    proxyInboundsRouteOnion
    proxyInboundsNeedLocalProxy
    proxyInboundsResolveInSingBox
    proxyInboundsServerSource
    proxyInboundsSelfSources
    proxyInboundsGuardPrivate
    proxyInboundsGuardStrategy
    proxyInboundViaTags
    proxyInboundViaOutbounds
    invalidInboundViaTargets
    proxyInboundPorts
    proxyInboundFirewallPorts
    proxyInboundFirewallUdpPorts
    constants
    selectionMode
    builtinTags
    outboundTags
    effectiveOutboundTags
    subscriptionTags
    groupTags
    outboundGroupsWatch
    clashBrokerEnabled
    clashBrokerGroups
    hasSubscriptions
    hasAvailableOutbounds
    collapseNamedOutbounds
    clashApiEnabled
    invalidRoutingTargets
    ;
}
