# Assembles proxy backend startup and control scripts.
{
  lib,
  pkgs,
  singBoxCfg,
  proxyCfg,
  sshProxyCfg,
  warpCfg,
  awgOutbounds,
  xrayEnabled,
  hybridEnabled,
  pureXrayEnabled,
  activeBackend,
  perAppRoutingCfg,
  userControlCfg,
  selectionMode,
  collapseNamedOutbounds,
  constants,
  zapretCutoffProxyFallback,
  jq,
  python3,
  singBox,
  xray,
  parserScriptsPythonPath,
  buildOutboundPy,
  fetchSubscriptionPy,
  tproxyFile,
  tunFile,
  perAppTunFile,
  routeModeRulesFile,
  proxyInboundsCfg,
  proxyInboundsAwg,
  awgBin,
  proxyInboundsNeedLocalProxy,
  proxyInboundsGuardPrivate,
  proxyInboundViaOutbounds,
  userControlAllows,
  buildInboundPy,
  proxyInboundsFile,
  proxyInboundsSpecFile,
  builders,
}:

let
  globalTproxy = proxyCfg.tproxy;
  backend = if activeBackend == null then "sing-box" else activeBackend;
  mainBackend = if pureXrayEnabled then "xray" else "sing-box";
  backendArg = "--backend ${mainBackend}";
  backendBin = if pureXrayEnabled then xray else singBox;
  localProxyAuth = proxyCfg.listener.auth;
  localProxyAuthEnabled =
    localProxyAuth.username != null
    && (localProxyAuth.password != null || localProxyAuth.passwordFile != null);
  localProxyAuthPasswordSource =
    if localProxyAuth.passwordFile != null then
      localProxyAuth.passwordFile
    else if localProxyAuth.password != null then
      pkgs.writeText "proxy-suite-core" localProxyAuth.password
    else
      null;
  routeModeStateFile = "${constants.runtimeDir}/proxy-suite/route-mode";
  inherit (constants)
    pinnedOutboundFile
    runtimeOutboundsDir
    runtimeSubscriptionsDir
    outboundInventoryFile
    ;
  clashApi = "http://127.0.0.1:${toString singBoxCfg.clashApiPort}";
  xrayLoglevelFile = "${constants.runtimeDir}/proxy-suite/xray-loglevel";
  runtimeProxychainsConfig = "${constants.runtimeDir}/proxy-suite-socks/proxychains.conf";
  xraySidecarRoutingMark = if constants.privileged then globalTproxy.proxyMark else null;

  routingMarkJq =
    routingMark:
    if routingMark == null then
      ""
    else if pureXrayEnabled then
      " | .streamSettings.sockopt.mark = ${toString routingMark}"
    else
      " | .routing_mark = ${toString routingMark}";

  subscriptionScripts = import ./script-blocks/subscriptions.nix {
    inherit (constants) stateDir;
    inherit
      lib
      pkgs
      proxyCfg
      hybridEnabled
      mainBackend
      backend
      runtimeSubscriptionsDir
      jq
      python3
      parserScriptsPythonPath
      fetchSubscriptionPy
      routingMarkJq
      ;
  };
  inherit (subscriptionScripts)
    subscriptionCacheDir
    subscriptionCacheHelpersBlock
    mkSubscriptionLoadHelperBlock
    mkSubscriptionBlock
    runtimeSubscriptionsBlock
    mkSubscriptionFetchBlock
    runtimeSubscriptionsFetchBlock
    subscriptionTagsFile
    ;

  outboundScripts = import ./script-blocks/outbounds.nix {
    inherit
      lib
      pkgs
      singBoxCfg
      proxyCfg
      sshProxyCfg
      warpCfg
      awgOutbounds
      constants
      pureXrayEnabled
      hybridEnabled
      collapseNamedOutbounds
      selectionMode
      backend
      backendArg
      xraySidecarRoutingMark
      pinnedOutboundFile
      runtimeOutboundsDir
      jq
      python3
      parserScriptsPythonPath
      buildOutboundPy
      mkSubscriptionBlock
      mkSubscriptionLoadHelperBlock
      runtimeSubscriptionsBlock
      ;
  };
  inherit (outboundScripts) mkOutboundScript;

  hybridRuntimeHelpersBlock = import ./script-blocks/hybrid-runtime-helpers.nix {
    inherit
      lib
      jq
      hybridEnabled
      xraySidecarRoutingMark
      ;
  };

  backendJqFilter = import ./script-blocks/backend-jq-filter.nix {
    inherit
      lib
      pureXrayEnabled
      selectionMode
      proxyInboundsGuardPrivate
      ;
    userDnsRules = proxyCfg.dns.singBox.rules;
  };
  backendJqFilterFile = pkgs.writeText "proxy-suite-core" backendJqFilter;

  startScripts = import ./start-scripts.nix {
    inherit
      lib
      pkgs
      proxyCfg
      perAppRoutingCfg
      userControlCfg
      userControlAllows
      globalTproxy
      xrayEnabled
      hybridEnabled
      pureXrayEnabled
      constants
      zapretCutoffProxyFallback
      jq
      singBox
      xray
      backendBin
      routeModeStateFile
      routeModeRulesFile
      xrayLoglevelFile
      runtimeProxychainsConfig
      localProxyAuth
      localProxyAuthEnabled
      localProxyAuthPasswordSource
      backendJqFilterFile
      hybridRuntimeHelpersBlock
      subscriptionCacheHelpersBlock
      mkOutboundScript
      tproxyFile
      tunFile
      perAppTunFile
      ;
  };
  inherit (startScripts) startSocks startTun startPerAppTun;

  proxyInboundsScripts = import ./proxy-inbounds-scripts.nix {
    inherit
      lib
      pkgs
      proxyCfg
      proxyInboundsCfg
      proxyInboundsAwg
      awgBin
      proxyInboundsNeedLocalProxy
      proxyInboundViaOutbounds
      userControlCfg
      userControlAllows
      localProxyAuth
      localProxyAuthEnabled
      localProxyAuthPasswordSource
      jq
      python3
      parserScriptsPythonPath
      buildInboundPy
      buildOutboundPy
      proxyInboundsFile
      proxyInboundsSpecFile
      builders
      constants
      ;
  };
  inherit (proxyInboundsScripts) startInbounds collectInboundStats;
  proxyInboundsLinksFile = proxyInboundsScripts.linksFile;
  proxyInboundsSubscriptionsFile = proxyInboundsScripts.subscriptionsFile;

  controlScripts = import ./control-scripts.nix {
    inherit (constants) systemctl;
    inherit
      lib
      pkgs
      proxyCfg
      clashApi
      routeModeStateFile
      pinnedOutboundFile
      outboundInventoryFile
      runtimeOutboundsDir
      subscriptionCacheDir
      subscriptionCacheHelpersBlock
      mkSubscriptionFetchBlock
      runtimeSubscriptionsFetchBlock
      jq
      ;
  };
  inherit (controlScripts)
    subscriptionUpdateScript
    setRouteModeScript
    pinOutboundScript
    reloadOutboundsScript
    ;

in
{
  inherit
    startSocks
    startTun
    startPerAppTun
    startInbounds
    collectInboundStats
    ;
  inherit
    proxyInboundsLinksFile
    proxyInboundsSubscriptionsFile
    routeModeStateFile
    setRouteModeScript
    pinOutboundScript
    reloadOutboundsScript
    subscriptionUpdateScript
    subscriptionTagsFile
    subscriptionCacheDir
    runtimeProxychainsConfig
    pinnedOutboundFile
    runtimeOutboundsDir
    runtimeSubscriptionsDir
    outboundInventoryFile
    clashApi
    ;
}
