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
  nftablesRulesFile,
  ip,
  nft,
}:

let
  derived = import ../derived.nix { inherit lib cfg; };
  # Only what this file itself needs; the rest reaches the sub-modules through ctx.
  inherit (derived) singBoxCfg xrayCfg userControlCfg;

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
  awgBin = "${cfg.amneziaWg.toolsPackage}/bin/awg";
  # `proxy-ctl awg` toggles global profiles; outbound ones always run and show up with the proxy.
  amneziaWgProfileNamesFile = pkgs.writeText "proxy-suite-core" (
    builtins.toJSON (
      builtins.attrNames (lib.filterAttrs (_: profile: profile.asOutbound == null) cfg.amneziaWg.profiles)
    )
  );

  proxySuiteScriptsDir = import ../lib/scripts-dir.nix { inherit lib; };
  parserScriptsPythonPath = proxySuiteScriptsDir;
  buildOutboundPy = "${proxySuiteScriptsDir}/build-outbound.py";
  buildInboundPy = "${proxySuiteScriptsDir}/build-inbound.py";
  fetchSubscriptionPy = "${proxySuiteScriptsDir}/fetch-subscription.py";

  builders = import ./builders.nix { inherit lib pkgs; };

  polkit = import ./polkit.nix { inherit userControlCfg; };

  # One context for the service layer: everything derived.nix computes, the tool paths and
  # generated files above, and the shell-snippet builders. Sub-modules take it whole and
  # `inherit` the names they use, so adding a value needs no plumbing in between.
  ctx = derived // {
    inherit
      lib
      pkgs
      packages
      cfg
      builders
      polkit
      ;
    inherit
      jq
      python3
      singBox
      xray
      grepBin
      awk
      sleepBin
      headBin
      seqBin
      findBin
      awgBin
      ;
    inherit
      proxySuiteScriptsDir
      parserScriptsPythonPath
      buildOutboundPy
      buildInboundPy
      fetchSubscriptionPy
      amneziaWgProfileNamesFile
      ;
    inherit
      tproxyFile
      tunFile
      perAppTunFile
      routeModeRulesFile
      proxyInboundsFile
      proxyInboundsSpecFile
      perAppTunChainFile
      perAppTproxyRulesFile
      perAppZapretRulesFile
      nftablesRulesFile
      ip
      nft
      ;
    # Filled in below; lazily, so the sub-modules can read each other's results.
    inherit scripts perAppRouting;
  };

  scripts = import ./scripts.nix { inherit ctx; };
  perAppRouting = import ./per-app-routing.nix { inherit ctx; };
  control = import ./control.nix { inherit ctx; };
in
{
  inherit
    ctx
    derived
    polkit
    scripts
    perAppRouting
    control
    ;
}
