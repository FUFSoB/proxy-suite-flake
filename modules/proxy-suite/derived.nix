{
  lib,
  cfg,
}:

let
  singBoxCfg = cfg.singBox;
  perAppRoutingCfg = cfg.perAppRouting;
  globalTun = singBoxCfg.tun;
  globalTproxy = singBoxCfg.tproxy;
  perAppRoutingTun = singBoxCfg.tun.perApp;
  perAppRoutingTproxy = singBoxCfg.tproxy.perApp;
  perAppZapretCfg = cfg.zapret.perApp;
  userControlCfg = cfg.userControl;

  selectionMode = singBoxCfg.selection;
  builtinTags = [ "proxy" "direct" "block" ];
  outboundTags = map (ob: ob.tag) singBoxCfg.outbounds;
  subscriptionTags = map (sub: sub.tag) singBoxCfg.subscriptions;

  hasStaticOutbounds = singBoxCfg.outbounds != [ ];
  hasSubscriptions = singBoxCfg.subscriptions != [ ];
  collapseNamedOutbounds = selectionMode == "first";
  clashApiEnabled = selectionMode != "first";
  perAppZapretEnabled = cfg.zapret.enable && perAppZapretCfg.enable;
  userControlEnabled = userControlCfg.global.enable || userControlCfg.perApp.enable;

  invalidRoutingTargets = lib.unique (
    map (rule: rule.outbound) (
      builtins.filter (rule: !builtins.elem rule.outbound (builtinTags ++ outboundTags)) singBoxCfg.routing.rules
    )
  );
in
{
  inherit
    singBoxCfg
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
