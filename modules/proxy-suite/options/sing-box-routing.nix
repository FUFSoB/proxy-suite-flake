{ lib, ... }:

let
  inherit (lib) mkOption types;
  t = import ./types.nix { inherit lib; };
in
{
  options.services.proxy-suite.singBox.routing = {
    enableRuDirect = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Automatically append "category-ru" to routing.direct.geosites and
        "ru" to routing.direct.geoips.

        This is additive: user-defined routing.direct.* entries still apply.
      '';
      example = true;
    };

    proxy = t.routingFields;

    direct = {
      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Domain suffixes to send direct (bypass proxy).
          Merged with zapret-synced direct domains when zapret direct sync
          options are enabled.
        '';
        example = [ "internal.example" ];
      };
      ips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          IP CIDRs to send direct.
          Merged with zapret-synced direct IPs when the corresponding zapret
          sync options are enabled.
        '';
        example = [ "10.10.0.0/16" ];
      };
      geosites = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          sing-geosite names to send direct.
          "category-ru" is added automatically when enableRuDirect = true.
        '';
        example = [ "category-ru" ];
      };
      geoips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          sing-geoip names to send direct.
          "ru" is added automatically when enableRuDirect = true.
        '';
        example = [ "ru" ];
      };
    };

    block = {
      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domain suffixes to block entirely.";
        example = [ "ads.example.com" ];
      };
      ips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "IP CIDRs to block.";
        example = [ "203.0.113.0/24" ];
      };
      geosites = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "sing-geosite names to block.";
        example = [ "category-ads-all" ];
      };
      geoips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "sing-geoip names to block.";
        example = [ "cn" ];
      };
    };

    rules = mkOption {
      type = types.listOf t.routingRuleType;
      default = [ ];
      description = ''
        Explicit routing rules evaluated before global proxy/direct/block lists.
        Each rule routes matching traffic to a specific outbound tag.

        The outbound can be a configured outbound tag (useful with selector/urltest),
        or one of: "proxy" (active proxy), "direct", "block".

        Order is preserved. The first matching rule wins in sing-box.
        With selection = "first", non-built-in outbound tags are effectively
        routed to the single active "proxy" outbound.
      '';
      example = [
        {
          outbound = "vps-de";
          domains = [ "netflix.com" ];
          geosites = [ "netflix" ];
        }
        {
          outbound = "direct";
          domains = [ "internal.corp" ];
        }
        {
          outbound = "block";
          domains = [ "ads.example.com" ];
        }
      ];
    };
  };
}
