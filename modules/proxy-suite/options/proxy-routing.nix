{ lib, ... }:

let
  inherit (lib) mkOption types;
  t = import ./types.nix { inherit lib; };
  list =
    description: example:
    mkOption {
      type = types.listOf types.str;
      default = [ ];
      inherit description example;
    };
in
{
  options.services.proxy-suite.proxy.routing = {
    default = mkOption {
      type = types.enum [
        "proxy"
        "direct"
      ];
      default = "proxy";
      description = "Where traffic no routing rule matches goes.";
      example = "direct";
    };

    directRu = mkOption {
      type = types.bool;
      default = true;
      description = ''Send geosite "category-ru" and geoip "ru" direct.'';
    };

    proxy = {
      domains = list "Domain suffixes sent through the proxy." [ "youtube.com" ];
      ips = list "IP CIDRs sent through the proxy." [ "1.1.1.0/24" ];
      geosites = list "Geosite names sent through the proxy." [ "netflix" ];
      geoips = list "Geoip names sent through the proxy." [ "us" ];
    };

    direct = {
      domains = list "Domain suffixes sent direct. zapret hostlists join them when zapret.directSync.enable is on." [
        "internal.example"
      ];
      ips = list "IP CIDRs sent direct." [ "10.10.0.0/16" ];
      geosites = list "Geosite names sent direct." [ "category-ru" ];
      geoips = list "Geoip names sent direct." [ "ru" ];
    };

    block = {
      domains = list "Domain suffixes blocked." [ "ads.example.com" ];
      ips = list "IP CIDRs blocked." [ "203.0.113.0/24" ];
      geosites = list "Geosite names blocked." [ "category-ads-all" ];
      geoips = list "Geoip names blocked." [ "cn" ];
    };

    rules = mkOption {
      type = types.listOf t.routingRuleType;
      default = [ ];
      description = "Rules checked before the proxy/direct/block lists, in order; the first match wins.";
      example = [
        {
          outbound = "vps-de";
          geosites = [ "netflix" ];
        }
        {
          outbound = "direct";
          domains = [ "internal.corp" ];
        }
      ];
    };
  };
}
