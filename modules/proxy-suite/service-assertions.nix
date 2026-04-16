{
  lib,
  cfg,
  singBoxCfg,
  tgWsProxyCfg,
  appRoutingCfg,
  appRoutingTun,
  appRoutingTproxy,
  appRoutingZapret,
  builtinTags,
  outboundTags,
  invalidRoutingTargets,
  effectiveAppRoutingProfileNames,
  hasProxychainsProfiles,
  hasTunProfiles,
  hasTproxyProfiles,
  hasZapretProfiles,
}:

[
  {
    assertion = !singBoxCfg.enable || (singBoxCfg.outbounds != [ ] || singBoxCfg.subscriptions != [ ]);
    message = "proxy-suite: at least one outbound or subscription is required when singBox.enable = true";
  }
  {
    assertion = builtins.length outboundTags == builtins.length (lib.unique outboundTags);
    message = "proxy-suite: outbound tags must be unique";
  }
  {
    assertion = builtins.all (tag: !builtins.elem tag builtinTags) outboundTags;
    message = "proxy-suite: outbound tags must not use reserved names: proxy, direct, block";
  }
  {
    assertion = invalidRoutingTargets == [ ];
    message = "proxy-suite: routing.rules reference unknown outbound tag(s): ${lib.concatStringsSep ", " invalidRoutingTargets}";
  }
  {
    assertion = !(singBoxCfg.tproxy.enable && singBoxCfg.tproxy.autostart && singBoxCfg.tun.enable && singBoxCfg.tun.autostart);
    message = "proxy-suite: singBox.tproxy.autostart and singBox.tun.autostart cannot both be enabled at the same time";
  }
  {
    assertion = appRoutingCfg.enable || appRoutingCfg.profiles == [ ];
    message = "proxy-suite: appRouting.profiles requires appRouting.enable = true";
  }
  {
    assertion = !appRoutingCfg.proxychains.enable || appRoutingCfg.enable;
    message = "proxy-suite: appRouting.proxychains.enable requires appRouting.enable = true";
  }
  {
    assertion = builtins.length effectiveAppRoutingProfileNames == builtins.length (lib.unique effectiveAppRoutingProfileNames);
    message = "proxy-suite: appRouting profile names must be unique";
  }
  {
    assertion = !hasProxychainsProfiles || appRoutingCfg.proxychains.enable;
    message = "proxy-suite: route=proxychains in appRouting.profiles requires appRouting.proxychains.enable = true";
  }
  {
    assertion = !appRoutingTun.enable || appRoutingCfg.enable;
    message = "proxy-suite: appRouting.backends.tun.enable requires appRouting.enable = true";
  }
  {
    assertion = !(hasTunProfiles && !appRoutingTun.enable);
    message = "proxy-suite: route=tun in appRouting profiles requires appRouting.backends.tun.enable = true";
  }
  {
    assertion = !appRoutingTproxy.enable || appRoutingCfg.enable;
    message = "proxy-suite: appRouting.backends.tproxy.enable requires appRouting.enable = true";
  }
  {
    assertion = !(hasTproxyProfiles && !appRoutingTproxy.enable);
    message = "proxy-suite: route=tproxy in appRouting profiles requires appRouting.backends.tproxy.enable = true";
  }
  {
    assertion = !appRoutingZapret.enable || appRoutingCfg.enable;
    message = "proxy-suite: appRouting.backends.zapretgWsProxyCfg.enable requires appRouting.enable = true";
  }
  {
    assertion = !appRoutingZapret.enable || cfg.zapret.enable;
    message = "proxy-suite: appRouting.backends.zapretgWsProxyCfg.enable requires zapretgWsProxyCfg.enable = true";
  }
  {
    assertion = !(hasZapretProfiles && (!appRoutingZapret.enable || !cfg.zapret.enable));
    message = "proxy-suite: route=zapret in appRouting profiles requires appRouting.backends.zapretgWsProxyCfg.enable = true and zapretgWsProxyCfg.enable = true";
  }
  {
    assertion = !(appRoutingTun.enable && singBoxCfg.tproxy.enable && appRoutingTun.fwmark == singBoxCfg.fwmark);
    message = "proxy-suite: appRouting.backends.tun.fwmark must differ from singBox.fwmark when singBox.tproxy.enable = true";
  }
  {
    assertion = !(appRoutingTun.enable && singBoxCfg.tproxy.enable && appRoutingTun.fwmark == singBoxCfg.proxyMark);
    message = "proxy-suite: appRouting.backends.tun.fwmark must differ from singBox.proxyMark when singBox.tproxy.enable = true";
  }
  {
    assertion = !(appRoutingTun.enable && singBoxCfg.tproxy.enable && appRoutingTun.routeTable == singBoxCfg.routeTable);
    message = "proxy-suite: appRouting.backends.tun.routeTable must differ from singBox.routeTable when singBox.tproxy.enable = true";
  }
  {
    assertion = !(appRoutingTproxy.enable && appRoutingTproxy.fwmark == singBoxCfg.fwmark);
    message = "proxy-suite: appRouting.backends.tproxy.fwmark must differ from singBox.fwmark";
  }
  {
    assertion = !(appRoutingTproxy.enable && appRoutingTproxy.fwmark == singBoxCfg.proxyMark);
    message = "proxy-suite: appRouting.backends.tproxy.fwmark must differ from singBox.proxyMark";
  }
  {
    assertion = !(appRoutingTproxy.enable && appRoutingTproxy.routeTable == singBoxCfg.routeTable);
    message = "proxy-suite: appRouting.backends.tproxy.routeTable must differ from singBox.routeTable";
  }
  {
    assertion = !(appRoutingTun.enable && appRoutingTproxy.enable && appRoutingTun.fwmark == appRoutingTproxy.fwmark);
    message = "proxy-suite: appRouting.backends.tun.fwmark and appRouting.backends.tproxy.fwmark must differ";
  }
  {
    assertion = !(appRoutingTun.enable && appRoutingTproxy.enable && appRoutingTun.routeTable == appRoutingTproxy.routeTable);
    message = "proxy-suite: appRouting.backends.tun.routeTable and appRouting.backends.tproxy.routeTable must differ";
  }
  {
    assertion = !(appRoutingZapret.enable && appRoutingZapret.filterMark == singBoxCfg.fwmark);
    message = "proxy-suite: appRouting.backends.zapretgWsProxyCfg.filterMark must differ from singBox.fwmark";
  }
  {
    assertion = !(appRoutingZapret.enable && appRoutingZapret.filterMark == singBoxCfg.proxyMark);
    message = "proxy-suite: appRouting.backends.zapretgWsProxyCfg.filterMark must differ from singBox.proxyMark";
  }
  {
    assertion = !(appRoutingTun.enable && appRoutingZapret.enable && appRoutingTun.fwmark == appRoutingZapret.filterMark);
    message = "proxy-suite: appRouting.backends.tun.fwmark and appRouting.backends.zapretgWsProxyCfg.filterMark must differ";
  }
  {
    assertion = !(appRoutingTproxy.enable && appRoutingZapret.enable && appRoutingTproxy.fwmark == appRoutingZapret.filterMark);
    message = "proxy-suite: appRouting.backends.tproxy.fwmark and appRouting.backends.zapretgWsProxyCfg.filterMark must differ";
  }
  {
    assertion = !(appRoutingZapret.enable && builtins.elem appRoutingZapret.filterMark [ 536870912 1073741824 ]);
    message = "proxy-suite: appRouting.backends.zapretgWsProxyCfg.filterMark must not use zapret internal desync mark bits";
  }
  {
    assertion = !(appRoutingZapret.enable && builtins.elem singBoxCfg.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: singBox.fwmark must not use app-zapret internal desync mark bits";
  }
  {
    assertion = !(appRoutingZapret.enable && builtins.elem singBoxCfg.proxyMark [ 67108864 134217728 ]);
    message = "proxy-suite: singBox.proxyMark must not use app-zapret internal desync mark bits";
  }
  {
    assertion = !(appRoutingTun.enable && appRoutingZapret.enable && builtins.elem appRoutingTun.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: appRouting.backends.tun.fwmark must not use app-zapret internal desync mark bits";
  }
  {
    assertion = !(appRoutingTproxy.enable && appRoutingZapret.enable && builtins.elem appRoutingTproxy.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: appRouting.backends.tproxy.fwmark must not use app-zapret internal desync mark bits";
  }
  {
    assertion = !(appRoutingZapret.enable && builtins.elem appRoutingZapret.filterMark [ 67108864 134217728 ]);
    message = "proxy-suite: appRouting.backends.zapretgWsProxyCfg.filterMark must not use app-zapret internal desync mark bits";
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
      builtins.length (
        builtins.filter (x: x != null) [
          sub.urlFile
          sub.url
        ]
      ) == 1;
    message = "proxy-suite: subscription '${sub.tag}': set exactly one of urlFile or url";
  }
]) singBoxCfg.subscriptions
