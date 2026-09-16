{ lib }:

let
  inherit (lib) mkOption types;

  list =
    description: example:
    mkOption {
      type = types.listOf types.str;
      default = [ ];
      inherit description example;
    };

  routingFields = {
    domains = list "Domain suffixes to match." [ "youtube.com" ];
    ips = list "IP CIDRs to match." [ "1.1.1.0/24" ];
    geosites = list "Geosite names to match (see geodata)." [ "netflix" ];
    geoips = list "Geoip names to match (see geodata; the defaults are country codes only)." [ "us" ];
  };

  routingRuleType = types.submodule {
    options = {
      outbound = mkOption {
        type = types.str;
        description = ''Outbound tag, or "proxy", "direct", "block".'';
        example = "vps-de";
      };
    }
    // routingFields;
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
        description = "Profile name, unique.";
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
          Backend: "direct" (unchanged), "proxychains", or the per-app "tun", "tproxy" or "zapret"
          backend of perAppRouting.
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
    routingRuleType
    ;
}
// import ./types/outbounds.nix { inherit lib routingFields; }
// import ./types/zapret.nix { inherit lib; }
// import ./types/inbounds.nix { inherit lib; }
// import ./types/amnezia-wg.nix { inherit lib; }
