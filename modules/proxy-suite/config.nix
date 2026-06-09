# Build-time proxy backend configuration templates.
# Proxy outbounds are injected at service start time, not here.
{
  lib,
  pkgs,
  cfg,
  rules,
}:

let
  derived = import ./derived.nix { inherit lib cfg; };
  inherit (derived)
    proxyCfg
    singBoxCfg
    xrayEnabled
    globalTun
    globalTproxy
    clashApiEnabled
    ;
  perAppTun = derived.perAppRoutingTun;
  direct = rules.direct;
  xrayGlobalTunIPv6Address = "fd66:19::1/64";
  xrayPerAppTunIPv6Address = "fd66:20::1/64";
  xrayFakeDnsPools = [
    {
      ipPool = "198.18.0.0/15";
      poolSize = 32768;
    }
    {
      ipPool = "fc00::/18";
      poolSize = 32768;
    }
  ];
  stripCidr = cidr: builtins.head (lib.splitString "/" cidr);

  mkSingBoxDnsServer =
    tag: upstream: detour:
    {
      inherit tag;
      type = upstream.type;
      server = upstream.address;
      server_port = upstream.port;
    }
    // lib.optionalAttrs (detour != null) { inherit detour; };

  mkSingBoxDnsConfig =
    {
      localDetour ? null,
    }:
    {
      servers = [
        (mkSingBoxDnsServer "remote" proxyCfg.dns.remote "proxy")
        (mkSingBoxDnsServer "local" proxyCfg.dns.local localDetour)
      ];
      rules =
        lib.optional (builtins.elem "google" proxyCfg.routing.proxy.geosites) {
          rule_set = [ "geosite-google" ];
          server = "remote";
        }
        ++ lib.optional (direct.geosites != [ ]) {
          rule_set = map (s: "geosite-${s}") direct.geosites;
          server = "local";
        };
      final = if proxyCfg.proxyByDefault then "remote" else "local";
    };

  clashApiBlock = lib.optionalAttrs clashApiEnabled {
    experimental = {
      clash_api = {
        external_controller = "127.0.0.1:${toString singBoxCfg.clashApiPort}";
      };
    };
  };

  mkSingBoxConfig =
    {
      enableMixed ? false,
      enableTProxy ? false,
      enableTun ? false,
      tunInterface ? globalTun.interface,
      tunAddress ? globalTun.address,
      tunMtu ? globalTun.mtu,
      tunAutoRoute ? true,
      tunAutoRouteTableIndex ? 2022,
      tunAutoRouteRuleIndex ? 9000,
      tunAutoRedirect ? true,
      tunStrictRoute ? true,
      forceLocalDnsViaProxy ? false,
      useOutboundRoutingMark ? false,
      enableClashApi ? clashApiEnabled,
    }:
    {
      log.level = "warn";

      dns = mkSingBoxDnsConfig {
        localDetour = if forceLocalDnsViaProxy then "proxy" else null;
      };

      inbounds =
        lib.optional enableMixed {
          type = "mixed";
          tag = "mixed-in";
          listen = proxyCfg.listenAddress;
          listen_port = proxyCfg.port;
        }
        ++ lib.optional enableTProxy {
          type = "tproxy";
          tag = "tproxy-in";
          listen = "127.0.0.1";
          listen_port = globalTproxy.port;
        }
        ++ lib.optional enableTun (
          {
            type = "tun";
            tag = "tun-in";
            interface_name = tunInterface;
            address = [ tunAddress ];
            mtu = tunMtu;
            auto_route = tunAutoRoute;
            auto_redirect = tunAutoRedirect;
            strict_route = tunStrictRoute;
            stack = "mixed";
          }
          // lib.optionalAttrs tunAutoRoute {
            iproute2_table_index = tunAutoRouteTableIndex;
            iproute2_rule_index = tunAutoRouteRuleIndex;
          }
        );

      outbounds = [
        (
          {
            type = "direct";
            tag = "direct";
          }
          // lib.optionalAttrs useOutboundRoutingMark { routing_mark = globalTproxy.proxyMark; }
        )
        {
          type = "block";
          tag = "block";
        }
      ];

      route = {
        default_domain_resolver = "local";
        rule_set = rules.geositeRuleSets ++ rules.geoIPRuleSets;
        rules = rules.singBoxRoutingRules;
        final = if proxyCfg.proxyByDefault then "proxy" else "direct";
      }
      // lib.optionalAttrs (enableTun && tunAutoRoute) {
        auto_detect_interface = true;
      };
    }
    // lib.optionalAttrs enableClashApi clashApiBlock;

  xrayDnsAddress =
    upstream:
    let
      base =
        if upstream.type == "tls" then
          "tls://${upstream.address}"
        else
          upstream.address;
    in
    if upstream.port == 53 && upstream.type != "tls" then
      base
    else
      "${base}:${toString upstream.port}";

  mkXrayDnsServer =
    tag: upstream:
    {
      address = xrayDnsAddress upstream;
      inherit tag;
      queryStrategy = "UseIP";
    };

  mkXraySniffing =
    {
      fakeDnsOnly ? false,
    }:
    if fakeDnsOnly then
      {
        enabled = true;
        destOverride = [ "fakedns" ];
        metadataOnly = true;
      }
    else
      {
        enabled = true;
        destOverride = [
          "http"
          "tls"
          "quic"
        ];
      };

  xraySniffing = mkXraySniffing { };

  mkXrayTunDnsConfig =
    {
      preferRemote ? proxyCfg.proxyByDefault,
    }:
    let
      primaryTag = if preferRemote then "remote" else "local";
      secondaryTag = if preferRemote then "local" else "remote";
      primaryUpstream = if preferRemote then proxyCfg.dns.remote else proxyCfg.dns.local;
      secondaryUpstream = if preferRemote then proxyCfg.dns.local else proxyCfg.dns.remote;
    in
    {
      queryStrategy = "UseIP";
      tag = "dns-in";
      servers = [
        {
          address = "fakedns";
          tag = "fakedns";
        }
        (mkXrayDnsServer primaryTag primaryUpstream)
        (mkXrayDnsServer secondaryTag secondaryUpstream)
      ];
    };

  xrayTunDnsHijackRule = {
    type = "field";
    inboundTag = [ "tun-in" ];
    network = "tcp,udp";
    port = 53;
    outboundTag = "dns-out";
    ruleTag = "dns-hijack";
  };

  xrayTunDnsUpstreamRule = {
    type = "field";
    inboundTag = [ "dns-in" ];
    network = "tcp,udp";
    outboundTag = "direct";
    ruleTag = "dns-upstream-direct";
  };

  xrayFinalRule =
    tag:
    {
      type = "field";
      network = "tcp,udp";
      ruleTag = "final-default";
    }
    // (
      if tag == "proxy" && proxyCfg.selection == "urltest" then
        { balancerTag = "proxy"; }
      else
        { outboundTag = tag; }
    );

  xrayRouteRules =
    rules.xrayRoutingRules ++ [ (xrayFinalRule (if proxyCfg.proxyByDefault then "proxy" else "direct")) ];

  xrayDirectOutbound =
    useOutboundRoutingMark:
    {
      protocol = "freedom";
      tag = "direct";
      settings = { };
    }
    // lib.optionalAttrs useOutboundRoutingMark {
      streamSettings.sockopt.mark = globalTproxy.proxyMark;
    };

  mkXrayConfig =
    {
      enableMixed ? false,
      enableTProxy ? false,
      enableTun ? false,
      tunInterface ? globalTun.interface,
      tunAddress ? globalTun.address,
      tunIPv6Address ? null,
      tunMtu ? globalTun.mtu,
      useOutboundRoutingMark ? false,
      enableUrlTest ? proxyCfg.selection == "urltest",
      domainStrategy ? "IPIfNonMatch",
      enableTunFakeDns ? false,
    }:
    let
      tunDnsServers = [
        (if proxyCfg.proxyByDefault then proxyCfg.dns.remote.address else proxyCfg.dns.local.address)
        (if proxyCfg.proxyByDefault then proxyCfg.dns.local.address else proxyCfg.dns.remote.address)
      ];
      xrayTunSniffing = mkXraySniffing { fakeDnsOnly = enableTunFakeDns; };
      xrayDnsConfig =
        if enableTunFakeDns then
          mkXrayTunDnsConfig { }
        else
          {
            servers = [
              (xrayDnsAddress proxyCfg.dns.remote)
              (xrayDnsAddress proxyCfg.dns.local)
            ];
          };
      xrayTunOutbounds = lib.optionals enableTunFakeDns [
        {
          protocol = "dns";
          tag = "dns-out";
          settings = {
            userLevel = 0;
            rules = [
              {
                action = "direct";
                qType = "2-27,29-65535";
              }
            ];
          };
        }
      ];
      xrayRoutingRules =
        lib.optionals enableTunFakeDns [
          xrayTunDnsUpstreamRule
          xrayTunDnsHijackRule
        ]
        ++ rules.xrayRoutingRules
        ++ [ (xrayFinalRule (if proxyCfg.proxyByDefault then "proxy" else "direct")) ];
    in
    {
      log.loglevel = "warning";
      dns = xrayDnsConfig;
      inbounds =
        lib.optional enableMixed {
          tag = "mixed-in";
          protocol = "socks";
          listen = proxyCfg.listenAddress;
          port = proxyCfg.port;
          settings = {
            auth = "noauth";
            udp = true;
            ip = proxyCfg.listenAddress;
          };
          sniffing = xraySniffing;
        }
        ++ lib.optional enableTProxy {
          tag = "tproxy-in";
          protocol = "tunnel";
          listen = "127.0.0.1";
          port = globalTproxy.port;
          settings = {
            allowedNetwork = "tcp,udp";
            followRedirect = true;
          };
          streamSettings.sockopt.tproxy = "tproxy";
          sniffing = xraySniffing;
        }
        ++ lib.optional enableTun {
          tag = "tun-in";
          protocol = "tun";
          settings = {
            name = tunInterface;
            mtu = tunMtu;
            gateway = [ tunAddress ] ++ lib.optionals (tunIPv6Address != null) [ tunIPv6Address ];
            dns = tunDnsServers;
            userLevel = 0;
            autoOutboundsInterface = "auto";
          };
          sniffing = xrayTunSniffing;
        };
      outbounds = xrayTunOutbounds ++ [
        (xrayDirectOutbound useOutboundRoutingMark)
        {
          protocol = "blackhole";
          tag = "block";
          settings = { };
        }
      ];
      routing = {
        domainStrategy = domainStrategy;
        domainMatcher = "hybrid";
        rules = xrayRoutingRules;
      }
      // lib.optionalAttrs enableUrlTest {
        balancers = [
          {
            tag = "proxy";
            selector = [ "proxy-suite-ob-" ];
            strategy = { type = "leastPing"; };
          }
        ];
      };
    }
    // lib.optionalAttrs enableUrlTest {
      observatory = {
        subjectSelector = [ "proxy-suite-ob-" ];
        probeUrl = proxyCfg.urlTest.url;
        probeInterval = proxyCfg.urlTest.interval;
      };
    }
    // lib.optionalAttrs enableTunFakeDns { fakedns = xrayFakeDnsPools; };

  singBoxTproxyTemplate = mkSingBoxConfig {
    enableMixed = true;
    enableTProxy = true;
    useOutboundRoutingMark = true;
  };

  singBoxTunTemplate = mkSingBoxConfig {
    enableTun = true;
    tunInterface = globalTun.interface;
    tunAddress = globalTun.address;
    tunMtu = globalTun.mtu;
    tunAutoRoute = true;
    tunAutoRedirect = true;
    tunStrictRoute = true;
    forceLocalDnsViaProxy = false;
    enableClashApi = false;
  };

  singBoxPerAppTunTemplate = mkSingBoxConfig {
    enableTun = true;
    tunInterface = perAppTun.interface;
    tunAddress = perAppTun.address;
    tunMtu = perAppTun.mtu;
    tunAutoRoute = false;
    tunAutoRedirect = false;
    tunStrictRoute = false;
    forceLocalDnsViaProxy = false;
    useOutboundRoutingMark = globalTproxy.enable;
    enableClashApi = false;
  };

  xrayTproxyTemplate = mkXrayConfig {
    enableMixed = true;
    enableTProxy = true;
    useOutboundRoutingMark = true;
  };

  xrayTunTemplate = mkXrayConfig {
    enableTun = true;
    tunInterface = globalTun.interface;
    tunAddress = globalTun.address;
    tunIPv6Address = xrayGlobalTunIPv6Address;
    tunMtu = globalTun.mtu;
    useOutboundRoutingMark = true;
    enableTunFakeDns = true;
  };

  xrayPerAppTunTemplate = mkXrayConfig {
    enableTun = true;
    tunInterface = perAppTun.interface;
    tunAddress = perAppTun.address;
    tunIPv6Address = xrayPerAppTunIPv6Address;
    tunMtu = perAppTun.mtu;
    useOutboundRoutingMark = true;
    enableTunFakeDns = true;
  };

  tproxyTemplate = if xrayEnabled then xrayTproxyTemplate else singBoxTproxyTemplate;
  tunTemplate = if xrayEnabled then xrayTunTemplate else singBoxTunTemplate;
  perAppTunTemplate = if xrayEnabled then xrayPerAppTunTemplate else singBoxPerAppTunTemplate;
  routeModeRules = if xrayEnabled then rules.xrayRouteModeRules else rules.singBoxRouteModeRules;

  tproxyFile = pkgs.writeText "proxy-suite-tproxy-template.json" (builtins.toJSON tproxyTemplate);
  tunFile = pkgs.writeText "proxy-suite-tun-template.json" (builtins.toJSON tunTemplate);
  perAppTunFile = pkgs.writeText "proxy-suite-per-app-tun-template.json" (
    builtins.toJSON perAppTunTemplate
  );
  routeModeRulesFile = pkgs.writeText "proxy-suite-route-mode-rules.json" (
    builtins.toJSON routeModeRules
  );

in
{
  inherit tproxyFile tunFile perAppTunFile routeModeRulesFile;
}
