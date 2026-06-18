{
  lib,
  cfg,
  derived,
  tgWsProxyCfg,
  builtinTags,
  outboundTags,
  subscriptionTags,
  invalidRoutingTargets,
  effectivePerAppRoutingProfileNames,
  hasProxychainsProfiles,
  hasTunProfiles,
  hasTproxyProfiles,
  hasZapretProfiles,
}:

let
  assertions = import ./service/assertions-lib.nix { inherit lib; };
  inherit (assertions)
    mkAssertion
    requireEnabled
    requireAvailable
    uniqueValues
    notEqualWhen
    forbiddenValues
    exactlyOneOf
    ;

  inherit (derived)
    proxyCfg
    singBoxCfg
    proxyEnabled
    singBoxEnabled
    xrayEnabled
    hybridEnabled
    pureXrayEnabled
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    ;

  globalTunAutoRouteTable = 2022;

  featureAssertions = [
    (requireAvailable proxyCfg.singBox.enable proxyEnabled
      "proxy-suite: proxy.singBox.enable requires proxy.enable = true"
    )
    (requireAvailable proxyCfg.xray.enable proxyEnabled
      "proxy-suite: proxy.xray.enable requires proxy.enable = true"
    )
    (mkAssertion (!proxyEnabled || proxyCfg.singBox.enable || proxyCfg.xray.enable)
      "proxy-suite: at least one of proxy.singBox.enable or proxy.xray.enable must be true when proxy.enable = true"
    )
    (requireAvailable proxyEnabled (
      proxyCfg.outbounds != [ ] || proxyCfg.subscriptions != [ ]
    ) "proxy-suite: at least one outbound or subscription is required when proxy.enable = true")
    (uniqueValues proxyEnabled outboundTags "proxy-suite: outbound tags must be unique")
    (uniqueValues proxyEnabled subscriptionTags
      "proxy-suite: subscription tags must be unique because they are used as cache keys and outbound tag prefixes"
    )
    (mkAssertion (
      !proxyEnabled || builtins.all (tag: !builtins.elem tag builtinTags) outboundTags
    ) "proxy-suite: outbound tags must not use reserved names: proxy, direct, block")
    (mkAssertion (!proxyEnabled || invalidRoutingTargets == [ ])
      "proxy-suite: routing.rules reference unknown outbound tag(s): ${lib.concatStringsSep ", " invalidRoutingTargets}"
    )
    (mkAssertion (
      !(pureXrayEnabled && proxyCfg.selection == "selector")
    ) "proxy-suite: proxy.selection = \"selector\" is only available with proxy.singBox.enable = true")
    (mkAssertion
      (!(pureXrayEnabled && (proxyCfg.dns.local.type == "tls" || proxyCfg.dns.remote.type == "tls")))
      "proxy-suite: proxy.dns.*.type = \"tls\" is not supported with proxy.xray.enable = true; use udp/tcp DNS for XRay"
    )
    (requireEnabled globalTun.enable proxyEnabled
      "proxy-suite: proxy.tun.enable requires proxy.enable = true"
    )
    (requireEnabled globalTproxy.enable proxyEnabled
      "proxy-suite: proxy.tproxy.enable requires proxy.enable = true"
    )
    (requireEnabled globalTun.autostart globalTun.enable
      "proxy-suite: proxy.tun.autostart requires proxy.tun.enable = true"
    )
    (requireEnabled globalTproxy.autostart globalTproxy.enable
      "proxy-suite: proxy.tproxy.autostart requires proxy.tproxy.enable = true"
    )
    (mkAssertion
      (!(globalTproxy.enable && globalTproxy.autostart && globalTun.enable && globalTun.autostart))
      "proxy-suite: proxy.tproxy.autostart and proxy.tun.autostart cannot both be enabled at the same time"
    )
  ];

  perAppRoutingAssertions = [
    (requireAvailable (perAppRoutingCfg.profiles != [ ]) perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.profiles requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingCfg.proxychains.enable perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.proxychains.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingCfg.proxychains.enable proxyEnabled
      "proxy-suite: perAppRouting.proxychains.enable requires proxy.enable = true"
    )
    (uniqueValues true effectivePerAppRoutingProfileNames
      "proxy-suite: perAppRouting profile names must be unique"
    )
    (requireAvailable hasProxychainsProfiles perAppRoutingCfg.proxychains.enable
      "proxy-suite: route=proxychains in perAppRouting.profiles requires perAppRouting.proxychains.enable = true"
    )
    (requireAvailable hasProxychainsProfiles proxyEnabled
      "proxy-suite: route=proxychains in perAppRouting.profiles requires proxy.enable = true"
    )
    (requireEnabled perAppRoutingTun.enable perAppRoutingCfg.enable
      "proxy-suite: proxy.tun.perApp.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingTun.enable proxyEnabled
      "proxy-suite: proxy.tun.perApp.enable requires proxy.enable = true"
    )
    (requireAvailable hasTunProfiles perAppRoutingTun.enable
      "proxy-suite: route=tun in perAppRouting.profiles requires proxy.tun.perApp.enable = true"
    )
    (requireAvailable hasTunProfiles proxyEnabled
      "proxy-suite: route=tun in perAppRouting.profiles requires proxy.enable = true"
    )
    (requireEnabled perAppRoutingTproxy.enable perAppRoutingCfg.enable
      "proxy-suite: proxy.tproxy.perApp.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingTproxy.enable proxyEnabled
      "proxy-suite: proxy.tproxy.perApp.enable requires proxy.enable = true"
    )
    (requireAvailable hasTproxyProfiles perAppRoutingTproxy.enable
      "proxy-suite: route=tproxy in perAppRouting.profiles requires proxy.tproxy.perApp.enable = true"
    )
    (requireAvailable hasTproxyProfiles proxyEnabled
      "proxy-suite: route=tproxy in perAppRouting.profiles requires proxy.enable = true"
    )
    (requireEnabled perAppZapretCfg.enable perAppRoutingCfg.enable
      "proxy-suite: zapret.perApp.enable requires perAppRouting.enable = true"
    )
    (requireAvailable hasZapretProfiles perAppZapretCfg.enable
      "proxy-suite: route=zapret in perAppRouting.profiles requires zapret.perApp.enable = true"
    )
  ];

  collisionAssertions = map (item: notEqualWhen item.condition item.left item.right item.message) [
    {
      condition = globalTun.enable && perAppRoutingTun.enable;
      left = globalTun.interface;
      right = perAppRoutingTun.interface;
      message = "proxy-suite: proxy.tun.interface and proxy.tun.perApp.interface must differ";
    }
    {
      condition = globalTun.enable && perAppRoutingTun.enable;
      left = globalTun.address;
      right = perAppRoutingTun.address;
      message = "proxy-suite: proxy.tun.address and proxy.tun.perApp.address must differ";
    }
    {
      condition = globalTun.enable && perAppRoutingTun.enable;
      left = perAppRoutingTun.routeTable;
      right = globalTunAutoRouteTable;
      message = "proxy-suite: proxy.tun.perApp.routeTable must differ from the global TUN auto-route table 2022";
    }
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: proxy.tun.perApp.fwmark must differ from proxy.tproxy.fwmark when global TProxy is enabled";
    }
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: proxy.tun.perApp.fwmark must differ from proxy.tproxy.proxyMark when global TProxy is enabled";
    }
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.routeTable;
      right = globalTproxy.routeTable;
      message = "proxy-suite: proxy.tun.perApp.routeTable must differ from proxy.tproxy.routeTable when global TProxy is enabled";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.fwmark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: proxy.tproxy.perApp.fwmark must differ from proxy.tproxy.fwmark";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.fwmark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: proxy.tproxy.perApp.fwmark must differ from proxy.tproxy.proxyMark";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.routeTable;
      right = globalTproxy.routeTable;
      message = "proxy-suite: proxy.tproxy.perApp.routeTable must differ from proxy.tproxy.routeTable";
    }
    {
      condition = perAppRoutingTun.enable && perAppRoutingTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = perAppRoutingTproxy.fwmark;
      message = "proxy-suite: proxy.tun.perApp.fwmark and proxy.tproxy.perApp.fwmark must differ";
    }
    {
      condition = perAppRoutingTun.enable && perAppRoutingTproxy.enable;
      left = perAppRoutingTun.routeTable;
      right = perAppRoutingTproxy.routeTable;
      message = "proxy-suite: proxy.tun.perApp.routeTable and proxy.tproxy.perApp.routeTable must differ";
    }
    {
      condition = perAppZapretCfg.enable;
      left = perAppZapretCfg.filterMark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: zapret.perApp.filterMark must differ from proxy.tproxy.fwmark";
    }
    {
      condition = perAppZapretCfg.enable;
      left = perAppZapretCfg.filterMark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: zapret.perApp.filterMark must differ from proxy.tproxy.proxyMark";
    }
    {
      condition = perAppRoutingTun.enable && perAppZapretCfg.enable;
      left = perAppRoutingTun.fwmark;
      right = perAppZapretCfg.filterMark;
      message = "proxy-suite: proxy.tun.perApp.fwmark and zapret.perApp.filterMark must differ";
    }
    {
      condition = perAppRoutingTproxy.enable && perAppZapretCfg.enable;
      left = perAppRoutingTproxy.fwmark;
      right = perAppZapretCfg.filterMark;
      message = "proxy-suite: proxy.tproxy.perApp.fwmark and zapret.perApp.filterMark must differ";
    }
    {
      condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && globalTproxy.enable;
      left = tgWsProxyCfg.routingMark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: tgWsProxy.routingMark must differ from proxy.tproxy.fwmark";
    }
    {
      condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && globalTproxy.enable;
      left = tgWsProxyCfg.routingMark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: tgWsProxy.routingMark must differ from proxy.tproxy.proxyMark";
    }
    {
      condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && perAppRoutingTun.enable;
      left = tgWsProxyCfg.routingMark;
      right = perAppRoutingTun.fwmark;
      message = "proxy-suite: tgWsProxy.routingMark must differ from proxy.tun.perApp.fwmark";
    }
    {
      condition =
        tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && perAppRoutingTproxy.enable;
      left = tgWsProxyCfg.routingMark;
      right = perAppRoutingTproxy.fwmark;
      message = "proxy-suite: tgWsProxy.routingMark must differ from proxy.tproxy.perApp.fwmark";
    }
    {
      condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && perAppZapretCfg.enable;
      left = tgWsProxyCfg.routingMark;
      right = perAppZapretCfg.filterMark;
      message = "proxy-suite: tgWsProxy.routingMark must differ from zapret.perApp.filterMark";
    }
  ];

  perAppZapretDesyncMarks = [
    67108864
    134217728
  ];

  positiveNumberAssertions =
    map (item: mkAssertion (!item.condition || item.value > 0) item.message)
      [
        {
          condition = globalTun.enable;
          value = globalTun.mtu;
          message = "proxy-suite: proxy.tun.mtu must be greater than zero";
        }
        {
          condition = perAppRoutingTun.enable;
          value = perAppRoutingTun.mtu;
          message = "proxy-suite: proxy.tun.perApp.mtu must be greater than zero";
        }
        {
          condition = globalTproxy.enable;
          value = globalTproxy.fwmark;
          message = "proxy-suite: proxy.tproxy.fwmark must be greater than zero";
        }
        {
          condition = globalTproxy.enable;
          value = globalTproxy.proxyMark;
          message = "proxy-suite: proxy.tproxy.proxyMark must be greater than zero";
        }
        {
          condition = globalTproxy.enable;
          value = globalTproxy.routeTable;
          message = "proxy-suite: proxy.tproxy.routeTable must be greater than zero";
        }
        {
          condition = perAppRoutingTun.enable;
          value = perAppRoutingTun.fwmark;
          message = "proxy-suite: proxy.tun.perApp.fwmark must be greater than zero";
        }
        {
          condition = perAppRoutingTun.enable;
          value = perAppRoutingTun.routeTable;
          message = "proxy-suite: proxy.tun.perApp.routeTable must be greater than zero";
        }
        {
          condition = perAppRoutingTproxy.enable;
          value = perAppRoutingTproxy.fwmark;
          message = "proxy-suite: proxy.tproxy.perApp.fwmark must be greater than zero";
        }
        {
          condition = perAppRoutingTproxy.enable;
          value = perAppRoutingTproxy.routeTable;
          message = "proxy-suite: proxy.tproxy.perApp.routeTable must be greater than zero";
        }
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.filterMark;
          message = "proxy-suite: zapret.perApp.filterMark must be greater than zero";
        }
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.qnum;
          message = "proxy-suite: zapret.perApp.qnum must be greater than zero";
        }
        {
          condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy;
          value = tgWsProxyCfg.routingMark;
          message = "proxy-suite: tgWsProxy.routingMark must be greater than zero";
        }
      ];

  localProxyAuthCfg = proxyCfg.auth;
  localProxyAuthUsed =
    localProxyAuthCfg.username != null
    || localProxyAuthCfg.password != null
    || localProxyAuthCfg.passwordFile != null;
  localProxyAuthAssertions = [
    (mkAssertion (
      !proxyEnabled || !localProxyAuthUsed || localProxyAuthCfg.username != null
    ) "proxy-suite: proxy.auth requires username when password or passwordFile is set")
    (exactlyOneOf (proxyEnabled && localProxyAuthUsed) [
      localProxyAuthCfg.password
      localProxyAuthCfg.passwordFile
    ] "proxy-suite: proxy.auth requires exactly one of password or passwordFile")
  ];

  forbiddenValueAssertions =
    map (item: forbiddenValues item.condition item.value item.disallowed item.message)
      [
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.filterMark;
          disallowed = [
            536870912
            1073741824
          ];
          message = "proxy-suite: zapret.perApp.filterMark must not use zapret internal desync mark bits";
        }
        {
          condition = perAppZapretCfg.enable;
          value = globalTproxy.fwmark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: proxy.tproxy.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppZapretCfg.enable;
          value = globalTproxy.proxyMark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: proxy.tproxy.proxyMark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppRoutingTun.enable && perAppZapretCfg.enable;
          value = perAppRoutingTun.fwmark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: proxy.tun.perApp.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppRoutingTproxy.enable && perAppZapretCfg.enable;
          value = perAppRoutingTproxy.fwmark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: proxy.tproxy.perApp.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.filterMark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: zapret.perApp.filterMark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy && perAppZapretCfg.enable;
          value = tgWsProxyCfg.routingMark;
          disallowed = perAppZapretDesyncMarks;
          message = "proxy-suite: tgWsProxy.routingMark must not use per-app-zapret internal desync mark bits";
        }
      ];

  secretAssertions = [
    (exactlyOneOf tgWsProxyCfg.enable [
      tgWsProxyCfg.secret
      tgWsProxyCfg.secretFile
    ] "proxy-suite: tgWsProxy requires exactly one of secret or secretFile")
  ];

  outboundAssertions = lib.concatMap (ob: [
    (exactlyOneOf proxyEnabled
      [
        ob.urlFile
        ob.url
        ob.singBoxJson
        ob.xrayJson
        ob.json
      ]
      "proxy-suite: outbound '${ob.tag}': set exactly one of urlFile, url, singBoxJson, xrayJson, or json"
    )
    (mkAssertion (
      !singBoxEnabled || hybridEnabled || ob.xrayJson == null
    ) "proxy-suite: outbound '${ob.tag}': xrayJson is only available with proxy.xray.enable = true")
    (mkAssertion (!xrayEnabled || hybridEnabled || (ob.singBoxJson == null && ob.json == null))
      "proxy-suite: outbound '${ob.tag}': singBoxJson/json are only available with proxy.singBox.enable = true"
    )
    (mkAssertion (
      !(ob.backend == "xray") || xrayEnabled
    ) "proxy-suite: outbound '${ob.tag}': backend = \"xray\" requires proxy.xray.enable = true")
    (mkAssertion (
      !(ob.backend == "sing-box") || singBoxEnabled
    ) "proxy-suite: outbound '${ob.tag}': backend = \"sing-box\" requires proxy.singBox.enable = true")
  ]) proxyCfg.outbounds;

  subscriptionAssertions = lib.concatMap (sub: [
    (exactlyOneOf proxyEnabled [
      sub.urlFile
      sub.url
    ] "proxy-suite: subscription '${sub.tag}': set exactly one of urlFile or url")
  ]) proxyCfg.subscriptions;
in
featureAssertions
++ perAppRoutingAssertions
++ collisionAssertions
++ positiveNumberAssertions
++ localProxyAuthAssertions
++ forbiddenValueAssertions
++ secretAssertions
++ outboundAssertions
++ subscriptionAssertions
