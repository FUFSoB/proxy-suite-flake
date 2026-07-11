# Derived zapret packages and validation.
{
  lib,
  pkgs,
  cfg,
  zapret,
}:

let
  zapretCfg = cfg.zapret;
  perAppZapretCfg = zapretCfg.perApp;
  zapretDomainGroups = import ../zapret-domain-groups.nix { inherit lib zapret; };

  runtimeDeps = lib.attrValues {
    inherit (pkgs)
      iptables
      ipset
      nftables
      coreutils
      gawk
      curl
      wget
      bash
      kmod
      findutils
      gnused
      gnugrep
      procps
      util-linux
      ;
  };

  effectiveHostlistRules = map (
    rule:
    rule
    // {
      domains = zapretDomainGroups.effectiveRuleDomains rule;
      ips = zapretDomainGroups.effectiveRuleIps rule;
      presets = zapretDomainGroups.effectiveRulePresets rule;
      ipsets = zapretDomainGroups.effectiveRuleIpsetFamilies rule;
      protocols = zapretDomainGroups.effectiveRuleProtocolFamilies rule;
    }
  ) zapretCfg.hostlistRules;
  hostlistRuleNames = map (rule: rule.name) zapretCfg.hostlistRules;

  baseZapretPackage =
    let
      upstreamPackages = zapret.packages.${pkgs.stdenv.hostPlatform.system};
    in
    if upstreamPackages ? zapret then upstreamPackages.zapret else upstreamPackages.default;

  mkOptionalHostlistFile =
    fileName: entries:
    if entries != [ ] then pkgs.writeText fileName (lib.concatStringsSep "\n" entries + "\n") else null;

  listGeneralFile = mkOptionalHostlistFile "proxy-suite-zapret-list-general-user.txt" zapretCfg.listGeneral;
  listExcludeFile = mkOptionalHostlistFile "proxy-suite-zapret-list-exclude-user.txt" zapretCfg.listExclude;
  ipsetAllFile = mkOptionalHostlistFile "proxy-suite-zapret-ipset-all.txt" zapretCfg.ipsetAll;
  ipsetExcludeFile = mkOptionalHostlistFile "proxy-suite-zapret-ipset-exclude-user.txt" zapretCfg.ipsetExclude;

  hostlistRuleSpec = pkgs.writeText "proxy-suite-zapret-hostlist-rules.json" (
    builtins.toJSON {
      includeExtraUpstreamLists = zapretCfg.includeExtraUpstreamLists;
      entries = map (rule: {
        inherit (rule)
          name
          configName
          nfqwsArgs
          ipsets
          presets
          protocols
          ;
        hasDomains = rule.domains != [ ];
        hasIps = rule.ips != [ ];
      }) effectiveHostlistRules;
    }
  );

  selectedConfigName = lib.strings.sanitizeDerivationName zapretCfg.configName;
  patchConfigScriptSrc = builtins.path {
    path = ../../../scripts/patch-zapret-config.py;
    name = "patch-zapret-config.py";
  };
  patchConfigScript = "${pkgs.python3}/bin/python3 ${patchConfigScriptSrc}";

  packageBuilder = import ./package-builder.nix {
    inherit
      lib
      pkgs
      zapretCfg
      baseZapretPackage
      effectiveHostlistRules
      listGeneralFile
      listExcludeFile
      ipsetAllFile
      ipsetExcludeFile
      hostlistRuleSpec
      patchConfigScript
      ;
  };
  inherit (packageBuilder)
    mkDerivedZapretPackage
    mkGlobalBypassScript
    ;

  globalZapretPackage = mkDerivedZapretPackage {
    packageName = "proxy-suite-zapret-${selectedConfigName}";
    pidDir = "/run/proxy-suite-zapret";
    gameFilter = zapretCfg.gameFilter;
    forceDisableFilterMark = true;
    customScript =
      if perAppZapretCfg.enable then mkGlobalBypassScript (toString perAppZapretCfg.filterMark) else null;
  };

  perAppZapretPackage = mkDerivedZapretPackage {
    packageName = "proxy-suite-per-app-zapret-${selectedConfigName}";
    pidDir = "/run/proxy-suite-per-app-zapret";
    gameFilter = "all";
    filterMark = perAppZapretCfg.filterMark;
    qnum = perAppZapretCfg.qnum;
    modeFilter = "none";
    desyncMark = 134217728;
    desyncMarkPostnat = 67108864;
    nftTable = "proxy_suite_per_app_zapret";
  };

  mkZapretEnv = package: [
    "ZAPRET_BASE=${package}/opt/zapret"
    "PATH=${lib.makeBinPath runtimeDeps}"
  ];

  assertions = [
    {
      assertion = builtins.length hostlistRuleNames == builtins.length (lib.unique hostlistRuleNames);
      message = "proxy-suite: zapret.hostlistRules names must be unique";
    }
    {
      assertion = builtins.all (
        rule:
        zapretDomainGroups.effectiveRuleDomains rule != [ ]
        || zapretDomainGroups.effectiveRuleIps rule != [ ]
      ) zapretCfg.hostlistRules;
      message = "proxy-suite: each zapret.hostlistRules entry must define domains, defaultDomains, ips, or defaultIps";
    }
    {
      assertion = builtins.all (
        rule:
        rule.preset != null
        || rule.defaultDomains != [ ]
        || rule.ips != [ ]
        || rule.defaultIps != [ ]
        || rule.nfqwsArgs != [ ]
      ) zapretCfg.hostlistRules;
      message = "proxy-suite: each zapret.hostlistRules entry must set preset, defaultDomains, ips/defaultIps, nfqwsArgs, or a valid configName source";
    }
    {
      assertion = builtins.all (
        rule:
        zapretDomainGroups.effectiveRuleDomains rule == [ ]
        || rule.preset != null
        || rule.defaultDomains != [ ]
        || rule.nfqwsArgs != [ ]
      ) zapretCfg.hostlistRules;
      message = "proxy-suite: zapret.hostlistRules entries with domains require preset, defaultDomains, or nfqwsArgs";
    }
    {
      assertion = builtins.all (
        rule: rule.preset != null || builtins.length rule.defaultDomains <= 1
      ) zapretCfg.hostlistRules;
      message = "proxy-suite: zapret.hostlistRules entries without preset may infer a rule family from only one defaultDomains entry; split groups into separate rules or set preset";
    }
    {
      assertion = builtins.all (
        rule: !(rule.configName != null && rule.nfqwsArgs != [ ])
      ) zapretCfg.hostlistRules;
      message = "proxy-suite: zapret.hostlistRules.*.configName cannot be used together with nfqwsArgs";
    }
    {
      assertion = builtins.all (
        rule:
        rule.configName == null
        || rule.preset != null
        || rule.defaultDomains != [ ]
        || rule.ips != [ ]
        || rule.defaultIps != [ ]
      ) zapretCfg.hostlistRules;
      message = "proxy-suite: zapret.hostlistRules.*.configName requires preset, defaultDomains, ips, or defaultIps";
    }
  ];
in
{
  inherit
    globalZapretPackage
    perAppZapretPackage
    ;

  globalZapretEnv = mkZapretEnv globalZapretPackage;
  perAppZapretEnv = mkZapretEnv perAppZapretPackage;

  inherit assertions;
}
