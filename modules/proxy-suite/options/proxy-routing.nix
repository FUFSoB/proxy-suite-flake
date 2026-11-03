{ lib, ... }:

let
  inherit (lib) mkOption types;
  t = import ./types.nix { inherit lib; };
  inherit (import ./lib.nix { inherit lib; }) list asnList;
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

    blockQuic = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Refuse QUIC (UDP to port 443) on its way to a proxy, so browsers switch to TCP at once
        rather than run HTTP/3 over a tunnel that carries UDP badly. Only what the rules send
        through a proxy: what goes direct (zapret unblocks QUIC there), through an outbound that
        carries UDP itself (hysteria2, TUIC, WireGuard, AmneziaWG, WARP) and rules that name a
        network or port themselves keep it. Mostly matters for TUN and TProxy: browsers do not
        send QUIC through a SOCKS proxy.
      '';
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
      asns =
        asnList "Autonomous systems (all their addresses) sent through the proxy; see `asnUpdateInterval`."
          [ 62041 ];
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
      asns = asnList "Autonomous systems (all their addresses) sent direct; see `asnUpdateInterval`." [
        "AS12389"
      ];
    };

    block = {
      domains = list "Domains, with their subdomains, to block." [ "ads.example.com" ];
      ips = list "IP ranges (CIDR) to block." [ "203.0.113.0/24" ];
      geosites = list "Geosite categories to block." [ "category-ads-all" ];
      geoips = list "Geoip codes to block." [ "cn" ];
      ruleSets = list "Rule sets from `ruleSets` to block." [ "ads" ];
      asns = asnList "Autonomous systems (all their addresses) to block; see `asnUpdateInterval`." [
        "AS15169"
      ];
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
              type = types.strMatching "https://.+";
              description = "URL of the sing-box rule set (https only).";
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

    asnUpdateInterval = mkOption {
      type = types.str;
      default = "1d";
      description = ''
        How often the address lists of the autonomous systems in `asns` (here, in `rules`, on
        outbounds, and in runtime rules: `proxy-ctl proxy rules add proxy asn:62041`) are
        refetched (systemd time span). They come from the ipverse asn-ip dataset on GitHub,
        through the proxy; an ASN matches nothing until its list first arrives.
        `proxy-ctl proxy rulesets update` fetches them now.
      '';
      example = "12h";
    };
  };
}
