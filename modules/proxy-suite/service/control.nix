# Builds proxy-ctl from global proxy-suite state and per-app routing metadata.
{
  packages,
  singBoxCfg,
  proxyCfg,
  perAppRoutingCfg,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretCfg,
  selectionMode,
  subscriptionTagsFile,
  subscriptionCacheDir,
  perAppRoutingProfilesFile,
  proxychainsConfigFile,
  proxychainsQuietArg,
  routeModeStateFile,
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
      ;
    defaultRouteMode = if proxyCfg.proxyByDefault then "blacklist" else "whitelist";
    perAppRoutingEnabled = if perAppRoutingCfg.enable then "1" else "0";
    perAppRoutingProxychainsEnabled = if perAppRoutingCfg.proxychains.enable then "1" else "0";
    perAppRoutingTunEnabled = if perAppRoutingTun.enable then "1" else "0";
    perAppRoutingTproxyEnabled = if perAppRoutingTproxy.enable then "1" else "0";
    perAppRoutingZapretEnabled = if perAppZapretCfg.enable then "1" else "0";
  };
}
