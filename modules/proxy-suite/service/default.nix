# Assembles proxy-suite systemd services from the sub-modules.
{
  config,
  lib,
  pkgs,
  packages,
  cfg,
  tproxyFile,
  tunFile,
  perAppTunFile,
  routeModeRulesFile,
  nftablesRulesFile,
  perAppTproxyRulesFile,
  perAppZapretRulesFile,
  perAppTunChainFile,
  ip,
  nft,
}:

let
  context = import ./context.nix {
    inherit
      lib
      pkgs
      packages
      cfg
      tproxyFile
      tunFile
      perAppTunFile
      routeModeRulesFile
      perAppTunChainFile
      perAppTproxyRulesFile
      perAppZapretRulesFile
      ip
      nft
      ;
  };

  builders = import ./builders.nix { inherit lib pkgs; };
  inherit (builders)
    mkNamedUnits
    mkRestartingService
    mkOneshotService
    mkUserRuleService
    mkAnchorService
    ;

  inherit (context)
    derived
    polkit
    scripts
    perAppRouting
    control
    ;

  inherit (derived)
    singBoxCfg
    proxyCfg
    proxyEnabled
    xrayEnabled
    activeBackend
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    userControlCfg
    userControlEnabled
    perAppZapretEnabled
    hasSubscriptions
    outboundTags
    subscriptionTags
    invalidRoutingTargets
    builtinTags
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

  localProxyAuthEnabled =
    proxyCfg.auth.username != null
    && (proxyCfg.auth.password != null || proxyCfg.auth.passwordFile != null);

  # Must match the explicit iproute2_* indexes written to the global SingBox TUN
  # template in config.nix. XRay uses the same table for manual Linux
  # policy routing because XRay's autoSystemRoutingTable is not Linux-ready.
  tunAutoRouteTableIndex = 2022;
  tunAutoRouteRulePriority = 9000;

  xrayTunUpScript = pkgs.writeShellScript "proxy-suite-xray-tun-up" ''
    set -euo pipefail

    for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
      if ${ip} link show dev ${lib.escapeShellArg globalTun.interface} >/dev/null 2>&1; then
        break
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done

    if ! ${ip} link show dev ${lib.escapeShellArg globalTun.interface} >/dev/null 2>&1; then
      echo "proxy-suite: XRay TUN interface ${globalTun.interface} did not appear in time" >&2
      exit 1
    fi

    while ${ip} -4 rule del pref ${toString tunAutoRouteRulePriority} 2>/dev/null; do :; done
    ${ip} -4 route replace default dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
    ${ip} -4 rule add pref ${toString tunAutoRouteRulePriority} not fwmark ${toString globalTproxy.proxyMark} table ${toString tunAutoRouteTableIndex}
  '';

  tproxyUpScript = pkgs.writeShellScript "proxy-suite-tproxy-up" ''
    set -euo pipefail

    # Start from a clean policy-routing state.  `ip rule add` permits duplicate
    # rules on some iproute2 versions, and a stale rule can keep packets routed
    # into a dead local table after a failed restart.
    ${nft} delete table ip singbox 2>/dev/null || true
    while ${ip} rule del fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable} 2>/dev/null; do :; done
    ${ip} route del local default dev lo table ${toString globalTproxy.routeTable} 2>/dev/null || true

    ${nft} -f ${nftablesRulesFile}
    ${ip} route replace local default dev lo table ${toString globalTproxy.routeTable}
    ${ip} rule add fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable}
  '';

  tproxyDownScript = pkgs.writeShellScript "proxy-suite-tproxy-down" ''
    set +e

    ${nft} delete table ip singbox 2>/dev/null || true
    while ${ip} rule del fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable} 2>/dev/null; do :; done
    ${ip} route del local default dev lo table ${toString globalTproxy.routeTable} 2>/dev/null || true
  '';

  tunCleanupScript = pkgs.writeShellScript "proxy-suite-tun-cleanup" ''
    set +e

    # SingBox normally removes these on graceful shutdown, but stale
    # auto_route/auto_redirect state leaves the host routing through a dead TUN
    # interface after `proxy-ctl tun off` or an unclean service stop.
    ${nft} delete table inet sing-box 2>/dev/null || true

    while ${ip} -4 rule del table ${toString tunAutoRouteTableIndex} 2>/dev/null; do :; done
    while ${ip} -6 rule del table ${toString tunAutoRouteTableIndex} 2>/dev/null; do :; done
    ${ip} -4 route flush table ${toString tunAutoRouteTableIndex} 2>/dev/null || true
    ${ip} -6 route flush table ${toString tunAutoRouteTableIndex} 2>/dev/null || true

    ${ip} link del dev ${lib.escapeShellArg globalTun.interface} 2>/dev/null || true
  '';

  systemServiceEntries = [
    {
      enable = proxyEnabled;
      name = serviceNames.socks;
      value = mkRestartingService {
        description = "${if xrayEnabled then "XRay" else "sing-box"} proxy client (SOCKS + TProxy-ready)";
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
        description = "${if xrayEnabled then "XRay" else "sing-box"} TUN proxy client";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = lib.optionals globalTun.autostart [ "multi-user.target" ];
        conflicts = [ "${serviceNames.tproxy}.service" ];
        execStartPre = tunCleanupScript;
        execStart = scripts.startTun;
        execStartPost = if xrayEnabled then xrayTunUpScript else null;
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
  environment.systemPackages = [ control.proxyCtl ];

  # nftables must be on for transparent routing backends. Global TUN uses
  # SingBox auto_redirect programs an `inet sing-box` nftables table.
  networking.nftables.enable = lib.mkIf (
    globalTun.enable
    || globalTproxy.enable
    || perAppRoutingTun.enable
    || perAppRoutingTproxy.enable
    || perAppZapretEnabled
  ) (lib.mkDefault true);

  users.groups = lib.mkIf (cfg.enable && (userControlEnabled || localProxyAuthEnabled)) {
    "${userControlCfg.group}" = { };
  };

  security.polkit.enable = lib.mkIf (cfg.enable && userControlEnabled) true;
  security.polkit.extraConfig = lib.mkIf (cfg.enable && userControlEnabled) (
    lib.mkAfter ''
      polkit.addRule(function(action, subject) {
        if (!subject.isInGroup("${userControlCfg.group}")) {
          return null;
        }

        if (action.id !== "org.freedesktop.systemd1.manage-units") {
          return null;
        }

        var unit = action.lookup("unit");
        ${polkit.userControlPolkitRules}

        return null;
      });
    ''
  );

  systemd.user.services = mkNamedUnits userServiceEntries;

  assertions = import ../service-assertions.nix {
    inherit lib cfg derived;
    tgWsProxyCfg = cfg.tgWsProxy;
    inherit
      builtinTags
      outboundTags
      subscriptionTags
      invalidRoutingTargets
      ;
    inherit (perAppRouting)
      effectivePerAppRoutingProfileNames
      hasProxychainsProfiles
      hasTunProfiles
      hasTproxyProfiles
      hasZapretProfiles
      ;
  };

  systemd.services = mkNamedUnits systemServiceEntries;

  systemd.timers = mkNamedUnits timerEntries;
}
