# Build-time sing-box configuration templates.
# The proxy outbound(s) are injected at service start time, not here.
{
  lib,
  pkgs,
  cfg,
  rules,
}:

let
  derived = import ./derived.nix { inherit lib cfg; };
  inherit (derived)
    singBoxCfg
    globalTun
    globalTproxy
    clashApiEnabled
    ;
  perAppTun = derived.perAppRoutingTun;
  direct = rules.direct;

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
        (mkDnsServer "remote" singBoxCfg.dns.remote "proxy")
        (mkDnsServer "local" singBoxCfg.dns.local localDetour)
      ];
      rules =
        lib.optional (builtins.elem "google" singBoxCfg.routing.proxy.geosites) {
          rule_set = [ "geosite-google" ];
          server = "remote";
        }
        ++ lib.optional (direct.geosites != [ ]) {
          rule_set = map (s: "geosite-${s}") direct.geosites;
          server = "local";
        };
      final = if singBoxCfg.proxyByDefault then "remote" else "local";
    };

  clashApiBlock = lib.optionalAttrs clashApiEnabled {
    experimental = {
      clash_api = {
        external_controller = "127.0.0.1:${toString singBoxCfg.clashApiPort}";
      };
    };
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

      # Keep "local" DNS on the direct path by default, but avoid explicit
      # detour="direct" because sing-box rejects detouring to an empty
      # direct outbound. Global TUN can force local DNS through proxy.
      dns = mkDnsConfig {
        localDetour = if forceLocalDnsViaProxy then "proxy" else null;
      };

      inbounds =
        lib.optional enableMixed {
          type = "mixed";
          tag = "mixed-in";
          listen = singBoxCfg.listenAddress;
          listen_port = singBoxCfg.port;
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
            # Keep sing-box auto_route indexes explicit so service cleanup can
            # reliably remove stale policy-routing state after unclean stops.
            iproute2_table_index = tunAutoRouteTableIndex;
            iproute2_rule_index = tunAutoRouteRuleIndex;
          }
        );

      # proxy outbound(s) are prepended at runtime by the start script
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
        rules = rules.routingRules;
        final = if singBoxCfg.proxyByDefault then "proxy" else "direct";
      }
      // lib.optionalAttrs (enableTun && tunAutoRoute) {
        # sing-box recommends this with auto_route to keep its own outbound
        # connections pinned to the host's default NIC instead of looping back
        # into the TUN interface.
        auto_detect_interface = true;
      };
    }
    // lib.optionalAttrs enableClashApi clashApiBlock;

  tproxyTemplate = mkConfig {
    enableMixed = true;
    enableTProxy = true;
    useOutboundRoutingMark = true;
  };

  tunTemplate = mkConfig {
    enableTun = true;
    tunInterface = globalTun.interface;
    tunAddress = globalTun.address;
    tunMtu = globalTun.mtu;
    tunAutoRoute = true;
    tunAutoRedirect = true;
    tunStrictRoute = true;
    # Keep the bootstrap resolver on the direct path. Sending the "local" DNS
    # transport through outbound tag "proxy" causes a resolver loop in global
    # TUN mode because outbound hostname resolution and urltest probe lookups
    # recurse back into the same proxy path.
    forceLocalDnsViaProxy = false;
    enableClashApi = false;
  };

  perAppTunTemplate = mkConfig {
    enableTun = true;
    tunInterface = perAppTun.interface;
    tunAddress = perAppTun.address;
    tunMtu = perAppTun.mtu;
    tunAutoRoute = false;
    tunAutoRedirect = false;
    tunStrictRoute = false;
    forceLocalDnsViaProxy = false;
    # App TUN can be used alongside TProxy; mark direct egress so TProxy output
    # rules do not re-intercept sing-box's own packets.
    useOutboundRoutingMark = globalTproxy.enable;
    enableClashApi = false;
  };

  tproxyFile = pkgs.writeText "proxy-suite-tproxy-template.json" (builtins.toJSON tproxyTemplate);
  tunFile = pkgs.writeText "proxy-suite-tun-template.json" (builtins.toJSON tunTemplate);
  perAppTunFile = pkgs.writeText "proxy-suite-per-app-tun-template.json" (
    builtins.toJSON perAppTunTemplate
  );
  routeModeRulesFile = pkgs.writeText "proxy-suite-route-mode-rules.json" (
    builtins.toJSON rules.routeModeRules
  );

in
{
  inherit tproxyFile tunFile perAppTunFile routeModeRulesFile;
}
