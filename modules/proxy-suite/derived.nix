{
  lib,
  cfg,
}:

let
  proxyCfg = cfg.proxy;
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
  proxyInboundsResolveInSingBox =
    !pureXrayEnabled && !lib.any (ib: ib.via == "direct") proxyInbounds;

  proxyInboundsGuardPrivate =
    proxyInboundsEnabled
    && proxyInboundsCfg.routing.blockPrivate
    && proxyInboundsNeedLocalProxy
    && proxyInboundsResolveInSingBox;

  # Other vias name static outbounds, rendered into the inbound service's own config.
  proxyInboundViaTags = lib.unique (
    builtins.filter (via: !builtins.elem via builtinTags) (map (ib: ib.via) proxyInbounds)
  );
  proxyInboundViaOutbounds = builtins.filter (
    ob: builtins.elem ob.tag proxyInboundViaTags
  ) proxyCfg.outbounds;

  proxyInboundUdpTypes = [
    "shadowsocks"
    "socks"
  ];
  proxyInboundPorts = lib.unique (map (ib: ib.listener.port) proxyInbounds);
  # Loopback listeners are fronted locally; their ports stay closed.
  proxyInboundsPublic = builtins.filter (
    ib:
    !builtins.elem ib.listener.address [
      "127.0.0.1"
      "::1"
    ]
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
  effectiveOutboundTags = outboundTags ++ lib.optional sshProxyOutboundEnabled sshProxyOutboundTag;
  subscriptionTags = map (sub: sub.tag) proxyCfg.subscriptions;

  hasStaticOutbounds = proxyCfg.outbounds != [ ];
  hasSubscriptions = proxyCfg.subscriptions != [ ];
  hasAvailableOutbounds = hasStaticOutbounds || hasSubscriptions || sshProxyOutboundEnabled;
  collapseNamedOutbounds = selectionMode == "first";
  clashApiEnabled = (singBoxEnabled || hybridEnabled) && selectionMode != "first";
  perAppZapretEnabled = perAppZapretCfg.enable;
  zapretCutoffEnabled =
    zapretEngine == "zapret2"
    && (zapretCfg.enable || perAppZapretEnabled)
    && zapretCfg.zapret2.cutoff.enable;
  # The cut-off networks no whitelisted name fixes go through the proxy outbound.
  zapretCutoffProxyFallback =
    zapretCutoffEnabled && zapretCfg.zapret2.cutoff.proxyFallback && hasAvailableOutbounds;
  userControlEnabled = userControlCfg.allow != [ ];
  constants = {
    zapret2StateDir = "/var/lib/proxy-suite/zapret2";
    zapret2CutoffDir = "/var/lib/proxy-suite/zapret2/cutoff";
    # Conntrack bit on the cutoff probe's own connections, which zapret2 leaves alone.
    zapret2CutoffProbeCtMark = 33554432; # 0x2000000

    # NFQUEUE of the global zapret instance, per engine. Both are the engine's own
    # default, which proxy-suite never overrides; the per-app instance opens a
    # second queue and must not land on this one.
    zapretGlobalQnum = {
      zapret-discord-youtube = 200;
      zapret2 = 300;
    };

    autoProxyStateDir = "/var/lib/proxy-suite/autoproxy";

    # Runtime outbound control. The spool dirs hold one proxy URL per file and are
    # group-writable when userControl is on, so proxy-ctl edits them without sudo;
    # the pin outlives a reboot, unlike the per-boot route-mode override.
    priorityOutboundFile = "/var/lib/proxy-suite/priority-outbound";
    runtimeOutboundsDir = "/var/lib/proxy-suite/outbounds.d";
    runtimeSubscriptionsDir = "/var/lib/proxy-suite/subscriptions.d";
    # Written by every backend start script; proxy-ctl reads the socks copy.
    outboundInventoryFile = "/run/proxy-suite-socks/outbounds.json";

    inboundStatsApiPort = 18536;
    inboundStatsFile = "/var/lib/proxy-suite/inbound-stats.json";

    tunAutoRouteTableIndex = 2022;
    tunAutoRouteRulePriority = 9000;
    xrayTunPerAppTproxyRulePriority = 8996;
    xrayTunPerAppTunRulePriority = 8997;

    xrayGlobalTunIPv6Address = "fd66:19::1/64";
    xrayGlobalTunIPv6RoutePrefix = "fd66:19::/64";
    xrayPerAppTunIPv6Address = "fd66:20::1/64";
    xrayPerAppTunIPv6RoutePrefix = "fd66:20::/64";

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
  invalidInboundViaTargets = builtins.filter (tag: !builtins.elem tag outboundTags) proxyInboundViaTags;

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
    sshProxyCfg
    sshProxyOutboundTag
    sshProxyOutboundEnabled
    sshProxyNativeOutbound
    sshProxyUnitEnabled
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
