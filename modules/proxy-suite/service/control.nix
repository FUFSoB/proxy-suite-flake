# Builds proxy-ctl from global proxy-suite state and per-app routing metadata.
{
  packages,
  singBoxCfg,
  perAppRoutingCfg,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretCfg,
  zapretEnabled,
  subscriptionTagsFile,
  perAppRoutingProfilesFile,
  proxychainsConfigFile,
  proxychainsQuietArg,
}:
{
  proxyCtl = packages.mkProxyCtl {
    clashApi = "http://127.0.0.1:${toString singBoxCfg.clashApiPort}";
    selection = singBoxCfg.selection;
    inherit
      subscriptionTagsFile
      perAppRoutingProfilesFile
      proxychainsConfigFile
      proxychainsQuietArg
      ;
    perAppRoutingEnabled = if perAppRoutingCfg.enable then "1" else "0";
    perAppRoutingProxychainsEnabled = if perAppRoutingCfg.proxychains.enable then "1" else "0";
    perAppRoutingTunEnabled = if perAppRoutingTun.enable then "1" else "0";
    perAppRoutingTproxyEnabled = if perAppRoutingTproxy.enable then "1" else "0";
    perAppRoutingZapretEnabled = if (perAppZapretCfg.enable && zapretEnabled) then "1" else "0";
  };
}
