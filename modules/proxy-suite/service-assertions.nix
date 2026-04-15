{
  lib,
  cfg,
  sb,
  t,
  ar,
  art,
  artp,
  arz,
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
    assertion = !sb.enable || (sb.outbounds != [ ] || sb.subscriptions != [ ]);
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
    assertion = !(sb.tproxy.enable && sb.tproxy.autostart && sb.tun.enable && sb.tun.autostart);
    message = "proxy-suite: singBox.tproxy.autostart and singBox.tun.autostart cannot both be enabled at the same time";
  }
  {
    assertion = ar.enable || ar.profiles == [ ];
    message = "proxy-suite: appRouting.profiles requires appRouting.enable = true";
  }
  {
    assertion = !ar.proxychains.enable || ar.enable;
    message = "proxy-suite: appRouting.proxychains.enable requires appRouting.enable = true";
  }
  {
    assertion = builtins.length effectiveAppRoutingProfileNames == builtins.length (lib.unique effectiveAppRoutingProfileNames);
    message = "proxy-suite: appRouting profile names must be unique";
  }
  {
    assertion = !hasProxychainsProfiles || ar.proxychains.enable;
    message = "proxy-suite: route=proxychains in appRouting.profiles requires appRouting.proxychains.enable = true";
  }
  {
    assertion = !art.enable || ar.enable;
    message = "proxy-suite: appRouting.backends.tun.enable requires appRouting.enable = true";
  }
  {
    assertion = !(hasTunProfiles && !art.enable);
    message = "proxy-suite: route=tun in appRouting profiles requires appRouting.backends.tun.enable = true";
  }
  {
    assertion = !artp.enable || ar.enable;
    message = "proxy-suite: appRouting.backends.tproxy.enable requires appRouting.enable = true";
  }
  {
    assertion = !(hasTproxyProfiles && !artp.enable);
    message = "proxy-suite: route=tproxy in appRouting profiles requires appRouting.backends.tproxy.enable = true";
  }
  {
    assertion = !arz.enable || ar.enable;
    message = "proxy-suite: appRouting.backends.zapret.enable requires appRouting.enable = true";
  }
  {
    assertion = !arz.enable || cfg.zapret.enable;
    message = "proxy-suite: appRouting.backends.zapret.enable requires zapret.enable = true";
  }
  {
    assertion = !(hasZapretProfiles && (!arz.enable || !cfg.zapret.enable));
    message = "proxy-suite: route=zapret in appRouting profiles requires appRouting.backends.zapret.enable = true and zapret.enable = true";
  }
  {
    assertion = !(art.enable && sb.tproxy.enable && art.fwmark == sb.fwmark);
    message = "proxy-suite: appRouting.backends.tun.fwmark must differ from singBox.fwmark when singBox.tproxy.enable = true";
  }
  {
    assertion = !(art.enable && sb.tproxy.enable && art.fwmark == sb.proxyMark);
    message = "proxy-suite: appRouting.backends.tun.fwmark must differ from singBox.proxyMark when singBox.tproxy.enable = true";
  }
  {
    assertion = !(art.enable && sb.tproxy.enable && art.routeTable == sb.routeTable);
    message = "proxy-suite: appRouting.backends.tun.routeTable must differ from singBox.routeTable when singBox.tproxy.enable = true";
  }
  {
    assertion = !(artp.enable && artp.fwmark == sb.fwmark);
    message = "proxy-suite: appRouting.backends.tproxy.fwmark must differ from singBox.fwmark";
  }
  {
    assertion = !(artp.enable && artp.fwmark == sb.proxyMark);
    message = "proxy-suite: appRouting.backends.tproxy.fwmark must differ from singBox.proxyMark";
  }
  {
    assertion = !(artp.enable && artp.routeTable == sb.routeTable);
    message = "proxy-suite: appRouting.backends.tproxy.routeTable must differ from singBox.routeTable";
  }
  {
    assertion = !(art.enable && artp.enable && art.fwmark == artp.fwmark);
    message = "proxy-suite: appRouting.backends.tun.fwmark and appRouting.backends.tproxy.fwmark must differ";
  }
  {
    assertion = !(art.enable && artp.enable && art.routeTable == artp.routeTable);
    message = "proxy-suite: appRouting.backends.tun.routeTable and appRouting.backends.tproxy.routeTable must differ";
  }
  {
    assertion = !(arz.enable && arz.filterMark == sb.fwmark);
    message = "proxy-suite: appRouting.backends.zapret.filterMark must differ from singBox.fwmark";
  }
  {
    assertion = !(arz.enable && arz.filterMark == sb.proxyMark);
    message = "proxy-suite: appRouting.backends.zapret.filterMark must differ from singBox.proxyMark";
  }
  {
    assertion = !(art.enable && arz.enable && art.fwmark == arz.filterMark);
    message = "proxy-suite: appRouting.backends.tun.fwmark and appRouting.backends.zapret.filterMark must differ";
  }
  {
    assertion = !(artp.enable && arz.enable && artp.fwmark == arz.filterMark);
    message = "proxy-suite: appRouting.backends.tproxy.fwmark and appRouting.backends.zapret.filterMark must differ";
  }
  {
    assertion = !(arz.enable && builtins.elem arz.filterMark [ 536870912 1073741824 ]);
    message = "proxy-suite: appRouting.backends.zapret.filterMark must not use zapret internal desync mark bits";
  }
  {
    assertion = !(arz.enable && builtins.elem sb.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: singBox.fwmark must not use app-zapret internal desync mark bits";
  }
  {
    assertion = !(arz.enable && builtins.elem sb.proxyMark [ 67108864 134217728 ]);
    message = "proxy-suite: singBox.proxyMark must not use app-zapret internal desync mark bits";
  }
  {
    assertion = !(art.enable && arz.enable && builtins.elem art.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: appRouting.backends.tun.fwmark must not use app-zapret internal desync mark bits";
  }
  {
    assertion = !(artp.enable && arz.enable && builtins.elem artp.fwmark [ 67108864 134217728 ]);
    message = "proxy-suite: appRouting.backends.tproxy.fwmark must not use app-zapret internal desync mark bits";
  }
  {
    assertion = !(arz.enable && builtins.elem arz.filterMark [ 67108864 134217728 ]);
    message = "proxy-suite: appRouting.backends.zapret.filterMark must not use app-zapret internal desync mark bits";
  }
  {
    assertion =
      !t.enable
      ||
        builtins.length (
          builtins.filter (x: x != null) [
            t.secret
            t.secretFile
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
]) sb.outbounds
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
]) sb.subscriptions
