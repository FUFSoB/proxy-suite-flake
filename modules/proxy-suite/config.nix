# Build-time sing-box configuration templates.
# The proxy outbound(s) are injected at service start time, not here.
{
  lib,
  pkgs,
  cfg,
  rules,
}:

let
  sb = cfg.singBox;
  art = cfg.appRouting.backends.tun;
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
    { localDetour ? null }:
    {
      servers = [
        (mkDnsServer "remote" sb.dns.remote "proxy")
        (mkDnsServer "local" sb.dns.local localDetour)
      ];
      rules =
        lib.optional (builtins.elem "google" sb.routing.proxy.geosites) {
          rule_set = [ "geosite-google" ];
          server = "remote";
        }
        ++ lib.optional (direct.geosites != [ ]) {
          rule_set = map (s: "geosite-${s}") direct.geosites;
          server = "local";
        };
      final = if sb.proxyByDefault then "remote" else "local";
    };

  clashApiBlock = lib.optionalAttrs (sb.selection != "first") {
    experimental = {
      clash_api = {
        external_controller = "127.0.0.1:${toString sb.clashApiPort}";
      };
    };
  };

  mkConfig =
    {
      enableMixed ? false,
      enableTProxy ? false,
      enableTun ? false,
      tunInterface ? sb.tun.interface,
      tunAddress ? sb.tun.address,
      tunMtu ? sb.tun.mtu,
      tunAutoRoute ? true,
      tunAutoRedirect ? true,
      tunStrictRoute ? true,
      forceLocalDnsViaProxy ? false,
      useOutboundRoutingMark ? false,
      enableClashApi ? true,
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
          listen = sb.listenAddress;
          listen_port = sb.port;
        }
        ++ lib.optional enableTProxy {
          type = "tproxy";
          tag = "tproxy-in";
          listen = "127.0.0.1";
          listen_port = sb.tproxyPort;
        }
        ++ lib.optional enableTun {
          type = "tun";
          tag = "tun-in";
          interface_name = tunInterface;
          address = [ tunAddress ];
          mtu = tunMtu;
          auto_route = tunAutoRoute;
          auto_redirect = tunAutoRedirect;
          strict_route = tunStrictRoute;
          stack = "mixed";
        };

      # proxy outbound(s) are prepended at runtime by the start script
      outbounds = [
        (
          {
            type = "direct";
            tag = "direct";
          }
          // lib.optionalAttrs useOutboundRoutingMark { routing_mark = sb.proxyMark; }
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
        final = if sb.proxyByDefault then "proxy" else "direct";
      }
      // lib.optionalAttrs (enableTun && tunAutoRoute) { auto_detect_interface = true; };
    }
    // lib.optionalAttrs enableClashApi clashApiBlock;

  tproxyTemplate = mkConfig {
    enableMixed = true;
    enableTProxy = true;
    useOutboundRoutingMark = true;
    enableClashApi = true;
  };

  tunTemplate = mkConfig {
    enableTun = true;
    tunInterface = sb.tun.interface;
    tunAddress = sb.tun.address;
    tunMtu = sb.tun.mtu;
    tunAutoRoute = true;
    tunAutoRedirect = true;
    tunStrictRoute = true;
    forceLocalDnsViaProxy = true;
    enableClashApi = false;
  };

  appTunTemplate = mkConfig {
    enableTun = true;
    tunInterface = art.interface;
    tunAddress = art.address;
    tunMtu = art.mtu;
    tunAutoRoute = false;
    tunAutoRedirect = false;
    tunStrictRoute = false;
    forceLocalDnsViaProxy = false;
    # App TUN can be used alongside TProxy; mark direct egress so TProxy output
    # rules do not re-intercept sing-box's own packets.
    useOutboundRoutingMark = sb.tproxy.enable;
    enableClashApi = false;
  };

  tproxyFile = pkgs.writeText "proxy-suite-tproxy-template.json" (builtins.toJSON tproxyTemplate);
  tunFile = pkgs.writeText "proxy-suite-tun-template.json" (builtins.toJSON tunTemplate);
  appTunFile = pkgs.writeText "proxy-suite-app-tun-template.json" (builtins.toJSON appTunTemplate);

in
{
  inherit tproxyFile tunFile appTunFile;
}
