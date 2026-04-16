{
  lib,
  cfg,
  singBoxCfg,
  tgWsProxyCfg,
  perAppRoutingCfg,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretCfg,
  builtinTags,
  outboundTags,
  invalidRoutingTargets,
  effectivePerAppRoutingProfileNames,
  hasProxychainsProfiles,
  hasTunProfiles,
  hasTproxyProfiles,
  hasZapretProfiles,
}:

let
  globalTun = singBoxCfg.tun;
  globalTproxy = singBoxCfg.tproxy;
in
[
  {
    assertion = !singBoxCfg.enable || (singBoxCfg.outbounds != [ ] || singBoxCfg.subscriptions != [ ]);
    message = "proxy-suite: at least one outbound or subscription is required when singBox.enable = true";
  }
  {
    assertion = !singBoxCfg.enable || builtins.length outboundTags == builtins.length (lib.unique outboundTags);
    message = "proxy-suite: outbound tags must be unique";
  }
  {
    assertion = !singBoxCfg.enable || builtins.all (tag: !builtins.elem tag builtinTags) outboundTags;
    message = "proxy-suite: outbound tags must not use reserved names: proxy, direct, block";
  }
  {
    assertion = !singBoxCfg.enable || invalidRoutingTargets == [ ];
    message = "proxy-suite: routing.rules reference unknown outbound tag(s): ${lib.concatStringsSep ", " invalidRoutingTargets}";
  }
  {
    assertion = !globalTun.enable || singBoxCfg.enable;
    message = "proxy-suite: singBox.tun.enable requires singBox.enable = true";
  }
  {
    assertion = !globalTproxy.enable || singBoxCfg.enable;
    message = "proxy-suite: singBox.tproxy.enable requires singBox.enable = true";
  }
  {
    assertion = !globalTun.autostart || globalTun.enable;
    message = "proxy-suite: singBox.tun.autostart requires singBox.tun.enable = true";
  }
  {
    assertion = !globalTproxy.autostart || globalTproxy.enable;
    message = "proxy-suite: singBox.tproxy.autostart requires singBox.tproxy.enable = true";
  }
  {
    assertion = !(globalTproxy.enable && globalTproxy.autostart && globalTun.enable && globalTun.autostart);
    message =
      "proxy-suite: singBox.tproxy.autostart and singBox.tun.autostart cannot both be enabled at the same time";
  }
  {
    assertion = perAppRoutingCfg.enable || perAppRoutingCfg.profiles == [ ];
    message = "proxy-suite: perAppRouting.profiles requires perAppRouting.enable = true";
  }
  {
    assertion = !perAppRoutingCfg.proxychains.enable || perAppRoutingCfg.enable;
    message = "proxy-suite: perAppRouting.proxychains.enable requires perAppRouting.enable = true";
  }
  {
    assertion = !perAppRoutingCfg.proxychains.enable || singBoxCfg.enable;
    message = "proxy-suite: perAppRouting.proxychains.enable requires singBox.enable = true";
  }
  {
    assertion = builtins.length effectivePerAppRoutingProfileNames == builtins.length (lib.unique effectivePerAppRoutingProfileNames);
    message = "proxy-suite: perAppRouting profile names must be unique";
  }
  {
    assertion = !hasProxychainsProfiles || perAppRoutingCfg.proxychains.enable;
    message = "proxy-suite: route=proxychains in perAppRouting.profiles requires perAppRouting.proxychains.enable = true";
  }
  {
    assertion = !hasProxychainsProfiles || singBoxCfg.enable;
    message = "proxy-suite: route=proxychains in perAppRouting.profiles requires singBox.enable = true";
  }
  {
    assertion = !perAppRoutingTun.enable || perAppRoutingCfg.enable;
    message = "proxy-suite: singBox.tun.perApp.enable requires perAppRouting.enable = true";
  }
  {
    assertion = !perAppRoutingTun.enable || singBoxCfg.enable;
    message = "proxy-suite: singBox.tun.perApp.enable requires singBox.enable = true";
  }
  {
    assertion = !(hasTunProfiles && !perAppRoutingTun.enable);
    message = "proxy-suite: route=tun in perAppRouting.profiles requires singBox.tun.perApp.enable = true";
  }
  {
    assertion = !hasTunProfiles || singBoxCfg.enable;
    message = "proxy-suite: route=tun in perAppRouting.profiles requires singBox.enable = true";
  }
  {
    assertion = !perAppRoutingTproxy.enable || perAppRoutingCfg.enable;
    message = "proxy-suite: singBox.tproxy.perApp.enable requires perAppRouting.enable = true";
  }
  {
    assertion = !perAppRoutingTproxy.enable || singBoxCfg.enable;
    message = "proxy-suite: singBox.tproxy.perApp.enable requires singBox.enable = true";
  }
  {
    assertion = !(hasTproxyProfiles && !perAppRoutingTproxy.enable);
    message = "proxy-suite: route=tproxy in perAppRouting.profiles requires singBox.tproxy.perApp.enable = true";
  }
  {
    assertion = !hasTproxyProfiles || singBoxCfg.enable;
    message = "proxy-suite: route=tproxy in perAppRouting.profiles requires singBox.enable = true";
  }
  {
    assertion = !perAppZapretCfg.enable || perAppRoutingCfg.enable;
    message = "proxy-suite: zapret.perApp.enable requires perAppRouting.enable = true";
  }
  {
    assertion = !perAppZapretCfg.enable || cfg.zapret.enable;
    message = "proxy-suite: zapret.perApp.enable requires zapret.enable = true";
  }
  {
    assertion = !(hasZapretProfiles && (!perAppZapretCfg.enable || !cfg.zapret.enable));
    message = "proxy-suite: route=zapret in perAppRouting.profiles requires zapret.perApp.enable = true and zapret.enable = true";
  }
  {
    assertion = !(perAppRoutingTun.enable && globalTproxy.enable && perAppRoutingTun.fwmark == globalTproxy.fwmark);
    message =
      "proxy-suite: singBox.tun.perApp.fwmark must differ from singBox.tproxy.fwmark when global TProxy is enabled";
  }
  {
    assertion = !(perAppRoutingTun.enable && globalTproxy.enable && perAppRoutingTun.fwmark == globalTproxy.proxyMark);
    message =
      "proxy-suite: singBox.tun.perApp.fwmark must differ from singBox.tproxy.proxyMark when global TProxy is enabled";
  }
  {
    assertion = !(perAppRoutingTun.enable && globalTproxy.enable && perAppRoutingTun.routeTable == globalTproxy.routeTable);
    message =
      "proxy-suite: singBox.tun.perApp.routeTable must differ from singBox.tproxy.routeTable when global TProxy is enabled";
  }
  {
    assertion = !(perAppRoutingTproxy.enable && perAppRoutingTproxy.fwmark == globalTproxy.fwmark);
    message = "proxy-suite: singBox.tproxy.perApp.fwmark must differ from singBox.tproxy.fwmark";
  }
  {
    assertion = !(perAppRoutingTproxy.enable && perAppRoutingTproxy.fwmark == globalTproxy.proxyMark);
    message = "proxy-suite: singBox.tproxy.perApp.fwmark must differ from singBox.tproxy.proxyMark";
  }
  {
    assertion = !(perAppRoutingTproxy.enable && perAppRoutingTproxy.routeTable == globalTproxy.routeTable);
    message = "proxy-suite: singBox.tproxy.perApp.routeTable must differ from singBox.tproxy.routeTable";
  }
  {
    assertion = !(perAppRoutingTun.enable && perAppRoutingTproxy.enable && perAppRoutingTun.fwmark == perAppRoutingTproxy.fwmark);
    message = "proxy-suite: singBox.tun.perApp.fwmark and singBox.tproxy.perApp.fwmark must differ";
  }
  {
    assertion = !(perAppRoutingTun.enable && perAppRoutingTproxy.enable && perAppRoutingTun.routeTable == perAppRoutingTproxy.routeTable);
    message = "proxy-suite: singBox.tun.perApp.routeTable and singBox.tproxy.perApp.routeTable must differ";
  }
  {
    assertion = !(perAppZapretCfg.enable && perAppZapretCfg.filterMark == globalTproxy.fwmark);
    message = "proxy-suite: zapret.perApp.filterMark must differ from singBox.tproxy.fwmark";
  }
  {
    assertion = !(perAppZapretCfg.enable && perAppZapretCfg.filterMark == globalTproxy.proxyMark);
    message = "proxy-suite: zapret.perApp.filterMark must differ from singBox.tproxy.proxyMark";
  }
  {
    assertion = !(perAppRoutingTun.enable && perAppZapretCfg.enable && perAppRoutingTun.fwmark == perAppZapretCfg.filterMark);
    message = "proxy-suite: singBox.tun.perApp.fwmark and zapret.perApp.filterMark must differ";
  }
  {
    assertion = !(perAppRoutingTproxy.enable && perAppZapretCfg.enable && perAppRoutingTproxy.fwmark == perAppZapretCfg.filterMark);
    message = "proxy-suite: singBox.tproxy.perApp.fwmark and zapret.perApp.filterMark must differ";
  }
  {
    assertion = !(perAppZapretCfg.enable && builtins.elem perAppZapretCfg.filterMark [ 536870912 1073741824 ]);
    message = "proxy-suite: zapret.perApp.filterMark must not use zapret internal desync mark bits";
  }
  {
    assertion = !(perAppZapretCfg.enable && builtins.elem globalTproxy.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: singBox.tproxy.fwmark must not use per-app-zapret internal desync mark bits";
  }
  {
    assertion = !(perAppZapretCfg.enable && builtins.elem globalTproxy.proxyMark [ 67108864 134217728 ]);
    message = "proxy-suite: singBox.tproxy.proxyMark must not use per-app-zapret internal desync mark bits";
  }
  {
    assertion = !(perAppRoutingTun.enable && perAppZapretCfg.enable && builtins.elem perAppRoutingTun.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: singBox.tun.perApp.fwmark must not use per-app-zapret internal desync mark bits";
  }
  {
    assertion = !(perAppRoutingTproxy.enable && perAppZapretCfg.enable && builtins.elem perAppRoutingTproxy.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: singBox.tproxy.perApp.fwmark must not use per-app-zapret internal desync mark bits";
  }
  {
    assertion = !(perAppZapretCfg.enable && builtins.elem perAppZapretCfg.filterMark [ 67108864 134217728 ]);
    message = "proxy-suite: zapret.perApp.filterMark must not use per-app-zapret internal desync mark bits";
  }
  {
    assertion =
      !tgWsProxyCfg.enable
      ||
        builtins.length (
          builtins.filter (x: x != null) [
            tgWsProxyCfg.secret
            tgWsProxyCfg.secretFile
          ]
        ) == 1;
    message = "proxy-suite: tgWsProxy requires exactly one of secret or secretFile";
  }
]
++ lib.concatMap (ob: [
  {
    assertion =
      !singBoxCfg.enable
      ||
        builtins.length (
          builtins.filter (x: x != null) [
            ob.urlFile
            ob.url
            ob.json
          ]
        ) == 1;
    message = "proxy-suite: outbound '${ob.tag}': set exactly one of urlFile, url, or json";
  }
]) singBoxCfg.outbounds
++ lib.concatMap (sub: [
  {
    assertion =
      !singBoxCfg.enable
      ||
        builtins.length (
          builtins.filter (x: x != null) [
            sub.urlFile
            sub.url
          ]
        ) == 1;
    message = "proxy-suite: subscription '${sub.tag}': set exactly one of urlFile or url";
  }
]) singBoxCfg.subscriptions
