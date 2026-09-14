# Builds proxy-ctl from global proxy-suite state and per-app routing metadata.
{
  packages,
  singBoxCfg,
  proxyCfg,
  perAppRoutingCfg,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretCfg,
  zapretEngine,
  zapretCutoffEnabled,
  constants,
  selectionMode,
  userControlCfg,
  subscriptionTagsFile,
  subscriptionCacheDir,
  perAppRoutingProfilesFile,
  proxychainsConfigFile,
  proxychainsQuietArg,
  routeModeStateFile,
  amneziaWgProfileNamesFile,
  proxyInboundsEnabled,
  proxyInboundsLinksFile,
  proxyInboundsSubscriptionsFile,
  proxyInboundsSubscriptionsBaseUrl,
}:
{
  proxyCtl = packages.mkProxyCtl {
    clashApi = "http://127.0.0.1:${toString singBoxCfg.clashApiPort}";
    selection = selectionMode;
    inherit
      subscriptionTagsFile
      subscriptionCacheDir
      perAppRoutingProfilesFile
      proxychainsConfigFile
      proxychainsQuietArg
      routeModeStateFile
      amneziaWgProfileNamesFile
      ;
    defaultRouteMode = if (proxyCfg.routing.default == "proxy") then "blacklist" else "whitelist";
    perAppRoutingEnabled = if perAppRoutingCfg.enable then "1" else "0";
    perAppRoutingProxychainsEnabled = if perAppRoutingCfg.proxychains.enable then "1" else "0";
    perAppRoutingTunEnabled = if perAppRoutingTun.enable then "1" else "0";
    perAppRoutingTproxyEnabled = if perAppRoutingTproxy.enable then "1" else "0";
    perAppRoutingZapretEnabled = if perAppZapretCfg.enable then "1" else "0";
    zapretAutoEnabled = if zapretEngine == "zapret2" then "1" else "0";
    zapretStateDir = constants.zapret2StateDir;
    zapretCutoffEnabled = if zapretCutoffEnabled then "1" else "0";
    outboundInventoryFile = constants.outboundInventoryFile;
    runtimeOutboundsDir = constants.runtimeOutboundsDir;
    runtimeSubscriptionsDir = constants.runtimeSubscriptionsDir;
    userControlGroup = userControlCfg.group;
    inboundsEnabled = if proxyInboundsEnabled then "1" else "0";
    inboundsLinksFile = proxyInboundsLinksFile;
    inboundsStatsFile = constants.inboundStatsFile;
    inboundsSubscriptionsFile = proxyInboundsSubscriptionsFile;
    inboundsSubscriptionsBaseUrl =
      if proxyInboundsSubscriptionsBaseUrl == null then "" else proxyInboundsSubscriptionsBaseUrl;
    autoProxyEnabled = if proxyCfg.autoProxy.enable then "1" else "0";
    autoProxyStateDir = constants.autoProxyStateDir;
    localProxyUrl = "http://${
      if proxyCfg.listener.address == "0.0.0.0" then "127.0.0.1" else proxyCfg.listener.address
    }:${toString proxyCfg.listener.port}";
  };
}
