{
  pkgs,
  system,
  nixpkgs,
  proxySuiteModule,
  zapret,
}:

let
  generated = import ./read-generated.nix;

  evalProxySuite =
    modules:
    import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [ proxySuiteModule ] ++ modules;
    };
  forceEval = value: builtins.tryEval (builtins.deepSeq value true);
  rg = "${pkgs.ripgrep}/bin/rg";
  mkRouting =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
    in
    import ../../modules/proxy-suite/rules.nix {
      lib = pkgs.lib;
      inherit pkgs cfg zapret;
    };
  mkRoutingRules = fixture: (mkRouting fixture).routingRules;
  mkRouteModeRules = fixture: (mkRouting fixture).routeModeRules;
  mkProxyConfig =
    fixture: configAttr:
    let
      cfg = fixture.config.services.proxy-suite;
      rules = mkRouting fixture;
      configs = import ../../modules/proxy-suite/config.nix {
        lib = pkgs.lib;
        inherit pkgs cfg rules;
      };
    in
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (generated.readDerivation configs.${configAttr})
    );
  mkTProxyConfig = fixture: mkProxyConfig fixture "tproxyFile";
  mkTunConfig = fixture: mkProxyConfig fixture "tunFile";
  mkPerAppTunConfig = fixture: mkProxyConfig fixture "perAppTunFile";
  mkTProxyNftRules =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
      nftr = import ../../modules/proxy-suite/nftables.nix {
        lib = pkgs.lib;
        inherit pkgs cfg;
      };
    in
    generated.readDerivation nftr.nftablesRulesFile;
  mkPerAppZapretNftRules =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
      nftr = import ../../modules/proxy-suite/nftables.nix {
        lib = pkgs.lib;
        inherit pkgs cfg;
      };
    in
    generated.readDerivation nftr.perAppZapretRulesFile;
  mkPerAppUserRules =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
      derived = import ../../modules/proxy-suite/derived.nix {
        lib = pkgs.lib;
        inherit cfg;
      };
      nftr = import ../../modules/proxy-suite/nftables.nix {
        lib = pkgs.lib;
        inherit pkgs cfg;
      };
    in
    import ../../modules/proxy-suite/service/per-app-routing/user-rules.nix {
      lib = pkgs.lib;
      inherit pkgs;
      inherit (derived)
        perAppRoutingTun
        perAppRoutingTproxy
        perAppZapretCfg
        ;
      perAppTunSliceName = "proxy-suite-per-app-tun.slice";
      perAppTproxySliceName = "proxy-suite-per-app-tproxy.slice";
      perAppZapretSliceName = "proxy-suite-per-app-zapret.slice";
      inherit (nftr) nft;
      awk = "${pkgs.gawk}/bin/awk";
      grepBin = "${pkgs.gnugrep}/bin/grep";
      findBin = "${pkgs.findutils}/bin/find";
      headBin = "${pkgs.coreutils}/bin/head";
    };
  hasDirectDomain =
    rules: domain:
    builtins.any (
      rule: (rule ? domain_suffix) && rule.outbound == "direct" && builtins.elem domain rule.domain_suffix
    ) rules;
  hasDirectIP =
    rules: cidr:
    builtins.any (
      rule: (rule ? ip_cidr) && rule.outbound == "direct" && builtins.elem cidr rule.ip_cidr
    ) rules;
  hasRuleSet =
    rules: outbound: ruleSet:
    builtins.any (
      rule: (rule ? rule_set) && rule.outbound == outbound && builtins.elem ruleSet rule.rule_set
    ) rules;
  dnsHasRuleSet =
    dnsRules: ruleSet:
    builtins.any (rule: (rule ? rule_set) && builtins.elem ruleSet rule.rule_set) dnsRules;
  dnsServerByTag =
    dnsConfig: tag: builtins.head (builtins.filter (server: server.tag == tag) dnsConfig.dns.servers);
  mkZapretBaseFor =
    fixture: serviceName:
    let
      env = fixture.config.systemd.services.${serviceName}.serviceConfig.Environment;
      zapretBaseEnv = builtins.head (
        builtins.filter (value: pkgs.lib.hasPrefix "ZAPRET_BASE=" value) env
      );
    in
    pkgs.lib.removePrefix "ZAPRET_BASE=" zapretBaseEnv;
  mkZapretBase = fixture: mkZapretBaseFor fixture "zapret-discord-youtube";
  packagePathMatches =
    packages: pattern:
    builtins.any (
      pkg: builtins.match pattern (builtins.unsafeDiscardStringContext (toString pkg)) != null
    ) packages;
  packageByPattern =
    packages: pattern:
    builtins.head (
      builtins.filter (
        pkg: builtins.match pattern (builtins.unsafeDiscardStringContext (toString pkg)) != null
      ) packages
    );
  lineByPrefix =
    text: prefix:
    builtins.head (
      builtins.filter (line: pkgs.lib.hasPrefix prefix line) (pkgs.lib.splitString "\n" text)
    );
  lineContaining =
    text: infix:
    builtins.head (
      builtins.filter (line: pkgs.lib.hasInfix infix line) (pkgs.lib.splitString "\n" text)
    );
  shellValueByPrefix =
    text: prefix:
    let
      value = pkgs.lib.removePrefix prefix (lineByPrefix text prefix);
    in
    if pkgs.lib.hasPrefix "'" value && pkgs.lib.hasSuffix "'" value then
      pkgs.lib.removeSuffix "'" (pkgs.lib.removePrefix "'" value)
    else if pkgs.lib.hasPrefix "\"" value && pkgs.lib.hasSuffix "\"" value then
      pkgs.lib.removeSuffix "\"" (pkgs.lib.removePrefix "\"" value)
    else
      value;

  baseModule = {
    system.stateVersion = "26.05";
    services.proxy-suite = {
      enable = true;
      proxy = {
        enable = true;
        singBox.enable = true;
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    };
  };
  mkFixture =
    proxySuiteConfig:
    evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = proxySuiteConfig;
      }
    ];
  mkBadFixture =
    modules:
    forceEval ((evalProxySuite ([ baseModule ] ++ modules)).config.system.build.toplevel.drvPath);
  mkBadFixtureRaw =
    modules: forceEval ((evalProxySuite modules).config.system.build.toplevel.drvPath);
  mkBadProxySuiteFixture =
    proxySuiteConfig: forceEval ((mkFixture proxySuiteConfig).config.system.build.toplevel.drvPath);
  mkFailingAssertions =
    evaluate: cases:
    map (
      case:
      assert (evaluate case).success == false;
      true
    ) cases;
  mkProxyCtlDerived =
    fixture:
    let
      proxyCtl = packageByPattern fixture.config.environment.systemPackages ".*/[^/]*proxy-ctl(-[0-9.]+)?$";
      metadata = proxyCtl.proxySuiteCheck;
      wrapper = pkgs.lib.concatStringsSep "\n" (
        pkgs.lib.mapAttrsToList (
          name: value: "export ${name}=${pkgs.lib.escapeShellArg value}"
        ) metadata.wrapperEnv
      );
    in
    {
      inherit proxyCtl wrapper;
      script = wrapper + "\n" + metadata.script;
      profiles = builtins.fromJSON (generated.readDerivation metadata.perAppRoutingProfilesFile);
      subscriptionTags = builtins.fromJSON (generated.readDerivation metadata.subscriptionTagsFile);
      inherit (metadata) proxychainsConfigFile;
    };
in
{
  inherit
    rg
    evalProxySuite
    forceEval
    mkRouting
    mkRoutingRules
    mkRouteModeRules
    mkTProxyConfig
    mkTunConfig
    mkPerAppTunConfig
    mkTProxyNftRules
    mkPerAppZapretNftRules
    mkPerAppUserRules
    hasDirectDomain
    hasDirectIP
    hasRuleSet
    dnsHasRuleSet
    dnsServerByTag
    mkZapretBaseFor
    mkZapretBase
    packagePathMatches
    packageByPattern
    lineByPrefix
    lineContaining
    shellValueByPrefix
    baseModule
    mkFixture
    mkBadFixture
    mkBadFixtureRaw
    mkBadProxySuiteFixture
    mkFailingAssertions
    mkProxyCtlDerived
    ;
}
