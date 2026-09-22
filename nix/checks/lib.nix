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
  # The module's own wiring, so a check sees exactly what a running system generates.
  mkAssembly =
    fixture:
    import ../../modules/proxy-suite/assembly.nix {
      lib = pkgs.lib;
      inherit pkgs zapret;
      cfg = fixture.config.services.proxy-suite;
      packages = import ../../pkgs/default.nix { inherit pkgs; };
    };
  mkRouting = fixture: (mkAssembly fixture).rules;
  mkRoutingRules = fixture: (mkRouting fixture).routingRules;
  mkRouteModeRules = fixture: (mkRouting fixture).routeModeRules;
  mkProxyConfig =
    fixture: configAttr:
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (
        generated.readDerivation (mkAssembly fixture).configs.${configAttr}
      )
    );
  mkTProxyConfig = fixture: mkProxyConfig fixture "tproxyFile";
  mkTunConfig = fixture: mkProxyConfig fixture "tunFile";
  mkPerAppTunConfig = fixture: mkProxyConfig fixture "perAppTunFile";
  mkInboundsConfig = fixture: mkProxyConfig fixture "proxyInboundsFile";
  mkInboundsSpec = fixture: mkProxyConfig fixture "proxyInboundsSpecFile";
  mkNftRules = fixture: attr: generated.readDerivation (mkAssembly fixture).nftr.${attr};
  mkTProxyNftRules = fixture: mkNftRules fixture "nftablesRulesFile";
  mkPerAppZapretNftRules = fixture: mkNftRules fixture "perAppZapretRulesFile";
  mkPerAppUserRules = fixture: (mkAssembly fixture).context.perAppRouting;
  # One assertion as a list element: `ok (x == y)` where the check lists want a true.
  ok =
    condition:
    assert condition;
    true;
  # A fixture from nothing but proxy-suite settings, the shape most checks want.
  mkProxySuite =
    proxySuiteConfig:
    evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = proxySuiteConfig;
      }
    ];
  # The text of the program a unit starts, without import-from-derivation.
  unitScript =
    fixture: unit:
    generated.readDerivation fixture.config.systemd.services.${unit}.serviceConfig.ExecStart;
  # The local proxy's start script, which most checks read their expectations out of.
  startScript = fixture: unitScript fixture "proxy-suite-socks";
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
  mkZapretBase = fixture: mkZapretBaseFor fixture "proxy-suite-zapret";
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
        backend = "sing-box";
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    };
  };
  # A bad fixture must fail on its own merits. Without a root file system and with a boot
  # loader, NixOS's own assertions fail every system, so any case passed as bad.
  mkBootableToplevel =
    modules:
    forceEval
      (evalProxySuite (
        [
          {
            fileSystems."/" = {
              device = "none";
              fsType = "tmpfs";
            };
            boot.loader.grub.enable = false;
          }
        ]
        ++ modules
      )).config.system.build.toplevel.drvPath;
  mkBadFixture = modules: mkBootableToplevel ([ baseModule ] ++ modules);
  mkBadFixtureRaw = mkBootableToplevel;
  mkBadProxySuiteFixture =
    proxySuiteConfig:
    mkBootableToplevel [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = proxySuiteConfig;
      }
    ];
  mkFailingAssertions =
    evaluate: cases:
    map (
      case:
      assert (evaluate case).success == false;
      true
    ) cases;
  # The messages of the assertions a config fails. Only the failing ones are forced, so an
  # unrelated module's lazily-broken message (nixpkgs has some) never gets in the way. A
  # fixture that does not evaluate at all reports that instead, so it cannot pass silently.
  failedAssertions =
    modules:
    let
      messages = map (a: a.message) (
        builtins.filter (a: !a.assertion) (evalProxySuite modules).config.assertions
      );
      forced = builtins.tryEval (builtins.deepSeq messages messages);
    in
    if forced.success then forced.value else [ "the fixture does not evaluate" ];
  # A bad config must fail *for the stated reason*: without the message, a case that stops
  # evaluating for an unrelated reason (a renamed option, say) passes while testing nothing.
  # Forcing the assertions rather than a whole system toplevel is also ~30x cheaper.
  rejectsRaw =
    expected: modules:
    let
      messages = failedAssertions modules;
    in
    if builtins.any (message: pkgs.lib.hasInfix expected message) messages then
      true
    else
      throw (
        "proxy-suite checks: expected a failure mentioning ${builtins.toJSON expected}, got: "
        + builtins.concatStringsSep " | " messages
      );
  rejects = expected: modules: rejectsRaw expected ([ baseModule ] ++ modules);
  rejectsProxySuite =
    expected: proxySuiteConfig:
    rejectsRaw expected [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = proxySuiteConfig;
      }
    ];
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
      inherit (metadata) proxychainsConfigFile wrapperEnv;
      awgProfiles = builtins.fromJSON (generated.readDerivation metadata.amneziaWgProfileNamesFile);
    };
in
{
  inherit
    rg
    evalProxySuite
    forceEval
    mkAssembly
    mkRouting
    mkRoutingRules
    mkRouteModeRules
    mkTProxyConfig
    mkTunConfig
    mkPerAppTunConfig
    mkInboundsConfig
    mkInboundsSpec
    mkTProxyNftRules
    mkNftRules
    mkPerAppZapretNftRules
    mkPerAppUserRules
    ok
    mkProxySuite
    unitScript
    startScript
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
    shellValueByPrefix
    baseModule
    mkBadFixture
    mkBadFixtureRaw
    mkBadProxySuiteFixture
    mkFailingAssertions
    failedAssertions
    rejects
    rejectsRaw
    rejectsProxySuite
    mkProxyCtlDerived
    system
    nixpkgs
    proxySuiteModule
    ;
}
