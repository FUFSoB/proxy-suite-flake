# Systemd unit definitions for proxy-suite services and timers.
{
  lib,
  builders,
  proxyCfg,
  proxyEnabled,
  hybridEnabled,
  pureXrayEnabled,
  globalTun,
  globalTproxy,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretEnabled,
  hasSubscriptions,
  scripts,
  perAppRouting,
  routingScripts,
}:

let
  inherit (builders)
    mkAnchorService
    mkRestartingService
    mkOneshotService
    mkUserRuleService
    ;

  inherit (routingScripts)
    xrayTunUpScript
    tproxyUpScript
    tproxyDownScript
    tunCleanupScript
    ;

  serviceNames = {
    socks = "proxy-suite-socks";
    tproxy = "proxy-suite-tproxy";
    tun = "proxy-suite-tun";
    perAppTun = "proxy-suite-per-app-tun";
    perAppTproxy = "proxy-suite-per-app-tproxy";
    perAppZapret = "proxy-suite-per-app-zapret";
    subscriptionUpdate = "proxy-suite-subscription-update";
  };

  backendDescription =
    if pureXrayEnabled then
      "XRay"
    else if hybridEnabled then
      "sing-box + XRay sidecar"
    else
      "sing-box";

  localProxyAuthEnabled =
    proxyCfg.auth.username != null
    && (proxyCfg.auth.password != null || proxyCfg.auth.passwordFile != null);

  systemServiceEntries = [
    {
      enable = proxyEnabled;
      name = serviceNames.socks;
      value = mkRestartingService {
        description = "${backendDescription} proxy client (SOCKS + TProxy-ready)";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        execStart = scripts.startSocks;
        runtimeDirectory = serviceNames.socks;
        stateDirectory = "proxy-suite";
      };
    }
    {
      enable = proxyEnabled && globalTproxy.enable;
      name = serviceNames.tproxy;
      value = mkOneshotService {
        description = "proxy-suite TProxy - nftables rules and policy routing";
        after = [
          "network.target"
          "${serviceNames.socks}.service"
        ];
        wantedBy = lib.optionals globalTproxy.autostart [ "multi-user.target" ];
        requires = [ "${serviceNames.socks}.service" ];
        conflicts = [
          "${serviceNames.tun}.service"
          "${serviceNames.perAppTproxy}.service"
        ];
        execStart = tproxyUpScript;
        execStop = tproxyDownScript;
      };
    }
    {
      enable = proxyEnabled && globalTun.enable;
      name = serviceNames.tun;
      value = mkRestartingService {
        description = "${backendDescription} TUN proxy client";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = lib.optionals globalTun.autostart [ "multi-user.target" ];
        conflicts = [ "${serviceNames.tproxy}.service" ];
        execStartPre = tunCleanupScript;
        execStart = scripts.startTun;
        execStartPost = if pureXrayEnabled then xrayTunUpScript else null;
        execStopPost = tunCleanupScript;
        runtimeDirectory = serviceNames.tun;
        stateDirectory = "proxy-suite";
      };
    }
    {
      enable = proxyEnabled && perAppRoutingTun.enable;
      name = serviceNames.perAppTun;
      value = mkRestartingService {
        description = "proxy-suite per-app-routing TUN backend";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        execStartPre = perAppRouting.perAppTunDownScript;
        execStart = scripts.startPerAppTun;
        execStartPost = perAppRouting.perAppTunUpScript;
        execStopPost = perAppRouting.perAppTunDownScript;
        runtimeDirectory = serviceNames.perAppTun;
        stateDirectory = "proxy-suite";
      };
    }
    {
      enable = proxyEnabled && perAppRoutingTun.enable;
      name = "${serviceNames.perAppTun}-user@";
      value = mkUserRuleService {
        description = "Enable proxy-suite app TUN marking for user %i";
        backendService = serviceNames.perAppTun;
        execStart = "${perAppRouting.perAppTunUserRuleStart} %i";
        execStop = "${perAppRouting.perAppTunUserRuleStop} %i";
      };
    }
    {
      enable = proxyEnabled && perAppRoutingTproxy.enable;
      name = serviceNames.perAppTproxy;
      value = mkOneshotService {
        description = "proxy-suite per-app-routing TProxy backend";
        after = [
          "network.target"
          "${serviceNames.socks}.service"
        ];
        requires = [ "${serviceNames.socks}.service" ];
        conflicts = [
          "${serviceNames.tproxy}.service"
          "${serviceNames.tun}.service"
        ];
        execStart = perAppRouting.perAppTproxyUpScript;
        execStop = perAppRouting.perAppTproxyDownScript;
      };
    }
    {
      enable = proxyEnabled && perAppRoutingTproxy.enable;
      name = "${serviceNames.perAppTproxy}-user@";
      value = mkUserRuleService {
        description = "Enable proxy-suite app TProxy marking for user %i";
        backendService = serviceNames.perAppTproxy;
        execStart = "${perAppRouting.perAppTproxyUserRuleStart} %i";
        execStop = "${perAppRouting.perAppTproxyUserRuleStop} %i";
      };
    }
    {
      enable = perAppZapretEnabled;
      name = "${serviceNames.perAppZapret}-user@";
      value = mkUserRuleService {
        description = "Enable proxy-suite app zapret marking for user %i";
        backendService = serviceNames.perAppZapret;
        execStart = "${perAppRouting.perAppZapretUserRuleStart} %i";
        execStop = "${perAppRouting.perAppZapretUserRuleStop} %i";
      };
    }
    {
      enable = proxyEnabled && hasSubscriptions;
      name = serviceNames.subscriptionUpdate;
      value = mkOneshotService {
        description = "Refresh proxy-suite subscription caches";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        execStart = scripts.subscriptionUpdateScript;
        stateDirectory = "proxy-suite";
      };
    }
    {
      enable = proxyEnabled;
      name = "proxy-suite-route-mode@";
      value = mkOneshotService {
        description = "Set proxy-suite route mode to %i";
        execStart = "${scripts.setRouteModeScript} %i";
        extraServiceConfig.RemainAfterExit = false;
      };
    }
  ];

  userServiceEntries = [
    {
      enable = perAppRoutingTun.enable;
      name = "${serviceNames.perAppTun}-anchor";
      value = mkAnchorService perAppRouting.perAppTunSliceName "Anchor service for proxy-suite app TUN slice";
    }
    {
      enable = perAppRoutingTproxy.enable;
      name = "${serviceNames.perAppTproxy}-anchor";
      value = mkAnchorService perAppRouting.perAppTproxySliceName "Anchor service for proxy-suite app TProxy slice";
    }
    {
      enable = perAppZapretEnabled;
      name = "${serviceNames.perAppZapret}-anchor";
      value = mkAnchorService perAppRouting.perAppZapretSliceName "Anchor service for proxy-suite app zapret slice";
    }
  ];

  timerEntries = [
    {
      enable = proxyEnabled && hasSubscriptions;
      name = serviceNames.subscriptionUpdate;
      value = {
        description = "Periodic proxy-suite subscription refresh";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = proxyCfg.subscriptionUpdateInterval;
        };
      };
    }
  ];
in
{
  inherit
    serviceNames
    localProxyAuthEnabled
    systemServiceEntries
    userServiceEntries
    timerEntries
    ;
}
