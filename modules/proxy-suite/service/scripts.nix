# Assembles proxy backend startup and control scripts.
{
  lib,
  pkgs,
  singBoxCfg,
  proxyCfg,
  sshProxyCfg,
  xrayEnabled,
  hybridEnabled,
  pureXrayEnabled,
  activeBackend,
  perAppRoutingCfg,
  userControlCfg,
  selectionMode,
  collapseNamedOutbounds,
  hasSubscriptions,
  constants,
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
  proxyInboundsNeedLocalProxy,
  proxyInboundViaOutbounds,
  userControlEnabled,
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
  localProxyAuth = proxyCfg.auth;
  localProxyAuthEnabled =
    localProxyAuth.username != null
    && (localProxyAuth.password != null || localProxyAuth.passwordFile != null);
  localProxyAuthPasswordSource =
    if localProxyAuth.passwordFile != null then
      localProxyAuth.passwordFile
    else if localProxyAuth.password != null then
      pkgs.writeText "proxy-suite-local-proxy-password" localProxyAuth.password
    else
      null;
  routeModeStateFile = "/run/proxy-suite/route-mode";
  xrayLoglevelFile = "/run/proxy-suite/xray-loglevel";
  runtimeProxychainsConfig = "/run/proxy-suite-socks/proxychains.conf";
  xraySidecarRoutingMark = globalTproxy.proxyMark;

  routingMarkJq =
    routingMark:
    if routingMark == null then
      ""
    else if pureXrayEnabled then
      " | .streamSettings.sockopt.mark = ${toString routingMark}"
    else
      " | .routing_mark = ${toString routingMark}";

  subscriptionScripts = import ./script-blocks/subscriptions.nix {
    inherit
      lib
      pkgs
      proxyCfg
      hasSubscriptions
      hybridEnabled
      mainBackend
      backend
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
    mkSubscriptionBlock
    mkSubscriptionFetchBlock
    subscriptionTagsFile
    ;

  outboundScripts = import ./script-blocks/outbounds.nix {
    inherit
      lib
      pkgs
      singBoxCfg
      proxyCfg
      sshProxyCfg
      pureXrayEnabled
      hybridEnabled
      collapseNamedOutbounds
      selectionMode
      backend
      backendArg
      xraySidecarRoutingMark
      jq
      python3
      parserScriptsPythonPath
      buildOutboundPy
      mkSubscriptionBlock
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
      pureXrayEnabled
      selectionMode
      ;
  };
  backendJqFilterFile = pkgs.writeText "proxy-suite-${backend}-backend-filter.jq" backendJqFilter;

  startScripts = import ./start-scripts.nix {
    inherit
      lib
      pkgs
      proxyCfg
      perAppRoutingCfg
      userControlCfg
      globalTproxy
      xrayEnabled
      hybridEnabled
      pureXrayEnabled
      constants
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
      proxyInboundsNeedLocalProxy
      proxyInboundViaOutbounds
      userControlCfg
      userControlEnabled
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
      ;
  };
  inherit (proxyInboundsScripts) startInbounds;
  proxyInboundsLinksFile = proxyInboundsScripts.linksFile;

  controlScripts = import ./control-scripts.nix {
    inherit
      lib
      pkgs
      proxyCfg
      routeModeStateFile
      subscriptionCacheDir
      subscriptionCacheHelpersBlock
      mkSubscriptionFetchBlock
      ;
  };
  inherit (controlScripts)
    subscriptionUpdateScript
    setRouteModeScript
    ;

in
{
  inherit startSocks startTun startPerAppTun startInbounds;
  inherit
    proxyInboundsLinksFile
    routeModeStateFile
    setRouteModeScript
    subscriptionUpdateScript
    hasSubscriptions
    subscriptionTagsFile
    subscriptionCacheDir
    runtimeProxychainsConfig
    ;
}
