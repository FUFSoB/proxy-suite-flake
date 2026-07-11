# zapret hostlist and preset option type definitions.
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

  zapretDefaultIpType = types.enum [
    "all"
  ];

  zapretHostlistRuleType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "^[a-z0-9][a-z0-9-]*$";
        description = ''
          Custom hostlist name. Used to generate hostlists/list-<name>.txt
          inside the derived zapret config directory.
        '';
        example = "cloudflare";
      };

      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Domains written into the generated custom zapret hostlist file.
          Can be combined with defaultDomains.
        '';
        example = [
          "example.com"
          "example.de"
        ];
      };

      defaultDomains = mkOption {
        type = types.listOf zapretDefaultDomainType;
        default = [ ];
        description = ''
          Built-in domain groups copied from zapret-discord-youtube hostlists.
          These are expanded and combined with domains.

          Each value maps directly to the same-named upstream file:
          "general" uses list-general.txt, "google" uses list-google.txt,
          and the remaining values use their corresponding list-<name>.txt.

          "discord" is an alias for "general"; "youtube" is an alias for
          "google".

          When "general" or "discord" is used together with configName, the
          module also clones the selected config's Discord UDP voice rule
          (--filter-l7=discord,stun).

          When preset is unset, use one defaultDomains entry per rule so the
          module can infer a single rule family. Split groups into separate
          rules when they need different strategies.
        '';
        example = [ "google" ];
      };

      ips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          IPs or CIDRs written into the generated custom zapret ipset file.
          Can be combined with defaultIps.
        '';
        example = [
          "203.0.113.0/24"
          "2001:db8::/32"
        ];
      };

      defaultIps = mkOption {
        type = types.listOf zapretDefaultIpType;
        default = [ ];
        description = ''
          Built-in IP/CIDR groups copied from zapret-discord-youtube ipsets.

          "all" uses the upstream ipset-all.txt list. The upstream bundle does
          not split this list by service, so site-specific defaults remain in
          defaultDomains.
        '';
        example = [ "all" ];
      };

      preset = mkOption {
        type = types.nullOr zapretPresetType;
        default = null;
        description = ''
          Clone this built-in NFQWS rule family for this hostlist. When
          configName is set, the family is cloned from that zapret config;
          otherwise it is cloned from the active global zapret config.

          When unset and defaultDomains is non-empty, rule families are
          inferred from defaultDomains.
        '';
        example = "google";
      };

      configName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          zapret config name to clone NFQWS rules from for this hostlist.
          Names use the same matching rules as services.proxy-suite.zapret.configName.

          This is a higher-level alternative to nfqwsArgs and cannot be used
          together with nfqwsArgs.
        '';
        example = "general(ALT9)";
      };

      nfqwsArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Additional NFQWS argument fragments for this hostlist.
          The module injects --hostlist=... and trailing --new automatically.

          This cannot be used together with configName.
        '';
        example = [
          "--filter-tcp=443 --dpi-desync=fake,multisplit"
        ];
      };

      enableDirectSync = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this custom hostlist should also be mirrored into proxy
          direct domain routing when zapret.syncDirectRouting = true.
        '';
      };
    };
  };
in
{
  inherit
    zapretDefaultDomainType
    zapretDefaultIpType
    zapretPresetType
    zapretHostlistRuleType
    ;
}
