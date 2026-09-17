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
  pureSingBoxEnabled = proxyEnabled && proxyCfg.backend == "sing-box";
  pureXrayEnabled = proxyEnabled && proxyCfg.backend == "xray";
  activeBackend = if proxyEnabled then proxyCfg.backend else null;
  perAppRoutingCfg = cfg.perAppRouting;
  globalTun = proxyCfg.tun;
  globalTproxy = proxyCfg.tproxy;
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
  warpCfg = cfg.warp // {
    # Without a configFile, proxy-suite-warp registers with wgcf into its state dir.
    autoRegister = cfg.warp.enable && cfg.warp.configFile == null;
    profilePath =
      if cfg.warp.configFile != null then cfg.warp.configFile else "${stateDir}/warp/wgcf-profile.conf";
    # Loopback SOCKS listener of proxy-suite-warp-tunnel, which the "warp" outbound dials.
    tunnelPort = 18538;
    # Its "direct-in" listener, which tells a blocked WARP from a dead uplink.
    directPort = 18539;
  };
  warpOutboundTag = "warp";
  # The sing-box tunnel; "userspace" and "interface" come in through the AmneziaWG profile list.
  warpOutboundEnabled = warpCfg.enable && warpCfg.asOutbound == "singBox";

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
      # Loopback listeners of a "singBox" or "userspace" tunnel, as warpCfg.tunnelPort/directPort
      # (only sing-box listens on directPort).
      tunnelPort = awgTunnelBasePort + 2 * index;
      directPort = awgTunnelBasePort + 1 + 2 * index;
    }
  ) (builtins.filter (name: awgProfiles.${name}.asOutbound != null) (builtins.attrNames awgProfiles));
  awgInterfaceOutbounds = builtins.filter (ob: ob.kind == "interface") awgOutbounds;
  # Profiles run behind a loopback SOCKS hop rather than an interface.
  awgTunnelOutbounds = builtins.filter (ob: ob.kind != "interface") awgOutbounds;

  proxyInboundsCfg = cfg.inbounds;
  proxyInboundsEnabled = proxyInboundsCfg.enable;

  # Listeners as a list, with `via` resolved against the default.
  proxyInbounds = lib.mapAttrsToList (tag: listener: {
    inherit tag listener;
    via = if listener.via == null then proxyInboundsCfg.routing.via else listener.via;
  }) proxyInboundsCfg.listeners;

  # Whether any listener or inbounds.routing.proxy exception relays through the local SOCKS
  # listener.
  proxyInboundsNeedLocalProxy =
    lib.any (ib: ib.via == "proxy") proxyInbounds
    || lib.any (field: proxyInboundsCfg.routing.proxy.${field} != [ ]) [
      "domains"
      "ips"
      "geosites"
      "geoips"
    ];

  # Names pass unresolved unless XRay dials itself (a direct listener, or pure XRay).
  proxyInboundsResolveInSingBox = !pureXrayEnabled && !lib.any (ib: ib.via == "direct") proxyInbounds;

  # Even when XRay resolves (a direct listener), it hands sing-box the name, which sing-box
  # looks up again: guard there too.
  proxyInboundsGuardPrivate =
    proxyInboundsEnabled
    && proxyInboundsCfg.routing.blockPrivate
    && proxyInboundsNeedLocalProxy
    && !pureXrayEnabled;

  # Other vias name static outbounds, rendered into the inbound service's own config.
  proxyInboundViaTags = lib.unique (
    builtins.filter (via: !builtins.elem via builtinTags) (map (ib: ib.via) proxyInbounds)
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

  proxyInboundUdpTypes = [
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
  # h3-only xhttp listeners are UDP-only, leaving the TCP port to a web server.
  proxyInboundIsH3Only =
    l: l.type != null && l.transport.type == "xhttp" && l.tls.enable && l.tls.alpn == [ "h3" ];
  proxyInboundFirewallPorts = lib.unique (
    map (ib: ib.listener.port) (
      builtins.filter (ib: !proxyInboundIsH3Only ib.listener) proxyInboundsPublic
    )
  );
  # A raw-JSON listener could serve anything, so open both protocols for it.
  proxyInboundFirewallUdpPorts = lib.unique (
    map (ib: ib.listener.port) (
      builtins.filter (
        ib:
        ib.listener.type == null
        || builtins.elem ib.listener.type proxyInboundUdpTypes
        || proxyInboundIsH3Only ib.listener
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
    ++ lib.optional warpOutboundEnabled warpOutboundTag
    ++ map (ob: ob.tag) awgOutbounds;
  subscriptionTags = map (sub: sub.tag) proxyCfg.subscriptions;

  hasStaticOutbounds = proxyCfg.outbounds != [ ];
  hasSubscriptions = proxyCfg.subscriptions != [ ];
  hasAvailableOutbounds =
    hasStaticOutbounds
    || hasSubscriptions
    || sshProxyOutboundEnabled
    || warpOutboundEnabled
    || awgOutbounds != [ ];
  collapseNamedOutbounds = selectionMode == "first";
  # Always on with sing-box: `proxy-ctl proxy outbounds test` needs it in every selection mode.
  clashApiEnabled = singBoxEnabled;
  perAppZapretEnabled = perAppZapretCfg.enable;
  zapretCutoffEnabled =
    zapretEngine == "zapret2"
    && (zapretCfg.enable || perAppZapretEnabled)
    && zapretCfg.zapret2.cutoff.enable;
  # The cut-off networks no whitelisted name fixes go through the proxy outbound.
  zapretCutoffProxyFallback =
    zapretCutoffEnabled && zapretCfg.zapret2.cutoff.proxyFallback && hasAvailableOutbounds;
  userControlEnabled = userControlCfg.enable;
  # Whether the group holds a scope; no scopes listed means all of them.
  userControlAllows =
    scope:
    userControlEnabled && (userControlCfg.scopes == [ ] || builtins.elem scope userControlCfg.scopes);
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
    # Socket marks and IP_TRANSPARENT, TUN and auto_redirect, listeners below 1024, ICMP.
    backendCaps = [
      "net_admin"
      "net_bind_service"
      "net_raw"
    ];

    zapret2StateDir = "${stateDir}/zapret2";
    zapret2CutoffDir = "${stateDir}/zapret2/cutoff";
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
    # Written by every backend start script; proxy-ctl reads the socks copy.
    outboundInventoryFile = "${runtimeDir}/proxy-suite-socks/outbounds.json";

    inboundStatsApiPort = 18536;
    # sing-box's fake IP caches, one per TUN config; the start script hands it to the backend.
    fakeIpCacheDir = "${stateDir}/fakeip";
    # Loopback listener behind the selector `proxy-ctl proxy outbounds test` switches.
    outboundTestPort = 18537;
    inboundStatsFile = "${stateDir}/inbound-stats.json";

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

    xraySidecarBasePorts = {
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
        rule: !builtins.elem rule.outbound (builtinTags ++ effectiveOutboundTags)
      ) proxyCfg.routing.rules
    )
  );
in
{
  inherit
    proxyCfg
    singBoxCfg
    xrayCfg
    proxyEnabled
    singBoxEnabled
    xrayEnabled
    hybridEnabled
    pureSingBoxEnabled
    pureXrayEnabled
    activeBackend
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    zapretCfg
    zapretEngine
    perAppZapretCfg
    perAppZapretEnabled
    zapretCutoffEnabled
    zapretCutoffProxyFallback
    userControlCfg
    userControlEnabled
    userControlAllows
    sshProxyCfg
    sshProxyOutboundTag
    sshProxyOutboundEnabled
    sshProxyNativeOutbound
    sshProxyUnitEnabled
    warpCfg
    warpOutboundTag
    warpOutboundEnabled
    awgGlobalProfiles
    awgOutbounds
    awgInterfaceOutbounds
    awgTunnelOutbounds
    proxyInboundsCfg
    proxyInboundsEnabled
    proxyInbounds
    proxyInboundsNeedLocalProxy
    proxyInboundsResolveInSingBox
    proxyInboundsGuardPrivate
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
    hasStaticOutbounds
    hasSubscriptions
    hasAvailableOutbounds
    collapseNamedOutbounds
    clashApiEnabled
    invalidRoutingTargets
    ;
}
