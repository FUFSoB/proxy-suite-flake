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

  selectionMode = proxyCfg.selection;
  builtinTags = [
    "proxy"
    "direct"
    "block"
  ];
  outboundTags = map (ob: ob.tag) proxyCfg.outbounds;
  subscriptionTags = map (sub: sub.tag) proxyCfg.subscriptions;

  hasStaticOutbounds = proxyCfg.outbounds != [ ];
  hasSubscriptions = proxyCfg.subscriptions != [ ];
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

  invalidRoutingTargets = lib.unique (
    map (rule: rule.outbound) (
      builtins.filter (
        rule: !builtins.elem rule.outbound (builtinTags ++ outboundTags)
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
    constants
    selectionMode
    builtinTags
    outboundTags
    subscriptionTags
    hasStaticOutbounds
    hasSubscriptions
    collapseNamedOutbounds
    clashApiEnabled
    invalidRoutingTargets
    ;
}
