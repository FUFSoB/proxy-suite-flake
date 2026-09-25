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
      description = "Where traffic goes when no rule matches.";
      example = "direct";
    };

    directRu = mkOption {
      type = types.bool;
      default = true;
      description = ''Send Russian sites and IPs (geosite "category-ru", geoip "ru") direct.'';
    };

    proxy = {
      domains = list "Domains, with their subdomains, sent through the proxy." [ "youtube.com" ];
      ips = list "IP ranges (CIDR) sent through the proxy." [ "1.1.1.0/24" ];
      geosites = list "Geosite categories sent through the proxy." [ "netflix" ];
      geoips = list "Geoip codes sent through the proxy." [ "us" ];
      ruleSets = list "Rule sets from `ruleSets` sent through the proxy." [ "antifilter" ];
    };

    direct = {
      domains =
        list "Domains, with their subdomains, sent direct. `zapret.directSync` adds zapret's domains."
          [
            "internal.example"
          ];
      ips = list "IP ranges (CIDR) sent direct." [ "10.10.0.0/16" ];
      geosites = list "Geosite categories sent direct." [ "category-ru" ];
      geoips = list "Geoip codes sent direct." [ "ru" ];
      ruleSets = list "Rule sets from `ruleSets` sent direct." [ "ru-services" ];
    };

    block = {
      domains = list "Domains, with their subdomains, to block." [ "ads.example.com" ];
      ips = list "IP ranges (CIDR) to block." [ "203.0.113.0/24" ];
      geosites = list "Geosite categories to block." [ "category-ads-all" ];
      geoips = list "Geoip codes to block." [ "cn" ];
      ruleSets = list "Rule sets from `ruleSets` to block." [ "ads" ];
    };

    rules = mkOption {
      type = types.listOf t.routingRuleType;
      default = [ ];
      description = "Rules checked in order before the proxy, direct and block lists. The first match wins.";
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
              description = "URL of the sing-box rule set.";
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
              description = ''"binary" (.srs) or "source" (JSON). `null`: guess from the URL.'';
            };
            detour = mkOption {
              type = types.enum [
                "proxy"
                "direct"
              ];
              default = "proxy";
              description = "Download through the proxy or directly.";
            };
          };
        }
      );
      default = { };
      description = ''
        Named sing-box rule sets, usable in any `ruleSets` list. They are downloaded every
        `ruleSetUpdateInterval` or on `proxy-ctl proxy rulesets update`, without a restart. A rule
        set matches nothing until its first download. Not available with the "xray" backend.
      '';
      example = {
        antifilter.url = "https://example.com/antifilter.srs";
      };
    };

    ruleSetUpdateInterval = mkOption {
      type = types.str;
      default = "1d";
      description = "How often rule sets are refreshed (systemd time span).";
      example = "6h";
    };
  };
}
