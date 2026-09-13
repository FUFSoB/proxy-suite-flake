{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  t = import ./types.nix { inherit lib; };
  list =
    description: example:
    mkOption {
      type = types.listOf types.str;
      default = [ ];
      inherit description example;
    };
  bool =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };
in
{
  options.services.proxy-suite.zapret = {
    enable = mkEnableOption "zapret DPI bypass";

    engine = mkOption {
      type = types.enum [
        "zapret-discord-youtube"
        "zapret2"
      ];
      default = "zapret-discord-youtube";
      description = ''
        "zapret-discord-youtube": nfqws with curated presets and static hostlists (zapret.zapret-discord-youtube).
        "zapret2": nfqws2, which learns blocked hosts at runtime (zapret.zapret2).
      '';
      example = "zapret2";
    };

    # What zapret feeds back into the client routing table.
    directSync = {
      enable = bool true "Add zapret's domain hostlists to proxy.routing.direct.";
      upstreamIps = bool false "Add zapret's upstream ipsets to proxy.routing.direct.";
      userIps = bool true "Add zapret-discord-youtube.ips, minus zapret-discord-youtube.excludeIps, to proxy.routing.direct.";
    };

    # Shared by both engines: a netfilter-level bypass, not an engine-specific concept.
    cidrExemption = {
      enable = mkEnableOption "exempting subnets from zapret, e.g. NATed VMs whose traffic it would break";
      cidrs = list "Exempted subnets." [ "192.168.123.0/24" ];
    };

    zapret-discord-youtube = {
      configName = mkOption {
        type = types.str;
        default = "general(ALT)";
        description = "Upstream strategy preset. Names that differ only in whitespace match.";
        example = "general (ALT9)";
      };

      gameFilter = mkOption {
        type = types.enum [
          "all"
          "tcp"
          "udp"
          "null"
        ];
        default = "null";
        description = ''Game traffic filter, or "null" for off.'';
        example = "all";
      };

      domains = list "Extra domains to bypass." [ "youtube.com" ];
      excludeDomains = list "Domains never bypassed." [ "music.youtube.com" ];
      ips = list "Extra IPs/CIDRs to bypass." [ "203.0.113.0/24" ];
      excludeIps = list "IPs/CIDRs never bypassed." [ "203.0.113.10/32" ];

      includeExtraUpstreamLists = bool false "Also use the upstream instagram, soundcloud and twitter lists.";

      hostlistRules = mkOption {
        type = types.listOf t.zapretHostlistRuleType;
        default = [ ];
        description = ''
          Extra named hostlists, each with its own strategy: cloned from a preset or configName,
          or given as nfqwsArgs.
        '';
        example = [
          {
            name = "youtube-alt9";
            defaultDomains = [ "youtube" ];
            configName = "general(ALT9)";
          }
          {
            name = "custom-sites";
            domains = [ "example.com" ];
            preset = "general";
          }
        ];
      };
    };
  };
}
