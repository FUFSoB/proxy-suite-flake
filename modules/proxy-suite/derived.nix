{
  lib,
  cfg,
}:

let
  proxyCfg = cfg.proxy;
  singBoxCfg = proxyCfg // {
    enable = proxyCfg.enable && proxyCfg.singBox.enable;
    package = proxyCfg.singBox.package;
    clashApiPort = proxyCfg.singBox.clashApiPort;
    urlTest = proxyCfg.urlTest // {
      tolerance = proxyCfg.singBox.urlTest.tolerance;
    };
  };
  xrayCfg = proxyCfg.xray;
  proxyEnabled = proxyCfg.enable;
  singBoxEnabled = proxyCfg.enable && proxyCfg.singBox.enable;
  xrayEnabled = proxyCfg.enable && proxyCfg.xray.enable;
  hybridEnabled = singBoxEnabled && xrayEnabled;
  pureSingBoxEnabled = singBoxEnabled && !xrayEnabled;
  pureXrayEnabled = xrayEnabled && !singBoxEnabled;
  activeBackend =
    if hybridEnabled then
      "hybrid"
    else if pureXrayEnabled then
      "xray"
    else if pureSingBoxEnabled then
      "sing-box"
    else
      null;
  perAppRoutingCfg = cfg.perAppRouting;
  globalTun = proxyCfg.tun;
  globalTproxy = proxyCfg.tproxy;
  perAppRoutingTun = proxyCfg.tun.perApp;
  perAppRoutingTproxy = proxyCfg.tproxy.perApp;
  perAppZapretCfg = cfg.zapret.perApp;
  userControlCfg = cfg.userControl;
  sshProxyCfg = cfg.sshProxy;
  sshProxyOutboundTag = "ssh-proxy";
  sshProxyOutboundEnabled = sshProxyCfg.enable && sshProxyCfg.asOutbound;
  # Only sing-box has a native `ssh` outbound. XRay has none, so it keeps the
  # OpenSSH `ssh -D` unit and its local SOCKS listener -- as does a standalone
  # tunnel that is not wired in as an outbound at all.
  sshProxyNativeOutbound = sshProxyOutboundEnabled && !pureXrayEnabled;
  sshProxyUnitEnabled = sshProxyCfg.enable && !sshProxyNativeOutbound;

  proxyInboundsCfg = cfg.proxyInbounds;
  proxyInboundsEnabled = proxyInboundsCfg.enable;

  # Listener attrset flattened to a list with `via` resolved against the
  # tree-wide default. Everything downstream (rules, spec, firewall) uses this.
  proxyInbounds = lib.mapAttrsToList (tag: listener: {
    inherit tag listener;
    via = if listener.via == null then proxyInboundsCfg.via else listener.via;
  }) proxyInboundsCfg.listeners;

  # "direct" and "block" are self-contained; "proxy" chains through the client
  # stack's local SOCKS listener, so it needs the client side to be running.
  proxyInboundsNeedLocalProxy = lib.any (ib: ib.via == "proxy") proxyInbounds;

  # Any other via names a static outbound, which is rendered into the inbound
  # service's own config so it stays pinned regardless of the client's
  # selection. Only referenced outbounds are built, so an unused (or
  # sing-box-only) one never has to be XRay-representable.
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
  # A loopback-bound listener is reached through something else on this host (an
  # nginx vhost, say), so opening its port would expose the endpoint that
  # arrangement exists to hide.
  proxyInboundsPublic = builtins.filter (
    ib:
    !builtins.elem ib.listener.listenAddress [
      "127.0.0.1"
      "::1"
    ]
  ) proxyInbounds;
  proxyInboundFirewallPorts = lib.unique (map (ib: ib.listener.port) proxyInboundsPublic);
  # A raw-JSON listener could serve anything, so open both protocols for it.
  proxyInboundFirewallUdpPorts = lib.unique (
    map (ib: ib.listener.port) (
      builtins.filter (
        ib: ib.listener.type == null || builtins.elem ib.listener.type proxyInboundUdpTypes
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
  userControlEnabled = userControlCfg.global.enable || userControlCfg.perApp.enable;
  constants = {
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
    perAppZapretCfg
    perAppZapretEnabled
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
