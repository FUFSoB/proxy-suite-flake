# Options for the generated HOME and WHITELIST groups. The generator itself lives in
# ../autogroups.nix (mkAutoGroups); options/proxy-outbounds.nix merges its groups into
# proxy.groups, and this file reports its warnings. See docs/autogroups-draft.md.
{
  config,
  lib,
  options,
  ...
}:
let
  inherit (lib) mkEnableOption mkOption types;

  autoGroups = config.services.proxy-suite.proxy.autoGroups;
  generated = (import ../autogroups.nix { inherit lib; }).mkAutoGroups {
    inherit (config.services.proxy-suite.proxy) subscriptions;
    config = autoGroups;
  };
in
{
  options.services.proxy-suite.proxy.autoGroups = {
    enable = mkEnableOption "automatic HOME and WHITELIST outbound groups" // {
      description = ''
        Generate two outbound groups from the declared subscriptions:
        - the home group (`homeGroupName`): every entry of every subscription, plus
          `extraHomeGlobs`; the everyday pool of main and reserve servers;
        - the whitelist group (`whitelistGroupName`): only subscription entries whose tag carries
          a `whitelistTokens` token.

        Both are resolved at start against the tags a subscription actually holds then, so a
        refreshed subscription needs no changes here. The groups are added to `proxy.groups`
        automatically; a manually declared group of the same name wins.
      '';
    };

    homeGroupName = mkOption {
      type = types.strMatching "[A-Za-z0-9_.-]+";
      default = "home";
      description = "Tag of the generated home group. A manual group with this name wins.";
      example = "pool";
    };

    whitelistGroupName = mkOption {
      type = types.strMatching "[A-Za-z0-9_.-]+";
      default = "whitelist";
      description = "Tag of the generated whitelist group. A manual group with this name wins.";
      example = "mobile-wl";
    };

    whitelistTokens = mkOption {
      type = types.listOf types.str;
      default = [
        "WL"
        "WLTE"
        "LTE"
        "🏳️"
      ];
      description = ''
        Tokens that make a server a whitelist entry, matched against whole tokens of a tag, not
        as substrings. Tokens are split on `-`, `_`, space, `.`, `|`, `/` and whitespace, so
        `LTE` matches `sub-LTE-1` and `sub-foo_lte_bar` but not `complete` or `welt`.

        Matching ignores ASCII case and the emoji presentation selector (U+FE0F), so `wl`,
        `Wlte` and `🏳` match `WL`, `WLTE` and `🏳️`. Nix cannot do NFKC nor general Unicode case
        folding: a non-ASCII token matches only its exact spelling at build time. A runtime
        matcher over the fetched tags is the planned second stage.

        Generated globs need a literal separator, and the glob language has only `*` and `?`,
        so entries with `.`, ` `, `/` or `|` between tokens need `extraWhitelistGlobs`.
      '';
      example = [
        "WL"
        "WLTE"
        "LTE"
        "🏳️"
      ];
    };

    extraWhitelistGlobs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra globs (`*`, `?`) matched against outbound tags and added to the whitelist group,
        for tags the token patterns cannot express (other separators, non-ASCII case). Prefer a
        subscription-wide form such as `"my-sub-*_WL_*"`.
      '';
      example = [ "mobile-*WL*" ];
    };

    extraHomeGlobs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra globs added to the home group, for outbounds outside a subscription. Reserved
        subscriptions are already members through `subscriptions`.
      '';
      example = [ "warp*" ];
    };

    strategy = mkOption {
      type = types.enum [
        "failover"
        "urltest"
        "selector"
      ];
      default = "failover";
      description = "Strategy of both generated groups; see `proxy.groups.<name>.strategy`.";
    };

    failback = mkOption {
      type = types.bool;
      default = true;
      description = "Failback of both generated groups; see `proxy.groups.<name>.failback`.";
    };

    interval = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Health-check interval of both generated groups; see `proxy.groups.<name>.interval`.";
      example = "15s";
    };
  };

  config = lib.mkIf autoGroups.enable (
    lib.optionalAttrs (options ? warnings) {
      warnings = map (warning: "proxy-suite: " + warning) generated.warnings;
    }
  );
}
