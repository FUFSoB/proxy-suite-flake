{ lib }:

let
  inherit (lib) mkOption types;

  zapretPresetType = types.enum [
    "general"
    "google"
    "instagram"
    "soundcloud"
    "twitter"
  ];

  zapretDefaultDomainType = types.enum [
    "general"
    "google"
    "discord"
    "youtube"
    "instagram"
    "soundcloud"
    "twitter"
  ];

  zapretDefaultIpType = types.enum [ "all" ];

  zapretHostlistRuleType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "^[a-z0-9][a-z0-9-]*$";
        description = "Hostlist name (hostlists/list-<name>.txt).";
        example = "cloudflare";
      };

      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domains in this hostlist.";
        example = [ "example.com" ];
      };

      defaultDomains = mkOption {
        type = types.listOf zapretDefaultDomainType;
        default = [ ];
        description = ''
          Upstream lists to include ("discord" = "general", "youtube" = "google"). Without preset,
          use one per rule so the strategy family can be inferred.
        '';
        example = [ "google" ];
      };

      ips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "IPs/CIDRs in this rule's ipset.";
        example = [ "203.0.113.0/24" ];
      };

      defaultIps = mkOption {
        type = types.listOf zapretDefaultIpType;
        default = [ ];
        description = ''Upstream ipsets to include ("all" is ipset-all.txt).'';
        example = [ "all" ];
      };

      preset = mkOption {
        type = types.nullOr zapretPresetType;
        default = null;
        description = "Strategy family to clone, from configName or the active config.";
        example = "google";
      };

      configName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Config to clone strategies from. Exclusive with nfqwsArgs.";
        example = "general(ALT9)";
      };

      nfqwsArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Raw NFQWS arguments; --hostlist and --new are added. Exclusive with configName.";
        example = [ "--filter-tcp=443 --dpi-desync=fake,multisplit" ];
      };

      enableDirectSync = mkOption {
        type = types.bool;
        default = true;
        description = "Include these domains in zapret.directSync.";
      };
    };
  };
in
{
  inherit zapretHostlistRuleType;
}
