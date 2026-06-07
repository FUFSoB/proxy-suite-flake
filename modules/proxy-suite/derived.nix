{
  lib,
  cfg,
}:

let
  proxyCfg = cfg.proxy;
  singBoxCfg =
    proxyCfg
    // {
      enable = proxyCfg.enable && proxyCfg.singBox.enable;
      package = proxyCfg.singBox.package;
      clashApiPort = proxyCfg.singBox.clashApiPort;
      urlTest = proxyCfg.urlTest // { tolerance = proxyCfg.singBox.urlTest.tolerance; };
    };
  xrayCfg = proxyCfg.xray;
  proxyEnabled = proxyCfg.enable;
  singBoxEnabled = proxyCfg.enable && proxyCfg.singBox.enable;
  xrayEnabled = proxyCfg.enable && proxyCfg.xray.enable;
  activeBackend =
    if xrayEnabled then
      "xray"
    else if singBoxEnabled then
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
  clashApiEnabled = singBoxEnabled && selectionMode != "first";
  perAppZapretEnabled = perAppZapretCfg.enable;
  userControlEnabled = userControlCfg.global.enable || userControlCfg.perApp.enable;

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
