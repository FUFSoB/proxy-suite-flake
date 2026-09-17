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
  sshProxyOutboundEnabled,
  sshProxyUnitEnabled,
  torOutboundEnabled,
  torOnionEnabled,
  proxyInboundsEnabled,
  proxyInboundsNeedLocalProxy,
  scripts,
  perAppRouting,
  routingScripts,
  geodata,
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
    inbounds = "proxy-suite-inbounds";
    inboundStats = "proxy-suite-inbound-stats";
  };

  backendDescription =
    if pureXrayEnabled then
      "XRay"
    else if hybridEnabled then
      "sing-box + XRay sidecar"
    else
      "sing-box";

  localProxyAuthEnabled =
    proxyCfg.listener.auth.username != null
    && (proxyCfg.listener.auth.password != null || proxyCfg.listener.auth.passwordFile != null);

  # XRay finds geoip.dat/geosite.dat through this; sing-box ignores it.
  xrayAssetEnv = lib.optionalAttrs (geodata.xray.assets != null) {
    Environment = [ "XRAY_LOCATION_ASSET=${geodata.xray.assets}/share/v2ray" ];
  };

  systemServiceEntries = [
    {
      enable = proxyEnabled;
      name = serviceNames.socks;
      value = mkRestartingService {
        description = "${backendDescription} proxy client (SOCKS + TProxy-ready)";
        # Only XRay goes through the OpenSSH unit's listener.
        after = [
          "network-online.target"
        ]
        ++ lib.optional (sshProxyOutboundEnabled && sshProxyUnitEnabled) "proxy-suite-ssh-proxy.service";
        # Not after Tor: it may reach its relays through this listener.
        wants = [
          "network-online.target"
        ]
        ++ lib.optional (sshProxyOutboundEnabled && sshProxyUnitEnabled) "proxy-suite-ssh-proxy.service"
        ++ lib.optional torOutboundEnabled "proxy-suite-tor.service";
        wantedBy = [ "multi-user.target" ];
        execStart = scripts.startSocks;
        runtimeDirectory = serviceNames.socks;
        stateDirectory = "proxy-suite";
        extraServiceConfig = xrayAssetEnv;
      };
    }
    {
      enable = proxyInboundsEnabled;
      name = serviceNames.inbounds;
      value = mkRestartingService {
        description = "XRay server inbounds (accept connections from outside)";
        after = [
          "network-online.target"
        ]
        # After the client stack, but not `requires`: direct listeners keep serving
        # without it.
        ++ lib.optional proxyInboundsNeedLocalProxy "${serviceNames.socks}.service"
        # For the onion address in the share links.
        ++ lib.optional torOnionEnabled "proxy-suite-tor.service";
        wants = [
          "network-online.target"
        ]
        ++ lib.optional proxyInboundsNeedLocalProxy "${serviceNames.socks}.service"
        ++ lib.optional torOnionEnabled "proxy-suite-tor.service";
        wantedBy = [ "multi-user.target" ];
        execStart = scripts.startInbounds;
        runtimeDirectory = serviceNames.inbounds;
        # The collector's file.
        stateDirectory = "proxy-suite";
        # While XRay still runs: what it counted since the last timer run.
        extraServiceConfig = xrayAssetEnv // {
          ExecStop = scripts.collectInboundStats;
        };
      };
    }
    {
      enable = proxyInboundsEnabled;
      name = serviceNames.inboundStats;
      value = mkOneshotService {
        description = "proxy-suite - add up per-user traffic through the inbounds";
        after = [ "${serviceNames.inbounds}.service" ];
        execStart = scripts.collectInboundStats;
        stateDirectory = "proxy-suite";
        # Run by a timer: a unit left "active" would never be started again.
        extraServiceConfig.RemainAfterExit = false;
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
        wantedBy = lib.optionals (proxyCfg.autostart == "tproxy") [ "multi-user.target" ];
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
        wantedBy = lib.optionals (proxyCfg.autostart == "tun") [ "multi-user.target" ];
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
      # Not gated on hasSubscriptions: runtime subscriptions need refreshing too.
      enable = proxyEnabled;
      name = serviceNames.subscriptionUpdate;
      value = mkOneshotService {
        description = "Refresh proxy-suite subscription caches";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        execStart = scripts.subscriptionUpdateScript;
        stateDirectory = "proxy-suite";
        # Run by a timer and by `proxy subs update`: a unit left "active" would never run again.
        extraServiceConfig.RemainAfterExit = false;
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
    {
      enable = proxyEnabled;
      name = "proxy-suite-outbound-pin@";
      value = mkOneshotService {
        # %I: proxy-ctl systemd-escapes the tag, so "ssh-proxy" arrives as ssh\x2dproxy.
        description = "Pin the proxy-suite outbound to %I";
        execStart = "${scripts.pinOutboundScript} %I";
        stateDirectory = "proxy-suite";
        extraServiceConfig.RemainAfterExit = false;
      };
    }
    {
      enable = proxyEnabled;
      name = "proxy-suite-outbound-unpin";
      value = mkOneshotService {
        description = "Unpin the proxy-suite outbound";
        execStart = "${scripts.pinOutboundScript}";
        stateDirectory = "proxy-suite";
        extraServiceConfig.RemainAfterExit = false;
      };
    }
    {
      enable = proxyEnabled;
      name = "proxy-suite-outbound-reload";
      value = mkOneshotService {
        description = "Apply proxy-suite outbounds and subscriptions added at runtime";
        execStart = scripts.reloadOutboundsScript;
        stateDirectory = "proxy-suite";
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
      enable = proxyEnabled;
      name = serviceNames.subscriptionUpdate;
      value = {
        description = "Periodic proxy-suite subscription refresh";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # OnActiveSec, not OnBootSec: see the autoProxy timer.
          OnActiveSec = "5m";
          OnUnitActiveSec = proxyCfg.subscriptionUpdateInterval;
        };
      };
    }
    {
      enable = proxyInboundsEnabled;
      name = serviceNames.inboundStats;
      value = {
        description = "proxy-suite per-user inbound traffic collection";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # OnActiveSec, not OnBootSec: see the autoProxy timer.
          OnActiveSec = "5m";
          OnUnitActiveSec = "5m";
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
