# Assembles proxy backend startup and control scripts.
{ ctx }:

let
  inherit (ctx)
    lib
    pkgs
    singBoxCfg
    proxyCfg
    activeBackend
    xrayEnabled
    hybridEnabled
    pureXrayEnabled
    perAppRoutingCfg
    userControlCfg
    userControlAllows
    selectionMode
    constants
    zapretCutoffProxyFallback
    jq
    python3
    singBox
    xray
    proxyInboundsCfg
    proxyInboundsGuardPrivate
    routeModeRulesFile
    tproxyFile
    tunFile
    perAppTunFile
    proxyInboundsFile
    proxyInboundsSpecFile
    builders
    ;
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

  # ctx plus this layer's own values; the script blocks read what they need off it. Lazy, so
  # a block may use a sibling's output (start-scripts uses the subscription helpers).
  sctx = ctx // {
    inherit
      backend
      mainBackend
      backendArg
      backendBin
      globalTproxy
      localProxyAuth
      localProxyAuthEnabled
      localProxyAuthPasswordSource
      routeModeStateFile
      xrayLoglevelFile
      runtimeProxychainsConfig
      xraySidecarRoutingMark
      routingMarkJq
      pinnedOutboundFile
      runtimeOutboundsDir
      runtimeSubscriptionsDir
      outboundInventoryFile
      clashApi
      ;
    inherit (subscriptionScripts)
      subscriptionCacheDir
      subscriptionCacheHelpersBlock
      mkSubscriptionLoadHelperBlock
      mkSubscriptionBlock
      runtimeSubscriptionsBlock
      mkSubscriptionFetchBlock
      runtimeSubscriptionsFetchBlock
      ;
    inherit (outboundScripts) mkOutboundScript;
    inherit hybridRuntimeHelpersBlock backendJqFilterFile;
  };

  subscriptionScripts = import ./script-blocks/subscriptions.nix { ctx = sctx; };
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
    inherit (sctx)
      lib
      pkgs
      singBoxCfg
      proxyCfg
      sshProxyCfg
      warpCfg
      torCfg
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

  hybridRuntimeHelpersBlock = import ./script-blocks/hybrid-runtime-helpers.nix { ctx = sctx; };

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

  startScripts = import ./start-scripts.nix { ctx = sctx; };
  inherit (startScripts) startSocks startTun startPerAppTun;

  proxyInboundsScripts = import ./proxy-inbounds-scripts.nix { ctx = sctx; };
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
    ;
}
