{ lib }:

let
  inherit (lib) mkOption types;
  inherit (import ./lib.nix { inherit lib; }) list;

  # `what` ends each description, saying where the matches go.
  routingFields = what: {
    domains = list "Domains, with their subdomains, ${what}." [ "youtube.com" ];
    ips = list "IP ranges (CIDR) ${what}." [ "1.1.1.0/24" ];
    geosites = list "Geosite categories ${what} (see `geodata`)." [ "netflix" ];
    geoips = list "Geoip codes ${what}; countries by default (see `geodata`)." [ "us" ];
  };
  # The client's routing also matches downloaded rule sets, which XRay cannot read.
  clientRoutingFields =
    what:
    routingFields what
    // {
      ruleSets = list "Rule sets from `proxy.routing.ruleSets` ${what} (sing-box and hybrid only)." [
        "antifilter"
      ];
    };

  routingRuleType = types.submodule {
    options = {
      outbound = mkOption {
        type = types.str;
        description = ''Outbound tag, or "proxy", "direct" or "block".'';
        example = "vps-de";
      };
    }
    // clientRoutingFields "that this rule matches";
  };

  dnsUpstreamType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "udp"
          "tcp"
          "tls"
        ];
        default = "udp";
        description = "DNS transport.";
      };

      address = mkOption {
        type = types.strMatching ".+";
        description = "Resolver address.";
        example = "1.1.1.1";
      };

      port = mkOption {
        type = types.port;
        default = 53;
        description = "Resolver port.";
      };
    };
  };

  perAppRoutingProfileType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "^[a-z0-9][a-z0-9-]*$";
        description = "Unique profile name.";
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
          How the app is routed: "direct" (untouched), "proxychains", or the per-app "tun",
          "tproxy" or "zapret".
        '';
      };
    };
  };
in
{
  inherit
    dnsUpstreamType
    perAppRoutingProfileType
    routingFields
    clientRoutingFields
    routingRuleType
    ;
}
// import ./types/outbounds.nix {
  inherit lib;
  routingFields = clientRoutingFields;
}
// import ./types/zapret.nix { inherit lib; }
// import ./types/inbounds.nix { inherit lib; }
// import ./types/amnezia-wg.nix { inherit lib; }
