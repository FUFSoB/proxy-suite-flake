# Auto-groups: HOME and WHITELIST generated for subscription entries.
#
# A subscription entry's outbound tag is "<subscription tag>-<slugified remark>" (see
# scripts/proxy_parsing.py). slugify keeps Unicode word characters and "-", and turns every other
# separator into "-", so a subscription tag separates its tokens with "-" or "_" only.
#
# The group engine (modules/proxy-suite/outbound-groups.jq) matches tags with a glob of "*" and
# "?" only, case-sensitively. This file therefore emits every ASCII case variant of a whitelist
# token, at every separator position a subscription tag can use. It is the build-time half: the
# match list is recomputed on every rebuild from the declared subscription tags, and resolved
# against the tags a subscription actually holds at start.
#
# Limits (see docs/autogroups-draft.md):
# - globs cannot express a character class, so generated patterns cover "-" and "_" only;
#   a tag with ".", " ", "/" or "|" as a token separator needs extraWhitelistGlobs;
# - Nix has no NFKC nor general Unicode case folding, so only ASCII tokens (and their VS16
#   variants) are case-insensitive; non-ASCII spellings need exact case or the runtime stage;
# - globs have no negation, so a whitelist entry cannot be kept out of the home group here.
{ lib }:
let
  inherit (builtins)
    concatMap
    filter
    foldl'
    isAttrs
    isString
    replaceStrings
    split
    substring
    ;
  inherit (lib)
    any
    attrNames
    elem
    filterAttrs
    hasAttr
    optional
    stringToCharacters
    unique
    ;

  defaults = {
    enable = false;
    homeGroupName = "home";
    whitelistGroupName = "whitelist";
    whitelistTokens = [
      "WL"
      "WLTE"
      "LTE"
      "🏳️"
    ];
    extraWhitelistGlobs = [ ];
    extraHomeGlobs = [ ];
    strategy = "failover";
    failback = true;
    interval = null;
  };

  # Tokens separated by "-", "_", " ", ".", "|", "/" or whitespace. Nix's regex engine is
  # byte-oriented, so [:space:] is the ASCII set; NFKC and Unicode whitespace are the runtime
  # stage's job.
  tokenize = tag: filter isString (split "[-_ .|/[:space:]]+" tag);

  # ASCII-only, as lib.toLower is: the build-time half cannot fold Unicode.
  foldCase = lib.toLower;

  # "🏳️" (U+1F3F3 U+FE0F) and "🏳" (U+1F3F3) are the same flag in most fonts and tags.
  # Nix has no escape for U+FE0F, so take the selector from the flag: 4-byte U+1F3F3, then it.
  vs16 = substring 4 3 "🏳️";
  stripVs16 = s: replaceStrings [ vs16 ] [ "" ] s;

  # Every ASCII case permutation. Byte-wise iteration is safe: non-ASCII bytes compare equal
  # under toLower/toUpper and are appended back unchanged.
  caseVariants =
    token:
    foldl' (
      acc: ch:
      let
        lower = lib.toLower ch;
        upper = lib.toUpper ch;
      in
      if lower == upper then
        map (v: v + ch) acc
      else
        concatMap (v: [
          (v + lower)
          (v + upper)
        ]) acc
    ) [ "" ] (stringToCharacters token);

  tokenVariants = token: unique (caseVariants token ++ map stripVs16 (caseVariants token));

  # Glob contexts a token can sit in inside "<sub>-<slug>": whole slug, start, end, middle.
  # The glob language has no character class, so "-" and "_" are separate patterns.
  separators = [
    "-"
    "_"
  ];
  tokenGlobs =
    prefix: token:
    concatMap (
      variant:
      let
        atStart = "${prefix}${variant}";
      in
      [ atStart ]
      ++ concatMap (separator: [ "${atStart}${separator}*" ]) separators
      ++ concatMap (separator: [ "${prefix}*${separator}${variant}" ]) separators
      ++ concatMap (separator: [
        "${prefix}*${separator}${variant}${separator}*"
      ]) separators
    ) (tokenVariants token);

  foldedTokens = cfg: map (token: foldCase (stripVs16 token)) cfg.whitelistTokens;
  foldedTagTokens = tag: map (token: foldCase (stripVs16 token)) (tokenize tag);

  # Token-boundary matching, not substring: "LTE" is whitelist, "complete" and "welt" are not.
  isWhitelist = cfg: tag: any (wanted: elem wanted (foldedTagTokens tag)) (foldedTokens cfg);

  classifyTag = cfg: tag: if isWhitelist cfg tag then "whitelist" else "home";

  # Build the two group definitions. Manual groups win by name: a generated group that already
  # exists is skipped, and manual membership is never rewritten.
  mkAutoGroups =
    {
      config,
      subscriptions,
      groups ? { },
    }:
    let
      cfg = defaults // config;
      subTags = map (sub: if isAttrs sub then sub.tag else sub) subscriptions;
      whitelistMatch = unique (
        concatMap (sub: concatMap (token: tokenGlobs "${sub}-" token) cfg.whitelistTokens) subTags
        ++ cfg.extraWhitelistGlobs
      );
      common = {
        inherit (cfg) strategy failback interval;
      };
      homeGroup = common // {
        subscriptions = subTags;
        match = cfg.extraHomeGlobs;
      };
      whitelistGroup = common // {
        subscriptions = [ ];
        match = whitelistMatch;
      };
      auto =
        if cfg.homeGroupName == cfg.whitelistGroupName then
          { ${cfg.whitelistGroupName} = whitelistGroup; }
        else
          {
            ${cfg.homeGroupName} = homeGroup;
            ${cfg.whitelistGroupName} = whitelistGroup;
          };
      kept = filterAttrs (name: _: !(hasAttr name groups)) auto;
      warnings =
        optional (cfg.enable && cfg.homeGroupName == cfg.whitelistGroupName)
          "autoGroups: homeGroupName and whitelistGroupName are both \"${cfg.homeGroupName}\"; only the whitelist group is kept"
        ++
          optional (cfg.enable && whitelistMatch == [ ])
            "autoGroups: no subscription and no extraWhitelistGlobs yield a whitelist match; the whitelist group has no member"
        ++
          optional (cfg.enable && subTags == [ ] && cfg.extraHomeGlobs == [ ])
            "autoGroups: no subscription and no extraHomeGlobs yield a home match; the home group has no member";
    in
    {
      groups = if cfg.enable then kept else { };
      generated = if cfg.enable then auto else { };
      skipped = if cfg.enable then filter (name: hasAttr name groups) (attrNames auto) else [ ];
      inherit warnings;
    };
in
{
  inherit
    classifyTag
    defaults
    isWhitelist
    mkAutoGroups
    tokenize
    ;
}
