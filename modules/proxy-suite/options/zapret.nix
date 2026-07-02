# zapret DPI bypass options.
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
  t = import ./types.nix { inherit lib; };
in
{
  options.services.proxy-suite.zapret = {
    enable = mkEnableOption "zapret DPI bypass";

    perApp = {
      enable = mkEnableOption "per-app-scoped zapret backend for perAppRouting profiles";

      filterMark = mkOption {
        type = types.int;
        default = 268435456;
        description = ''
          Packet mark bit used to mark wrapped app traffic for the
          dedicated per-app-scoped zapret instance.
        '';
        example = 268435456;
      };

      qnum = mkOption {
        type = types.int;
        default = 201;
        description = ''
          NFQUEUE number used by the dedicated per-app-scoped zapret instance.
          This backend runs as a second zapret daemon and should use a
          queue distinct from the global zapret instance.
        '';
        example = 201;
      };
    };

    syncDirectRouting = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When zapret.enable = true, mirror zapret's upstream domain hostlists
        into proxy direct domain routing.

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
        (such as ipset-all.txt minus exclusions) into proxy direct IP routing.
      '';
      example = false;
    };

    syncDirectRoutingUserIps = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When zapret.enable = true, mirror user-defined zapret.ipsetAll and
        zapret.ipsetExclude entries into proxy direct IP routing.
      '';
      example = true;
    };

    configName = mkOption {
      type = types.str;
      default = "general(ALT)";
      description = ''
        zapret strategy preset name selected from the upstream configs
        directory. Exact filenames are accepted, and names that differ only by
        whitespace are treated as aliases.
      '';
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
        proxy direct routing.
      '';
      example = [ "youtube.com" ];
    };

    listExclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Domains to exclude from zapret interception.
        When syncDirectRouting = true, these exclusions also remove matching
        domains from the zapret-derived proxy direct-routing set.
      '';
      example = [ "music.youtube.com" ];
    };

    ipsetAll = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra IPs/CIDRs to add to zapret's ipset.
        Mirrored into proxy direct IP routing when
        syncDirectRoutingUserIps = true.
      '';
      example = [ "203.0.113.0/24" ];
    };

    ipsetExclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        IPs/CIDRs to exclude from zapret's ipset.
        Also excluded from zapret-derived proxy direct IP routing when
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
        mirrored into proxy direct routing.
      '';
      example = false;
    };

    hostlistRules = mkOption {
      type = types.listOf t.zapretHostlistRuleType;
      default = [ ];
      description = ''
        Additional named zapret hostlists with per-list DPI mitigation rules.
        Each entry generates hostlists/list-<name>.txt and can clone a built-in
        zapret family from the active config, clone it from another configName,
        add custom NFQWS rule fragments, or combine these pieces.

        defaultDomains selects same-named upstream zapret-discord-youtube
        hostlists such as "general" and "google", with the aliases "discord"
        and "youtube" for readability. defaultIps provides upstream IP/CIDR
        groups such as "all". configName is a higher-level alternative to
        nfqwsArgs and cannot be used together with nfqwsArgs.
      '';
      example = [
        {
          name = "youtube-alt9";
          defaultDomains = [ "youtube" ];
          configName = "general(ALT9)";
        }
        {
          name = "discord-alt12";
          defaultDomains = [ "discord" ];
          configName = "general (ALT12)";
        }
        {
          name = "custom-sites";
          domains = [
            "example.com"
            "example.org"
          ];
          ips = [ "203.0.113.0/24" ];
          preset = "general";
          configName = "general (SIMPLE FAKE)";
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
