{
  lib,
  zapret,
}:

let
  trim = lib.strings.trim;
  hasPrefix = lib.strings.hasPrefix;
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

  domainGroups = {
    general = generalDomains;
    google = upstreamHostlist "list-google.txt";
    discord = generalDomains;
    youtube = upstreamHostlist "list-google.txt";
    instagram = upstreamHostlist "list-instagram.txt";
    soundcloud = upstreamHostlist "list-soundcloud.txt";
    twitter = upstreamHostlist "list-twitter.txt";
  };

  groupPresets = {
    general = "general";
    google = "google";
    discord = "general";
    youtube = "google";
    instagram = "instagram";
    soundcloud = "soundcloud";
    twitter = "twitter";
  };

  ipGroups = {
    all = upstreamHostlist "ipset-all.txt";
  };

  protocolGroups = {
    general = [ "discord-voice" ];
    discord = [ "discord-voice" ];
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

  effectiveRuleProtocolFamilies =
    rule:
    lib.optionals (rule.configName != null) (
      lib.unique (
        lib.concatMap (
          group:
          if builtins.hasAttr group protocolGroups then protocolGroups.${group} else [ ]
        ) rule.defaultDomains
      )
    );
in
{
  inherit
    domainGroups
    groupPresets
    ipGroups
    protocolGroups
    expandDefaultDomains
    expandDefaultIps
    inferPresets
    effectiveRuleDomains
    effectiveRuleIps
    effectiveRulePresets
    effectiveRuleIpsetFamilies
    effectiveRuleProtocolFamilies
    ;
}
