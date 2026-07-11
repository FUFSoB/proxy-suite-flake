# Type submodule definitions shared across options sub-files.
{ lib }:

let
  inherit (lib) mkOption types;

  # Reused in both outboundType.routing and routing.rules entries.
  routingFields = {
    domains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Domain suffixes to match in this routing rule.
        Leave empty to skip domain-based matching for this rule entry.
      '';
      example = [
        "youtube.com"
        "discord.com"
      ];
    };
    ips = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        IP CIDRs to match in this routing rule.
        Leave empty to skip IP-based matching for this rule entry.
      '';
      example = [ "1.1.1.0/24" ];
    };
    geosites = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        sing-geosite rule-set names to match in this routing rule.
        Each name becomes a backend geosite rule-set reference.
      '';
      example = [
        "netflix"
        "google"
      ];
    };
    geoips = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        sing-geoip rule-set names to match in this routing rule.
        Each name becomes a backend geoip rule-set reference.
      '';
      example = [
        "us"
        "de"
      ];
    };
  };

  routingRuleType = types.submodule {
    options = {
      outbound = mkOption {
        type = types.str;
        description = ''
          Target outbound tag. Can be a specific server tag (only useful with
          selection = "selector" or "urltest"), or one of the built-in tags:
          "proxy" (the active proxy outbound), "direct", "block".

          With selection = "first", named proxy outbounds are collapsed into the
          single active "proxy" outbound at runtime, so per-tag routing no longer
          distinguishes between individual proxy servers.
        '';
        example = "vps-de";
      };
    }
    // routingFields;
  };

  outboundTypes = import ./types/outbounds.nix {
    inherit lib;
    inherit routingFields;
  };

  zapretTypes = import ./types/zapret.nix { inherit lib; };

  dnsUpstreamType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "udp"
          "tcp"
          "tls"
        ];
        default = "udp";
        description = ''
          DNS transport type for this upstream resolver.
        '';
        example = "tls";
      };

      address = mkOption {
        type = types.strMatching ".+";
        description = ''
          Resolver address or hostname used for this DNS upstream.
        '';
        example = "1.1.1.1";
      };

      port = mkOption {
        type = types.port;
        default = 53;
        description = ''
          Destination port for this DNS upstream.
        '';
        example = 853;
      };
    };
  };

  perAppRoutingProfileType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "^[a-z0-9][a-z0-9-]*$";
        description = ''
          Profile name used by `proxy-ctl wrap <name> -- <command>`.
          Must be unique within perAppRouting.profiles.
        '';
        example = "steam-browser";
      };

      route = mkOption {
        type = types.enum [
          "direct"
          "proxychains"
          "tun"
          "tproxy"
          "zapret"
        ];
        default = "proxychains";
        description = ''
          Per-app route backend used by proxy-ctl wrap.

          - "direct": run the command unchanged.
          - "proxychains": run the command through proxychains-ng using the
            local proxy-suite mixed SOCKS endpoint.
          - "tun": launch the command in the dedicated per-app-routing TUN slice so
            only that app's traffic is policy-routed into the app TUN backend.
          - "tproxy": launch the command in the dedicated per-app-routing TProxy
            slice so only that app's traffic is transparently intercepted by
            the local proxy TProxy inbound.
          - "zapret": launch the command in the dedicated per-app-routing zapret
            slice so only that app's traffic is handled by the separate
            per-app-scoped zapret instance.

          Additional route backends may be added in the future.
        '';
        example = "proxychains";
      };
    };
  };
in
{
  inherit
    dnsUpstreamType
    perAppRoutingProfileType
    routingFields
    routingRuleType
    ;
}
// outboundTypes
// zapretTypes
