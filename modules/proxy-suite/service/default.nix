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

  defaultUplinkIPv4Source = builders.mkDefaultUplinkIPv4Source {
    inherit ip;
    awk = "${pkgs.gawk}/bin/awk";
    errorMessage = "proxy-suite: could not determine the default uplink IPv4 address for XRay TUN";
  };

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
    hybridEnabled
    pureXrayEnabled
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
  constants = derived.constants;
  inherit (constants)
    tunAutoRouteTableIndex
    tunAutoRouteRulePriority
    xrayTunPerAppTproxyRulePriority
    xrayTunPerAppTunRulePriority
    xrayGlobalTunIPv6Address
    xrayGlobalTunIPv6RoutePrefix
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

  xrayTunUpScript = pkgs.writeShellScript "proxy-suite-xray-tun-up" ''
    set -euo pipefail

    tun_cidr=${lib.escapeShellArg globalTun.address}
    tun6_cidr=${lib.escapeShellArg xrayGlobalTunIPv6Address}
    tun6_route_prefix=${lib.escapeShellArg xrayGlobalTunIPv6RoutePrefix}
    tun_addr=""
    tun_route_prefix=""
    uplink_addr=""

    ${builders.cidrNetworkFunction}

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

    ${defaultUplinkIPv4Source}

    while ${ip} -4 rule del pref ${toString xrayTunPerAppTproxyRulePriority} 2>/dev/null; do :; done
    while ${ip} -4 rule del pref ${toString xrayTunPerAppTunRulePriority} 2>/dev/null; do :; done
    while ${ip} -4 rule del pref ${toString tunAutoRouteRulePriority} 2>/dev/null; do :; done
    while ${ip} -6 rule del pref ${toString xrayTunPerAppTunRulePriority} 2>/dev/null; do :; done
    while ${ip} -6 rule del pref ${toString tunAutoRouteRulePriority} 2>/dev/null; do :; done

    tun_addr="''${tun_cidr%%/*}"
    tun_route_prefix="$(cidr_network "$tun_cidr")"

    ${ip} -4 addr replace "$tun_cidr" dev ${lib.escapeShellArg globalTun.interface}
    ${ip} -6 addr replace "$tun6_cidr" dev ${lib.escapeShellArg globalTun.interface}
    ${ip} -4 route replace "$tun_route_prefix" dev ${lib.escapeShellArg globalTun.interface} src "$tun_addr" table ${toString tunAutoRouteTableIndex}
    ${ip} -4 route replace default dev ${lib.escapeShellArg globalTun.interface} src "$uplink_addr" table ${toString tunAutoRouteTableIndex}
    ${ip} -6 route replace "$tun6_route_prefix" dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
    ${ip} -6 route replace default dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
    ${lib.optionalString perAppRoutingTproxy.enable ''
      ${ip} -4 rule add pref ${toString xrayTunPerAppTproxyRulePriority} fwmark ${toString perAppRoutingTproxy.fwmark} table ${toString perAppRoutingTproxy.routeTable}
    ''}
    ${lib.optionalString perAppRoutingTun.enable ''
      ${ip} -4 rule add pref ${toString xrayTunPerAppTunRulePriority} fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable}
      ${ip} -6 rule add pref ${toString xrayTunPerAppTunRulePriority} fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable}
    ''}
    ${ip} -4 rule add pref ${toString tunAutoRouteRulePriority} not fwmark ${toString globalTproxy.proxyMark} table ${toString tunAutoRouteTableIndex}
    ${ip} -6 rule add pref ${toString tunAutoRouteRulePriority} not fwmark ${toString globalTproxy.proxyMark} table ${toString tunAutoRouteTableIndex}
  '';

  tproxyUpScript = pkgs.writeShellScript "proxy-suite-tproxy-up" ''
    set -euo pipefail

    # Start from a clean policy-routing state.  `ip rule add` permits duplicate
    # rules on some iproute2 versions, and a stale rule can keep packets routed
    # into a dead local table after a failed restart.
    ${builders.mkNftDeleteTable { inherit nft; family = "ip"; table = "singbox"; }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      fwmark = globalTproxy.fwmark;
      table = globalTproxy.routeTable;
    }}
    ${builders.mkIpLocalDefaultRouteDelete { inherit ip; table = globalTproxy.routeTable; }}

    ${nft} -f ${nftablesRulesFile}
    ${ip} route replace local default dev lo table ${toString globalTproxy.routeTable}
    ${ip} rule add fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable}
  '';

  tproxyDownScript = pkgs.writeShellScript "proxy-suite-tproxy-down" ''
    set +e

    ${builders.mkNftDeleteTable { inherit nft; family = "ip"; table = "singbox"; }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      fwmark = globalTproxy.fwmark;
      table = globalTproxy.routeTable;
    }}
    ${builders.mkIpLocalDefaultRouteDelete { inherit ip; table = globalTproxy.routeTable; }}
  '';

  tunCleanupScript = pkgs.writeShellScript "proxy-suite-tun-cleanup" ''
    set +e

    # SingBox normally removes these on graceful shutdown, but stale
    # auto_route/auto_redirect state leaves the host routing through a dead TUN
    # interface after `proxy-ctl tun off` or an unclean service stop.
    ${builders.mkNftDeleteTable { inherit nft; family = "inet"; table = "sing-box"; }}
    ${builders.mkIpRuleDeleteByTable { inherit ip; family = "-4"; table = tunAutoRouteTableIndex; }}
    ${builders.mkIpRuleDeleteByTable { inherit ip; family = "-6"; table = tunAutoRouteTableIndex; }}
    ${builders.mkIpRuleDeleteByPriority {
      inherit ip;
      family = "-4";
      priority = xrayTunPerAppTproxyRulePriority;
    }}
    ${builders.mkIpRuleDeleteByPriority {
      inherit ip;
      family = "-4";
      priority = xrayTunPerAppTunRulePriority;
    }}
    ${builders.mkIpRuleDeleteByPriority {
      inherit ip;
      family = "-6";
      priority = xrayTunPerAppTunRulePriority;
    }}
    ${builders.mkIpRouteFlushTable { inherit ip; family = "-4"; table = tunAutoRouteTableIndex; }}
    ${builders.mkIpRouteFlushTable { inherit ip; family = "-6"; table = tunAutoRouteTableIndex; }}
    ${builders.mkIpLinkDelete { inherit ip; interface = globalTun.interface; }}
    ${builders.flushResolvedCaches}
  '';

  systemServiceEntries = [
    {
      enable = proxyEnabled;
      name = serviceNames.socks;
      value = mkRestartingService {
        description = "${
          if pureXrayEnabled then
            "XRay"
          else if hybridEnabled then
            "sing-box + XRay sidecar"
          else
            "sing-box"
        } proxy client (SOCKS + TProxy-ready)";
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
        description = "${
          if pureXrayEnabled then
            "XRay"
          else if hybridEnabled then
            "sing-box + XRay sidecar"
          else
            "sing-box"
        } TUN proxy client";
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
