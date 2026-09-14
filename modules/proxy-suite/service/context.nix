# Shared service-layer assembly used by runtime module and docs generation.
{
  lib,
  pkgs,
  packages,
  cfg,
  tproxyFile,
  tunFile,
  perAppTunFile,
  routeModeRulesFile,
  proxyInboundsFile,
  proxyInboundsSpecFile,
  perAppTunChainFile,
  perAppTproxyRulesFile,
  perAppZapretRulesFile,
  ip,
  nft,
}:

let
  derived = import ../derived.nix { inherit lib cfg; };
  constants = derived.constants;
  inherit (derived)
    singBoxCfg
    proxyCfg
    xrayCfg
    proxyEnabled
    singBoxEnabled
    xrayEnabled
    hybridEnabled
    pureXrayEnabled
    activeBackend
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    zapretEngine
    zapretCutoffEnabled
    zapretCutoffProxyFallback
    userControlCfg
    selectionMode
    builtinTags
    outboundTags
    subscriptionTags
    invalidRoutingTargets
    collapseNamedOutbounds
    sshProxyCfg
    sshProxyOutboundEnabled
    sshProxyUnitEnabled
    warpCfg
    proxyInboundsCfg
    proxyInboundsEnabled
    proxyInboundsNeedLocalProxy
    proxyInboundsGuardPrivate
    proxyInboundViaOutbounds
    userControlEnabled
    ;

  # Tool paths – defined once here and passed into sub-modules as needed.
  jq = "${pkgs.jq}/bin/jq";
  python3 = "${pkgs.python3}/bin/python3";
  singBox = "${singBoxCfg.package}/bin/sing-box";
  xray = "${xrayCfg.package}/bin/xray";
  grepBin = "${pkgs.gnugrep}/bin/grep";
  awk = "${pkgs.gawk}/bin/awk";
  sleepBin = "${pkgs.coreutils}/bin/sleep";
  headBin = "${pkgs.coreutils}/bin/head";
  seqBin = "${pkgs.coreutils}/bin/seq";
  findBin = "${pkgs.findutils}/bin/find";
  amneziaWgProfileNamesFile = pkgs.writeText "proxy-suite-awg-profiles.json" (
    builtins.toJSON (builtins.attrNames cfg.amneziaWg.profiles)
  );

  proxySuiteScriptsDir = ../../../scripts;
  parserScriptsPythonPath = proxySuiteScriptsDir;
  buildOutboundPy = "${proxySuiteScriptsDir}/build-outbound.py";
  buildInboundPy = "${proxySuiteScriptsDir}/build-inbound.py";
  fetchSubscriptionPy = "${proxySuiteScriptsDir}/fetch-subscription.py";

  builders = import ./builders.nix { inherit lib pkgs; };

  polkit = import ./polkit.nix {
    inherit lib cfg userControlCfg;
  };

  scripts = import ./scripts.nix {
    inherit
      lib
      pkgs
      singBoxCfg
      proxyCfg
      sshProxyCfg
      warpCfg
      xrayEnabled
      hybridEnabled
      pureXrayEnabled
      activeBackend
      perAppRoutingCfg
      userControlCfg
      selectionMode
      collapseNamedOutbounds
      constants
      zapretCutoffProxyFallback
      ;
    inherit
      jq
      python3
      singBox
      xray
      parserScriptsPythonPath
      buildOutboundPy
      buildInboundPy
      fetchSubscriptionPy
      ;
    inherit
      tproxyFile
      tunFile
      perAppTunFile
      routeModeRulesFile
      proxyInboundsFile
      proxyInboundsSpecFile
      ;
    inherit
      proxyInboundsCfg
      proxyInboundsNeedLocalProxy
      proxyInboundsGuardPrivate
      proxyInboundViaOutbounds
      userControlEnabled
      builders
      ;
  };

  perAppRouting = import ./per-app-routing.nix {
    inherit
      lib
      pkgs
      cfg
      singBoxCfg
      proxyCfg
      pureXrayEnabled
      perAppRoutingCfg
      perAppRoutingTun
      perAppRoutingTproxy
      constants
      ;
    perAppZapretCfg = perAppZapretCfg;
    inherit perAppTunChainFile perAppTproxyRulesFile perAppZapretRulesFile;
    inherit ip nft;
    inherit
      awk
      grepBin
      findBin
      headBin
      seqBin
      sleepBin
      ;
  };

  control = import ./control.nix {
    inherit
      packages
      singBoxCfg
      proxyCfg
      perAppRoutingCfg
      perAppRoutingTun
      perAppRoutingTproxy
      perAppZapretCfg
      zapretEngine
      zapretCutoffEnabled
      constants
      selectionMode
      userControlCfg
      ;
    inherit (scripts) subscriptionTagsFile subscriptionCacheDir;
    inherit (scripts) routeModeStateFile;
    inherit proxyInboundsEnabled;
    inherit (scripts) proxyInboundsLinksFile proxyInboundsSubscriptionsFile;
    proxyInboundsSubscriptionsBaseUrl = proxyInboundsCfg.subscriptions.baseUrl;
    inherit amneziaWgProfileNamesFile;
    inherit (perAppRouting)
      perAppRoutingProfilesFile
      proxychainsConfigFile
      proxychainsQuietArg
      ;
  };
in
{
  inherit
    derived
    singBoxCfg
    proxyCfg
    xrayCfg
    proxyEnabled
    singBoxEnabled
    xrayEnabled
    hybridEnabled
    pureXrayEnabled
    activeBackend
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    userControlCfg
    builtinTags
    outboundTags
    subscriptionTags
    invalidRoutingTargets
    polkit
    scripts
    perAppRouting
    control
    amneziaWgProfileNamesFile
    ;
}
