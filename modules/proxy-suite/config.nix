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
  direct = rules.direct;

  clashApiBlock = lib.optionalAttrs (sb.selection != "first") {
    experimental = {
      clash_api = {
        external_controller = "127.0.0.1:${toString sb.clashApiPort}";
      };
    };
  };

  dnsConfig = {
    servers = [
      {
        tag = "remote";
        type = "udp";
        server = "1.1.1.1";
        detour = "proxy";
      }
      {
        tag = "local";
        type = "udp";
        server = "1.1.1.1";
        # In TUN mode, routing DNS through direct can conflict with auto_redirect.
        # In TProxy/mixed mode, direct is fine for local traffic.
        detour = "direct";
      }
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

  dnsConfigTun = dnsConfig // {
    servers = map (s: if s.tag == "local" then s // { detour = "proxy"; } else s) dnsConfig.servers;
  };

  mkConfig =
    {
      enableMixed ? false,
      enableTProxy ? false,
      enableTun ? false,
      useOutboundRoutingMark ? false,
    }:
    {
      log.level = "warn";

      dns = if enableTun then dnsConfigTun else dnsConfig;

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
          interface_name = sb.tun.interface;
          address = [ sb.tun.address ];
          mtu = sb.tun.mtu;
          auto_route = true;
          auto_redirect = true;
          strict_route = true;
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
      // lib.optionalAttrs enableTun { auto_detect_interface = true; };
    }
    // clashApiBlock;

  tproxyTemplate = mkConfig {
    enableMixed = true;
    enableTProxy = true;
    useOutboundRoutingMark = true;
  };

  tunTemplate = mkConfig {
    enableTun = true;
  };

  tproxyFile = pkgs.writeText "proxy-suite-tproxy-template.json" (builtins.toJSON tproxyTemplate);
  tunFile = pkgs.writeText "proxy-suite-tun-template.json" (builtins.toJSON tunTemplate);

in
{
  inherit tproxyFile tunFile;
}
