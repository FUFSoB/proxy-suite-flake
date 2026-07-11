# Build-time sing-box backend configuration templates.
# Proxy outbounds are injected at service start time, not here.
{
  lib,
  derived,
  rules,
}:

let
  constants = derived.constants;
  inherit (derived)
    proxyCfg
    singBoxCfg
    hybridEnabled
    globalTun
    globalTproxy
    clashApiEnabled
    perAppRoutingTun
    ;
  inherit (constants)
    xrayDnsBridgePorts
    ;
  direct = rules.direct;
  defaultTunAutoRouteTableIndex = constants.tunAutoRouteTableIndex;
  defaultTunAutoRouteRulePriority = constants.tunAutoRouteRulePriority;

  mkDnsServer =
    tag: upstream: detour:
    {
      inherit tag;
      type = upstream.type;
      server = upstream.address;
      server_port = upstream.port;
    }
    // lib.optionalAttrs (detour != null) { inherit detour; };

  mkDnsConfig =
    {
      localDetour ? null,
    }:
    {
      servers = [
        (mkDnsServer "remote" proxyCfg.dns.remote "proxy")
        (mkDnsServer "local" proxyCfg.dns.local localDetour)
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

  xrayDnsBridgeHijackRule = {
    inbound = [ "xray-dns-in" ];
    network = [
      "tcp"
      "udp"
    ];
    action = "hijack-dns";
  };

  clashApiBlock = lib.optionalAttrs clashApiEnabled {
    experimental.clash_api.external_controller =
      "127.0.0.1:${toString singBoxCfg.clashApiPort}";
  };

  mkConfig =
    {
      enableMixed ? false,
      enableTProxy ? false,
      enableTun ? false,
      tunInterface ? globalTun.interface,
      tunAddress ? globalTun.address,
      tunMtu ? globalTun.mtu,
      tunAutoRoute ? true,
      tunAutoRouteTableIndex ? defaultTunAutoRouteTableIndex,
      tunAutoRouteRuleIndex ? defaultTunAutoRouteRulePriority,
      tunAutoRedirect ? true,
      tunStrictRoute ? true,
      forceLocalDnsViaProxy ? false,
      useOutboundRoutingMark ? false,
      enableClashApi ? clashApiEnabled,
      enableXrayDnsBridge ? hybridEnabled,
      xrayDnsBridgePort ? xrayDnsBridgePorts.socks,
    }:
    {
      log.level = "warn";

      dns = mkDnsConfig {
        localDetour = if forceLocalDnsViaProxy then "proxy" else null;
      };

      inbounds =
        lib.optional enableXrayDnsBridge {
          type = "direct";
          tag = "xray-dns-in";
          listen = "127.0.0.1";
          listen_port = xrayDnsBridgePort;
        }
        ++ lib.optional enableMixed {
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
        rules = lib.optionals enableXrayDnsBridge [ xrayDnsBridgeHijackRule ] ++ rules.singBoxRoutingRules;
        final = if proxyCfg.proxyByDefault then "proxy" else "direct";
      }
      // lib.optionalAttrs (enableTun && tunAutoRoute) {
        auto_detect_interface = true;
      };
    }
    // lib.optionalAttrs enableClashApi clashApiBlock;
in
{
  tproxy = mkConfig {
    enableMixed = true;
    enableTProxy = true;
    useOutboundRoutingMark = true;
    xrayDnsBridgePort = xrayDnsBridgePorts.socks;
  };

  tun = mkConfig {
    enableTun = true;
    tunInterface = globalTun.interface;
    tunAddress = globalTun.address;
    tunMtu = globalTun.mtu;
    tunAutoRoute = true;
    tunAutoRedirect = true;
    tunStrictRoute = true;
    forceLocalDnsViaProxy = false;
    enableClashApi = false;
    xrayDnsBridgePort = xrayDnsBridgePorts.tun;
  };

  perAppTun = mkConfig {
    enableTun = true;
    tunInterface = perAppRoutingTun.interface;
    tunAddress = perAppRoutingTun.address;
    tunMtu = perAppRoutingTun.mtu;
    tunAutoRoute = false;
    tunAutoRedirect = false;
    tunStrictRoute = false;
    forceLocalDnsViaProxy = false;
    useOutboundRoutingMark = globalTproxy.enable;
    enableClashApi = false;
    xrayDnsBridgePort = xrayDnsBridgePorts.perAppTun;
  };
}
