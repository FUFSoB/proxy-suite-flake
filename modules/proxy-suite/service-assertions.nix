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
    singBoxCfg
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    ;

  featureAssertions = [
    (requireAvailable singBoxCfg.enable (
      singBoxCfg.outbounds != [ ] || singBoxCfg.subscriptions != [ ]
    ) "proxy-suite: at least one outbound or subscription is required when singBox.enable = true")
    (uniqueValues singBoxCfg.enable outboundTags "proxy-suite: outbound tags must be unique")
    (uniqueValues singBoxCfg.enable subscriptionTags
      "proxy-suite: subscription tags must be unique because they are used as cache keys and outbound tag prefixes"
    )
    (mkAssertion (
      !singBoxCfg.enable || builtins.all (tag: !builtins.elem tag builtinTags) outboundTags
    ) "proxy-suite: outbound tags must not use reserved names: proxy, direct, block")
    (mkAssertion (!singBoxCfg.enable || invalidRoutingTargets == [ ])
      "proxy-suite: routing.rules reference unknown outbound tag(s): ${lib.concatStringsSep ", " invalidRoutingTargets}"
    )
    (requireEnabled globalTun.enable singBoxCfg.enable
      "proxy-suite: singBox.tun.enable requires singBox.enable = true"
    )
    (requireEnabled globalTproxy.enable singBoxCfg.enable
      "proxy-suite: singBox.tproxy.enable requires singBox.enable = true"
    )
    (requireEnabled globalTun.autostart globalTun.enable
      "proxy-suite: singBox.tun.autostart requires singBox.tun.enable = true"
    )
    (requireEnabled globalTproxy.autostart globalTproxy.enable
      "proxy-suite: singBox.tproxy.autostart requires singBox.tproxy.enable = true"
    )
    (mkAssertion
      (!(globalTproxy.enable && globalTproxy.autostart && globalTun.enable && globalTun.autostart))
      "proxy-suite: singBox.tproxy.autostart and singBox.tun.autostart cannot both be enabled at the same time"
    )
  ];

  perAppRoutingAssertions = [
    (requireAvailable (perAppRoutingCfg.profiles != [ ]) perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.profiles requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingCfg.proxychains.enable perAppRoutingCfg.enable
      "proxy-suite: perAppRouting.proxychains.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingCfg.proxychains.enable singBoxCfg.enable
      "proxy-suite: perAppRouting.proxychains.enable requires singBox.enable = true"
    )
    (uniqueValues true effectivePerAppRoutingProfileNames
      "proxy-suite: perAppRouting profile names must be unique"
    )
    (requireAvailable hasProxychainsProfiles perAppRoutingCfg.proxychains.enable
      "proxy-suite: route=proxychains in perAppRouting.profiles requires perAppRouting.proxychains.enable = true"
    )
    (requireAvailable hasProxychainsProfiles singBoxCfg.enable
      "proxy-suite: route=proxychains in perAppRouting.profiles requires singBox.enable = true"
    )
    (requireEnabled perAppRoutingTun.enable perAppRoutingCfg.enable
      "proxy-suite: singBox.tun.perApp.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingTun.enable singBoxCfg.enable
      "proxy-suite: singBox.tun.perApp.enable requires singBox.enable = true"
    )
    (requireAvailable hasTunProfiles perAppRoutingTun.enable
      "proxy-suite: route=tun in perAppRouting.profiles requires singBox.tun.perApp.enable = true"
    )
    (requireAvailable hasTunProfiles singBoxCfg.enable
      "proxy-suite: route=tun in perAppRouting.profiles requires singBox.enable = true"
    )
    (requireEnabled perAppRoutingTproxy.enable perAppRoutingCfg.enable
      "proxy-suite: singBox.tproxy.perApp.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppRoutingTproxy.enable singBoxCfg.enable
      "proxy-suite: singBox.tproxy.perApp.enable requires singBox.enable = true"
    )
    (requireAvailable hasTproxyProfiles perAppRoutingTproxy.enable
      "proxy-suite: route=tproxy in perAppRouting.profiles requires singBox.tproxy.perApp.enable = true"
    )
    (requireAvailable hasTproxyProfiles singBoxCfg.enable
      "proxy-suite: route=tproxy in perAppRouting.profiles requires singBox.enable = true"
    )
    (requireEnabled perAppZapretCfg.enable perAppRoutingCfg.enable
      "proxy-suite: zapret.perApp.enable requires perAppRouting.enable = true"
    )
    (requireEnabled perAppZapretCfg.enable cfg.zapret.enable
      "proxy-suite: zapret.perApp.enable requires zapret.enable = true"
    )
    (requireAvailable hasZapretProfiles (perAppZapretCfg.enable && cfg.zapret.enable)
      "proxy-suite: route=zapret in perAppRouting.profiles requires zapret.perApp.enable = true and zapret.enable = true"
    )
  ];

  collisionAssertions = map (item: notEqualWhen item.condition item.left item.right item.message) [
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: singBox.tun.perApp.fwmark must differ from singBox.tproxy.fwmark when global TProxy is enabled";
    }
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: singBox.tun.perApp.fwmark must differ from singBox.tproxy.proxyMark when global TProxy is enabled";
    }
    {
      condition = perAppRoutingTun.enable && globalTproxy.enable;
      left = perAppRoutingTun.routeTable;
      right = globalTproxy.routeTable;
      message = "proxy-suite: singBox.tun.perApp.routeTable must differ from singBox.tproxy.routeTable when global TProxy is enabled";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.fwmark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: singBox.tproxy.perApp.fwmark must differ from singBox.tproxy.fwmark";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.fwmark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: singBox.tproxy.perApp.fwmark must differ from singBox.tproxy.proxyMark";
    }
    {
      condition = perAppRoutingTproxy.enable;
      left = perAppRoutingTproxy.routeTable;
      right = globalTproxy.routeTable;
      message = "proxy-suite: singBox.tproxy.perApp.routeTable must differ from singBox.tproxy.routeTable";
    }
    {
      condition = perAppRoutingTun.enable && perAppRoutingTproxy.enable;
      left = perAppRoutingTun.fwmark;
      right = perAppRoutingTproxy.fwmark;
      message = "proxy-suite: singBox.tun.perApp.fwmark and singBox.tproxy.perApp.fwmark must differ";
    }
    {
      condition = perAppRoutingTun.enable && perAppRoutingTproxy.enable;
      left = perAppRoutingTun.routeTable;
      right = perAppRoutingTproxy.routeTable;
      message = "proxy-suite: singBox.tun.perApp.routeTable and singBox.tproxy.perApp.routeTable must differ";
    }
    {
      condition = perAppZapretCfg.enable;
      left = perAppZapretCfg.filterMark;
      right = globalTproxy.fwmark;
      message = "proxy-suite: zapret.perApp.filterMark must differ from singBox.tproxy.fwmark";
    }
    {
      condition = perAppZapretCfg.enable;
      left = perAppZapretCfg.filterMark;
      right = globalTproxy.proxyMark;
      message = "proxy-suite: zapret.perApp.filterMark must differ from singBox.tproxy.proxyMark";
    }
    {
      condition = perAppRoutingTun.enable && perAppZapretCfg.enable;
      left = perAppRoutingTun.fwmark;
      right = perAppZapretCfg.filterMark;
      message = "proxy-suite: singBox.tun.perApp.fwmark and zapret.perApp.filterMark must differ";
    }
    {
      condition = perAppRoutingTproxy.enable && perAppZapretCfg.enable;
      left = perAppRoutingTproxy.fwmark;
      right = perAppZapretCfg.filterMark;
      message = "proxy-suite: singBox.tproxy.perApp.fwmark and zapret.perApp.filterMark must differ";
    }
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
          disallowed = [
            67108864
            134217728
          ];
          message = "proxy-suite: singBox.tproxy.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppZapretCfg.enable;
          value = globalTproxy.proxyMark;
          disallowed = [
            67108864
            134217728
          ];
          message = "proxy-suite: singBox.tproxy.proxyMark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppRoutingTun.enable && perAppZapretCfg.enable;
          value = perAppRoutingTun.fwmark;
          disallowed = [
            67108864
            134217728
          ];
          message = "proxy-suite: singBox.tun.perApp.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppRoutingTproxy.enable && perAppZapretCfg.enable;
          value = perAppRoutingTproxy.fwmark;
          disallowed = [
            67108864
            134217728
          ];
          message = "proxy-suite: singBox.tproxy.perApp.fwmark must not use per-app-zapret internal desync mark bits";
        }
        {
          condition = perAppZapretCfg.enable;
          value = perAppZapretCfg.filterMark;
          disallowed = [
            67108864
            134217728
          ];
          message = "proxy-suite: zapret.perApp.filterMark must not use per-app-zapret internal desync mark bits";
        }
      ];

  secretAssertions = [
    (exactlyOneOf tgWsProxyCfg.enable [
      tgWsProxyCfg.secret
      tgWsProxyCfg.secretFile
    ] "proxy-suite: tgWsProxy requires exactly one of secret or secretFile")
  ];

  outboundAssertions = lib.concatMap (ob: [
    (exactlyOneOf singBoxCfg.enable [
      ob.urlFile
      ob.url
      ob.json
    ] "proxy-suite: outbound '${ob.tag}': set exactly one of urlFile, url, or json")
  ]) singBoxCfg.outbounds;

  subscriptionAssertions = lib.concatMap (sub: [
    (exactlyOneOf singBoxCfg.enable [
      sub.urlFile
      sub.url
    ] "proxy-suite: subscription '${sub.tag}': set exactly one of urlFile or url")
  ]) singBoxCfg.subscriptions;
in
featureAssertions
++ perAppRoutingAssertions
++ collisionAssertions
++ forbiddenValueAssertions
++ secretAssertions
++ outboundAssertions
++ subscriptionAssertions
