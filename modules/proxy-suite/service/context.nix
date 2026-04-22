# Shared service-layer assembly used by runtime module and docs generation.
{
  lib,
  pkgs,
  packages,
  cfg,
  tproxyFile,
  tunFile,
  perAppTunFile,
  perAppTunChainFile,
  perAppTproxyRulesFile,
  perAppZapretRulesFile,
  ip,
  nft,
}:

let
  derived = import ../derived.nix { inherit lib cfg; };
  inherit (derived)
    singBoxCfg
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    userControlCfg
    selectionMode
    builtinTags
    outboundTags
    subscriptionTags
    invalidRoutingTargets
    collapseNamedOutbounds
    hasSubscriptions
    ;

  # Tool paths – defined once here and passed into sub-modules as needed.
  jq = "${pkgs.jq}/bin/jq";
  python3 = "${pkgs.python3}/bin/python3";
  singBox = "${pkgs.sing-box}/bin/sing-box";
  grepBin = "${pkgs.gnugrep}/bin/grep";
  awk = "${pkgs.gawk}/bin/awk";
  sleepBin = "${pkgs.coreutils}/bin/sleep";
  headBin = "${pkgs.coreutils}/bin/head";
  seqBin = "${pkgs.coreutils}/bin/seq";
  findBin = "${pkgs.findutils}/bin/find";

  proxySuiteScriptsDir = ../../../scripts;
  parserScriptsPythonPath = proxySuiteScriptsDir;
  buildOutboundPy = "${proxySuiteScriptsDir}/build-outbound.py";
  fetchSubscriptionPy = "${proxySuiteScriptsDir}/fetch-subscription.py";

  polkit = import ./polkit.nix {
    inherit lib cfg userControlCfg;
  };

  scripts = import ./scripts.nix {
    inherit
      lib
      pkgs
      singBoxCfg
      perAppRoutingCfg
      userControlCfg
      perAppRoutingTun
      selectionMode
      collapseNamedOutbounds
      hasSubscriptions
      ;
    inherit
      jq
      python3
      singBox
      parserScriptsPythonPath
      buildOutboundPy
      fetchSubscriptionPy
      ;
    inherit tproxyFile tunFile perAppTunFile;
  };

  perAppRouting = import ./per-app-routing.nix {
    inherit
      lib
      pkgs
      cfg
      singBoxCfg
      perAppRoutingCfg
      perAppRoutingTun
      perAppRoutingTproxy
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
      perAppRoutingCfg
      perAppRoutingTun
      perAppRoutingTproxy
      perAppZapretCfg
      selectionMode
      ;
    zapretEnabled = cfg.zapret.enable;
    inherit (scripts) subscriptionTagsFile;
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
    ;
}
