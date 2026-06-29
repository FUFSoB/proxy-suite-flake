{
  lib,
  zapret,
}:

let
  trim = lib.strings.trim;
  hasPrefix = lib.strings.hasPrefix;
  hasInfix = lib.strings.hasInfix;
  splitString = lib.strings.splitString;

  zapretSrc = if builtins.isAttrs zapret && zapret ? outPath then zapret.outPath else zapret;

  parseListFile =
    path:
    lib.unique (
      builtins.filter (line: line != "" && !(hasPrefix "#" line)) (
        map trim (splitString "\n" (builtins.replaceStrings [ "\r" ] [ "" ] (builtins.readFile path)))
      )
    );

  upstreamHostlist = file: parseListFile "${zapretSrc}/hostlists/${file}";
  generalDomains = upstreamHostlist "list-general.txt";
  isDiscordDomain = domain: domain == "dis.gd" || hasInfix "discord" domain;

  domainGroups = {
    youtube = upstreamHostlist "list-google.txt";
    discord = builtins.filter isDiscordDomain generalDomains;
    other = builtins.filter (domain: !(isDiscordDomain domain)) generalDomains;
    instagram = upstreamHostlist "list-instagram.txt";
    soundcloud = upstreamHostlist "list-soundcloud.txt";
    twitter = upstreamHostlist "list-twitter.txt";
  };

  groupPresets = {
    youtube = "google";
    discord = "general";
    other = "general";
    instagram = "instagram";
    soundcloud = "soundcloud";
    twitter = "twitter";
  };

  ipGroups = {
    all = upstreamHostlist "ipset-all.txt";
  };

  expandDefaultDomains =
    groups:
    lib.unique (
      lib.concatMap (group: domainGroups.${group}) groups
    );

  expandDefaultIps =
    groups:
    lib.unique (
      lib.concatMap (group: ipGroups.${group}) groups
    );

  inferPresets =
    groups:
    lib.unique (map (group: groupPresets.${group}) groups);

  effectiveRuleDomains =
    rule:
    lib.unique (expandDefaultDomains rule.defaultDomains ++ rule.domains);

  effectiveRuleIps =
    rule:
    lib.unique (expandDefaultIps rule.defaultIps ++ rule.ips);

  effectiveRulePresets =
    rule:
    if rule.preset != null then [ rule.preset ] else inferPresets rule.defaultDomains;

  effectiveRuleIpsetFamilies =
    rule:
    lib.optional (effectiveRuleIps rule != [ ]) "all";
in
{
  inherit
    domainGroups
    groupPresets
    ipGroups
    expandDefaultDomains
    expandDefaultIps
    inferPresets
    effectiveRuleDomains
    effectiveRuleIps
    effectiveRulePresets
    effectiveRuleIpsetFamilies
    ;
}
