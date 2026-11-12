# Routing rules and rule-set definitions for sing-box
{
  lib,
  pkgs,
  cfg,
  zapret,
  # The zapret2 strategy sources' site lists; the docs assemble without them.
  zapret2Sources ? { },
}:

let
  derived = import ./derived.nix { inherit lib cfg; };
  r = cfg.proxy.routing;
  proxyCfg = derived.proxyCfg;
  tgWsProxyCfg = cfg.tgWsProxy;
  zapretDirect = import ./rules-zapret-direct.nix {
    inherit
      lib
      pkgs
      cfg
      zapret
      zapret2Sources
      ;
  };
  inherit (zapretDirect) direct;
  zapretDirectRules = zapretDirect.zapretDirect;

  customRuleCategory =
    outbound:
    if outbound == "direct" then
      "direct"
    else if outbound == "block" then
      "block"
    else
      "proxy";

  # Pure XRay's urltest prefixes every outbound for its balancer.
  resolveTag =
    tag:
    if
      derived.pureXrayEnabled
      && derived.selectionMode == "urltest"
      && !builtins.elem tag derived.builtinTags
    then
      "proxy-suite-ob-${tag}"
    else
      tag;

  # Collect per-outbound routing attached directly to outbound definitions.
  perOutboundRules = lib.concatMap (
    ob:
    let
      ro = ob.routing;
      hasAny =
        ro.domains != [ ]
        || ro.ips != [ ]
        || ro.geosites != [ ]
        || ro.geoips != [ ]
        || ro.ruleSets != [ ]
        || ro.asns != [ ];
    in
    lib.optional hasAny {
      outbound = resolveTag ob.tag;
      inherit (ro)
        domains
        ips
        geosites
        geoips
        ruleSets
        asns
        ;
    }
  ) proxyCfg.outbounds;

  # .onion names go to Tor in every route mode: nothing else can reach them.
  onionOutbound = if derived.torRouteOnion then resolveTag derived.torOutboundTag else null;

  # mitm.hosts, ahead of the rest: a rule like any other, so the names are looked up as a
  # proxied one's are.
  mitmHostRules = lib.optional (derived.mitmOutboundEnabled && derived.mitmCfg.hosts != [ ]) {
    outbound = derived.mitmOutboundTag;
    domains = derived.mitmCfg.hosts;
    ips = [ ];
    geosites = [ ];
    geoips = [ ];
    ruleSets = [ ];
    asns = [ ];
  };

  # What mitmproxy has read comes back on mitm-return and leaves by the upstream chosen,
  # never by "mitm" again; what mitm.listener and mitm.interfaces take in goes to it whole.
  # Among the common rules: no route mode or runtime rule comes before them, and the hop
  # guard above still does.
  mitmCommonRules =
    let
      m = derived.mitmCfg;
      listenerExposed =
        !(
          lib.hasPrefix "127." m.listener.address
          || m.listener.address == "::1"
          || m.listener.address == "localhost"
        );
      # Not this host's own programs.
      remote = {
        source_ip_cidr = [
          "127.0.0.0/8"
          "::1/128"
        ];
        invert = true;
      };
      divertIn = [ "mitm-tproxy-in" ] ++ lib.optional proxyCfg.ipv6 "mitm-tproxy-in6";
    in
    lib.optionals derived.mitmOutboundEnabled (
      [
        {
          inbound = [ "mitm-return" ];
          outbound = derived.mitmUpstreamSelector;
        }
      ]
      ++ lib.optionals derived.mitmListenerEnabled (
        # A listener others reach: one of them could ask for 127.0.0.1, or a name resolving
        # there, and have this host's loopback-only services dialed from here (as mixed-in's
        # guard, backend-jq-filter.nix).
        lib.optionals listenerExposed [
          {
            type = "logical";
            mode = "and";
            rules = [
              { inbound = [ "mitm-in" ]; }
              remote
            ];
            action = "resolve";
            server = "local";
          }
          {
            type = "logical";
            mode = "and";
            rules = [
              {
                inbound = [ "mitm-in" ];
                ip_cidr = derived.proxyInboundsLoopback;
              }
              remote
            ];
            action = "reject";
          }
        ]
        ++ [
          # mitmproxy is an HTTP proxy: it carries no UDP.
          {
            inbound = [ "mitm-in" ];
            network = [ "udp" ];
            action = "reject";
          }
          {
            inbound = [ "mitm-in" ];
            outbound = derived.mitmOutboundTag;
          }
        ]
      )
      ++ lib.optionals derived.mitmInterfacesEnabled [
        # QUIC refused, so the guests take TCP; their other UDP follows the rules below.
        {
          inbound = divertIn;
          network = [ "udp" ];
          port = [ 443 ];
          action = "reject";
        }
        {
          inbound = divertIn;
          network = [ "tcp" ];
          outbound = derived.mitmOutboundTag;
        }
      ]
    );

  # All custom rules in priority order: per-outbound first, then explicit routing.rules.
  customRules =
    mitmHostRules
    ++ perOutboundRules
    ++ map (rule: rule // { outbound = resolveTag rule.outbound; }) r.rules;

  singBoxRules = import ./rules/sing-box.nix {
    inherit
      lib
      r
      direct
      tgWsProxyCfg
      customRules
      customRuleCategory
      onionOutbound
      mitmCommonRules
      ;
    inherit (cfg) geodata;
    inherit (derived)
      ruleSets
      proxyInboundsLoopback
      declaredAsns
      asnTag
      asnPath
      ;
    inherit (proxyCfg.dns) browserDoh;
    hopPorts = lib.optionals cfg.host.privileged derived.hopPorts;
  };
  inherit (singBoxRules)
    geositeRuleSets
    geoIPRuleSets
    asnRuleSets
    remoteRuleSets
    singBoxRoutingRules
    singBoxRouteModeRules
    singBoxDnsRules
    ;

  xrayRules = import ./rules/xray.nix {
    inherit
      lib
      r
      direct
      tgWsProxyCfg
      customRules
      customRuleCategory
      onionOutbound
      ;
    inherit (derived) selectionMode proxyInboundsLoopback;
    inherit (proxyCfg.dns) browserDoh;
  };
  inherit (xrayRules) xrayRoutingRules xrayRouteModeRules;

  routingRules = singBoxRoutingRules;
  routeModeRules = singBoxRouteModeRules;

  # The configuration's sections in match order, each at a fixed priority that runtime
  # routing rules (`proxy-ctl proxy rules`) sort among; `proxy rules list` and the Routing tab
  # show them. Tags as the user wrote them, not as the backend spells them.
  matchFields = rule: {
    domains = rule.domains or [ ];
    ips = rule.ips or [ ];
    geosites = rule.geosites or [ ];
    geoips = rule.geoips or [ ];
    ruleSets = rule.ruleSets or [ ];
    asns = rule.asns or [ ];
  };
  routingSections = [
    {
      id = "rules";
      priority = 100;
      label = "routing.rules";
      entries =
        lib.concatMap (
          ob:
          let
            m = matchFields ob.routing;
          in
          lib.optional (lib.any (v: v != [ ]) (builtins.attrValues m)) (m // { target = ob.tag; })
        ) proxyCfg.outbounds
        ++ map (rule: matchFields rule // { target = rule.outbound; }) r.rules;
    }
    {
      id = "proxy";
      priority = 200;
      label = "routing.proxy: domains and ips";
      entries = [
        (matchFields { inherit (r.proxy) domains ips; } // { target = "proxy"; })
      ];
    }
    {
      id = "block";
      priority = 300;
      label = "routing.block";
      entries = [ (matchFields r.block // { target = "block"; }) ];
    }
    {
      id = "direct";
      priority = 400;
      label = "routing.direct, private addresses";
      entries = [
        (matchFields (direct // { inherit (r.direct) ruleSets asns; }) // { target = "direct"; })
      ];
    }
    {
      id = "proxyGeo";
      priority = 500;
      label = "routing.proxy: geosites, geoips, rule sets and ASNs";
      entries = [
        (
          matchFields {
            inherit (r.proxy)
              geosites
              geoips
              ruleSets
              asns
              ;
          }
          // {
            target = "proxy";
          }
        )
      ];
    }
  ];

in
{
  inherit
    direct
    zapretDirectRules
    geositeRuleSets
    geoIPRuleSets
    asnRuleSets
    remoteRuleSets
    singBoxRoutingRules
    singBoxRouteModeRules
    singBoxDnsRules
    xrayRoutingRules
    xrayRouteModeRules
    routeModeRules
    routingRules
    routingSections
    ;
}
