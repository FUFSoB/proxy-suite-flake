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
      useOutboundRoutingMark ? false,
      fakeIp ? false,
    }:
    {
      servers = [
        (mkDnsServer "remote" proxyCfg.dns.remote "proxy")
        (mkDnsServer "local" proxyCfg.dns.local localDetour)
      ]
      ++ map (
        ob:
        mkDnsServer (constants.awgDnsServerTag ob.tag) proxyCfg.dns.remote null
        // {
          bind_interface = ob.interface;
        }
        // lib.optionalAttrs useOutboundRoutingMark { routing_mark = globalTproxy.proxyMark; }
      ) derived.awgInterfaceOutbounds
      ++ lib.optional fakeIp {
        tag = "fakeip";
        type = "fakeip";
        inet4_range = proxyCfg.dns.fakeIp.inet4Range;
      }
      ++ proxyCfg.dns.singBox.servers;
      # The route mode keeps the user's rules and fake IP, and may drop what sits between.
      rules =
        proxyCfg.dns.singBox.rules
        ++ rules.singBoxDnsRules
        # Only what apps ask through the TUN: the XRay sidecar's and sing-box's own lookups
        # need real addresses.
        ++ lib.optional fakeIp {
          inbound = [ "tun-in" ];
          query_type = [
            "A"
            "AAAA"
          ];
          server = "fakeip";
        };
      final = if (proxyCfg.routing.default == "proxy") then "remote" else "local";
    }
    // lib.optionalAttrs (proxyCfg.dns.strategy != null) { inherit (proxyCfg.dns) strategy; }
    // lib.optionalAttrs (proxyCfg.dns.clientSubnet != null) {
      client_subnet = proxyCfg.dns.clientSubnet;
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
      # Names the fake IP cache: TUN configs only.
      fakeIpCache ? null,
    }:
    let
      fakeIp = fakeIpCache != null && proxyCfg.dns.fakeIp.enable;
    in
    lib.recursiveUpdate (
    {
      log.level = "warn";

      dns = mkDnsConfig {
        localDetour = if forceLocalDnsViaProxy then "proxy" else null;
        inherit useOutboundRoutingMark fakeIp;
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
          listen = proxyCfg.listener.address;
          listen_port = proxyCfg.listener.port;
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
        final = if (proxyCfg.routing.default == "proxy") then "proxy" else "direct";
      }
      // lib.optionalAttrs (enableTun && tunAutoRoute) {
        auto_detect_interface = true;
      };
    }
    // lib.optionalAttrs enableClashApi clashApiBlock)
    # Fake addresses handed out survive a restart, so apps still holding one keep working. The
    # start script creates the directory; nothing else is stored, since TUN configs have no
    # Clash API to switch a selector with.
    (lib.optionalAttrs fakeIp {
      experimental.cache_file = {
        enabled = true;
        path = "${constants.fakeIpCacheDir}/${fakeIpCache}.db";
        store_fakeip = true;
      };
    });
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
    fakeIpCache = "tun";
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
    fakeIpCache = "per-app-tun";
  };
}
