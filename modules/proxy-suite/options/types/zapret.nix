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
        description = "List name.";
        example = "cloudflare";
      };

      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domains in this list.";
        example = [ "example.com" ];
      };

      defaultDomains = mkOption {
        type = types.listOf zapretDefaultDomainType;
        default = [ ];
        description = ''
          Upstream lists to include ("discord" is "general", "youtube" is "google"). Without
          `preset`, use only one, so the strategy can be inferred from it.
        '';
        example = [ "google" ];
      };

      ips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "IPs or CIDRs in this list.";
        example = [ "203.0.113.0/24" ];
      };

      defaultIps = mkOption {
        type = types.listOf zapretDefaultIpType;
        default = [ ];
        description = "Upstream IP lists to include.";
        example = [ "all" ];
      };

      preset = mkOption {
        type = types.nullOr zapretPresetType;
        default = null;
        description = "Strategy to copy, from `configName` or the active config.";
        example = "google";
      };

      configName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Config to copy the strategy from. Cannot be used with `nfqwsArgs`.";
        example = "general(ALT9)";
      };

      nfqwsArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Raw nfqws arguments; `--hostlist` and `--new` are added. Cannot be used with `configName`.";
        example = [ "--filter-tcp=443 --dpi-desync=fake,multisplit" ];
      };

      enableDirectSync = mkOption {
        type = types.bool;
        default = true;
        description = "Include these domains in `zapret.directSync`.";
      };
    };
  };
in
{
  inherit zapretHostlistRuleType;
}
