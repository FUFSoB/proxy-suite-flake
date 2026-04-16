# zapret DPI bypass options.
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
  t = import ./types.nix { inherit lib; };
in
{
  options.services.proxy-suite.zapret = {
    enable = mkEnableOption "zapret DPI bypass";

    syncDirectRouting = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When zapret.enable = true, mirror zapret's upstream domain hostlists
        into sing-box direct domain routing.

        This includes the default zapret domain lists and any custom
        hostlistRules entries with enableDirectSync = true.
      '';
      example = true;
    };

    syncDirectRoutingUpstreamIps = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When zapret.enable = true, mirror zapret's upstream ipset ranges
        (such as ipset-all.txt minus exclusions) into sing-box direct IP routing.
      '';
      example = false;
    };

    syncDirectRoutingUserIps = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When zapret.enable = true, mirror user-defined zapret.ipsetAll and
        zapret.ipsetExclude entries into sing-box direct IP routing.
      '';
      example = true;
    };

    configName = mkOption {
      type = types.str;
      default = "general(ALT)";
      description = "zapret strategy preset name passed through to the generated zapret configuration.";
      example = "general(ALT)";
    };

    gameFilter = mkOption {
      type = types.str;
      default = "null";
      description = ''zapret game traffic filter mode: "all", "tcp", "udp", or "null" to disable.'';
      example = "null";
    };

    listGeneral = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra domains to include in zapret's interception list.
        When syncDirectRouting = true, these domains are also mirrored into
        sing-box direct routing.
      '';
      example = [ "youtube.com" ];
    };

    listExclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Domains to exclude from zapret interception.
        When syncDirectRouting = true, these exclusions also remove matching
        domains from the zapret-derived sing-box direct-routing set.
      '';
      example = [ "music.youtube.com" ];
    };

    ipsetAll = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra IPs/CIDRs to add to zapret's ipset.
        Mirrored into sing-box direct IP routing when
        syncDirectRoutingUserIps = true.
      '';
      example = [ "203.0.113.0/24" ];
    };

    ipsetExclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        IPs/CIDRs to exclude from zapret's ipset.
        Also excluded from zapret-derived sing-box direct IP routing when
        syncDirectRoutingUserIps = true.
      '';
      example = [ "203.0.113.10/32" ];
    };

    includeExtraUpstreamLists = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Automatically activate upstream list-instagram.txt, list-soundcloud.txt,
        and list-twitter.txt in the generated zapret config when the selected
        upstream preset does not already reference them.

        When syncDirectRouting = true, domains from these extra lists are also
        mirrored into sing-box direct routing.
      '';
      example = false;
    };

    hostlistRules = mkOption {
      type = types.listOf t.zapretHostlistRuleType;
      default = [ ];
      description = ''
        Additional named zapret hostlists with per-list DPI mitigation rules.
        Each entry generates hostlists/list-<name>.txt and can clone a built-in
        zapret family, add custom NFQWS rule fragments, or both.

        Each entry must define at least one domain and at least one of preset
        or nfqwsArgs.
      '';
      example = [
        {
          name = "googlevideo";
          domains = [
            "googlevideo.com"
            "ggpht.com"
          ];
          preset = "google";
        }
        {
          name = "example";
          domains = [
            "example.com"
            "example.de"
          ];
          preset = "general";
          nfqwsArgs = [
            "--filter-tcp=443 --dpi-desync=fake,multisplit"
          ];
        }
      ];
    };

    cidrExemption = {
      enable = mkEnableOption "CIDR exemption from zapret NFQUEUE";

      cidrs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "192.168.123.0/24"
          "10.0.0.0/8"
        ];
        description = ''
          Subnets to exempt from zapret's NFQUEUE mangle rules.
          Useful when a VM (libvirt, etc.) is behind NAT and zapret
          would corrupt its traffic through the host's nftables.
        '';
      };
    };
  };
}
