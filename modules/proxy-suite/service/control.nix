# Builds proxy-ctl from global proxy-suite state and per-app routing metadata.
{ ctx }:

let
  inherit (ctx)
    lib
    localProxy
    packages
    cfg
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
    proxyInboundsCfg
    proxyInboundsEnabled
    amneziaWgProfileNamesFile
    ruleSets
    pkgs
    ;
  inherit (ctx.scripts)
    subscriptionTagsFile
    subscriptionCacheDir
    routeModeStateFile
    proxyInboundsLinksFile
    proxyInboundsSubscriptionsFile
    ;
  inherit (ctx.perAppRouting)
    perAppRoutingProfilesFile
    proxychainsConfigFile
    proxychainsQuietArg
    ;
  proxyInboundsSubscriptionsBaseUrl = proxyInboundsCfg.subscriptions.baseUrl;
  proxyInboundsXray = "${proxyInboundsCfg.package}/bin/xray";
  guiRefreshInterval = cfg.gui.refreshInterval;
  # proxy_ctl.py reads these as "1"/"0" strings.
  flag = enabled: if enabled then "1" else "0";
in
{
  proxyCtl = packages.mkProxyCtl {
    inherit
      guiRefreshInterval
      subscriptionTagsFile
      perAppRoutingProfilesFile
      proxychainsConfigFile
      amneziaWgProfileNamesFile
      ;
    env = {
      CLASH_API = "http://127.0.0.1:${toString singBoxCfg.clashApiPort}";
      SELECTION = selectionMode;
      SUB_TAGS_FILE = toString subscriptionTagsFile;
      SUB_CACHE_DIR = subscriptionCacheDir;
      RULE_SETS_FILE = toString (
        pkgs.writeText "proxy-suite-control" (
          builtins.toJSON (map (rs: { inherit (rs) name path; }) ruleSets)
        )
      );
      PER_APP_ROUTING_ENABLED = flag perAppRoutingCfg.enable;
      PER_APP_ROUTING_PROXYCHAINS_ENABLED = flag perAppRoutingCfg.proxychains.enable;
      PER_APP_ROUTING_TUN_ENABLED = flag perAppRoutingTun.enable;
      PER_APP_ROUTING_TPROXY_ENABLED = flag perAppRoutingTproxy.enable;
      PER_APP_ROUTING_ZAPRET_ENABLED = flag perAppZapretCfg.enable;
      PER_APP_ROUTING_PROFILES_FILE = toString perAppRoutingProfilesFile;
      PROXYCHAINS_CONFIG = toString proxychainsConfigFile;
      PROXYCHAINS_QUIET_ARG = lib.removeSuffix " " proxychainsQuietArg;
      ROUTE_MODE_STATE_FILE = routeModeStateFile;
      DEFAULT_ROUTE_MODE = if proxyCfg.routing.default == "proxy" then "blacklist" else "whitelist";
      AWG_PROFILES_FILE = toString amneziaWgProfileNamesFile;
      WL_FILE = toString (
        pkgs.writeText "proxy-suite-control" (
          builtins.toJSON (
            lib.optionals cfg.whitelistBypass.enable (
              lib.mapAttrsToList (name: c: {
                inherit name;
                inherit (c) platform;
                role = "creator";
              }) cfg.whitelistBypass.creators
              ++ lib.mapAttrsToList (name: j: {
                inherit name;
                inherit (j) platform;
                role = "joiner";
              }) cfg.whitelistBypass.joiners
            )
          )
        )
      );
      INBOUNDS_ENABLED = flag proxyInboundsEnabled;
      INBOUNDS_LINKS_FILE = proxyInboundsLinksFile;
      INBOUNDS_STATS_FILE = constants.inboundStatsFile;
      INBOUNDS_XRAY = proxyInboundsXray;
      INBOUNDS_API = "unix://${constants.inboundStatsApiSocket}";
      INBOUNDS_SUBS_FILE = proxyInboundsSubscriptionsFile;
      INBOUNDS_SUB_BASE_URL =
        if proxyInboundsSubscriptionsBaseUrl == null then "" else proxyInboundsSubscriptionsBaseUrl;
      ZAPRET_AUTO_ENABLED = flag (zapretEngine == "zapret2");
      ZAPRET_STATE_DIR = constants.zapret2StateDir;
      ZAPRET_CUTOFF_ENABLED = flag zapretCutoffEnabled;
      OUTBOUND_INVENTORY_FILE = constants.outboundInventoryFile;
      RUNTIME_OUTBOUNDS_DIR = constants.runtimeOutboundsDir;
      RUNTIME_SUBS_DIR = constants.runtimeSubscriptionsDir;
      USER_CONTROL_GROUP = userControlCfg.group;
      LOCAL_PROXY_URL = "http://${localProxy.hostPart}:${toString proxyCfg.listener.port}";
      AUTOPROXY_ENABLED = flag proxyCfg.autoProxy.enable;
      AUTOPROXY_STATE_DIR = constants.autoProxyStateDir;
      TOR_CONTROL_SOCKET = constants.torControlSocket;
      SING_BOX = "${singBoxCfg.package}/bin/sing-box";
      STATE_DIR = constants.stateDir;
      RUNTIME_DIR = constants.runtimeDir;
      SERVICE_MANAGER = constants.serviceManager;
      PRIVILEGED = flag constants.privileged;
    }
    // lib.optionalAttrs (constants.serviceManager == "supervisor") {
      SUPERVISOR_CTL = constants.systemctl;
    };
  };
}
