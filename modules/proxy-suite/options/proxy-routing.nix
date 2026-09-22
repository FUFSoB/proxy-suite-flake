{ lib, ... }:

let
  inherit (lib) mkOption types;
  t = import ./types.nix { inherit lib; };
  inherit (import ./lib.nix { inherit lib; }) list;
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
      ruleSets = list "Names from ruleSets sent through the proxy." [ "antifilter" ];
    };

    direct = {
      domains =
        list "Domain suffixes sent direct. zapret hostlists join them when zapret.directSync.enable is on."
          [
            "internal.example"
          ];
      ips = list "IP CIDRs sent direct." [ "10.10.0.0/16" ];
      geosites = list "Geosite names sent direct." [ "category-ru" ];
      geoips = list "Geoip names sent direct." [ "ru" ];
      ruleSets = list "Names from ruleSets sent direct." [ "ru-services" ];
    };

    block = {
      domains = list "Domain suffixes blocked." [ "ads.example.com" ];
      ips = list "IP CIDRs blocked." [ "203.0.113.0/24" ];
      geosites = list "Geosite names blocked." [ "category-ads-all" ];
      geoips = list "Geoip names blocked." [ "cn" ];
      ruleSets = list "Names from ruleSets blocked." [ "ads" ];
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

    ruleSets = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            url = mkOption {
              type = types.strMatching "https?://.+";
              description = "Where the sing-box rule set is downloaded from.";
              example = "https://example.com/antifilter.srs";
            };
            format = mkOption {
              type = types.nullOr (
                types.enum [
                  "binary"
                  "source"
                ]
              );
              default = null;
              description = ''"binary" (.srs) or "source" (JSON). Null goes by the URL: .srs is binary.'';
            };
            detour = mkOption {
              type = types.enum [
                "proxy"
                "direct"
              ];
              default = "proxy";
              description = "Downloaded through the local proxy, or directly.";
            };
          };
        }
      );
      default = { };
      description = ''
        sing-box rule sets kept up to date at runtime, for the ruleSets of proxy, direct, block,
        rules and an outbound's routing. They are fetched every ruleSetUpdateInterval and on
        `proxy-ctl proxy rulesets update`, and sing-box picks up a new file without a restart;
        until the first fetch one matches nothing. Not for backend = "xray".
      '';
      example = {
        antifilter.url = "https://example.com/antifilter.srs";
      };
    };

    ruleSetUpdateInterval = mkOption {
      type = types.str;
      default = "1d";
      description = "How often ruleSets are downloaded again (systemd time span).";
      example = "6h";
    };
  };
}
