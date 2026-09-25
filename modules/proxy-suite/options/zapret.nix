{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  t = import ./types.nix { inherit lib; };
  inherit (import ./lib.nix { inherit lib; }) list bool;
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
        Which zapret to run:
        - "zapret-discord-youtube": ready-made presets and fixed site lists.
        - "zapret2": learns blocked sites at runtime.
      '';
      example = "zapret2";
    };

    # What zapret feeds back into the client routing table.
    directSync = {
      enable = bool true "Send zapret's domains direct in the proxy routing, so zapret handles them.";
      upstreamIps = bool false "Also send zapret's upstream IP lists direct.";
      userIps = bool true "Also send `zapret-discord-youtube.ips` (minus `excludeIps`) direct.";
    };

    # Shared by both engines: a netfilter-level bypass, not an engine-specific concept.
    cidrExemption = {
      enable = mkEnableOption "skipping zapret for some subnets, such as NATed VMs it would break";
      cidrs = list "Subnets zapret skips." [ "192.168.123.0/24" ];
    };

    zapret-discord-youtube = {
      configName = mkOption {
        type = types.str;
        default = "general(ALT)";
        description = "Strategy preset name (spaces are ignored).";
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
        description = ''Which game traffic to handle, or "null" for none.'';
        example = "all";
      };

      domains = list "Extra domains to unblock." [ "youtube.com" ];
      excludeDomains = list "Domains zapret never touches." [ "music.youtube.com" ];
      ips = list "Extra IPs or CIDRs to unblock." [ "203.0.113.0/24" ];
      excludeIps = list "IPs or CIDRs zapret never touches." [ "203.0.113.10/32" ];

      includeExtraUpstreamLists = bool false "Also use the upstream instagram, soundcloud and twitter lists.";

      hostlistRules = mkOption {
        type = types.listOf t.zapretHostlistRuleType;
        default = [ ];
        description = ''
          Extra site lists, each with its own strategy: copied from a `preset` or `configName`,
          or given as raw `nfqwsArgs`.
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
