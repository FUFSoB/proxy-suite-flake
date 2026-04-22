# Assembles all sing-box systemd services from the sub-modules.
{
  config,
  lib,
  pkgs,
  packages,
  cfg,
  tproxyFile,
  tunFile,
  perAppTunFile,
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
    singBoxCfg.auth.username != null
    && (singBoxCfg.auth.password != null || singBoxCfg.auth.passwordFile != null);

  tproxyUpScript = pkgs.writeShellScript "proxy-suite-tproxy-up" ''
    ${nft} delete table ip singbox 2>/dev/null || true
    ${nft} -f ${nftablesRulesFile}
    ${ip} route add local default dev lo table ${toString globalTproxy.routeTable}
    ${ip} rule add fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable}
  '';

  tproxyDownScript = pkgs.writeShellScript "proxy-suite-tproxy-down" ''
    ${nft} delete table ip singbox 2>/dev/null || true
    ${ip} route del local default dev lo table ${toString globalTproxy.routeTable} 2>/dev/null || true
    ${ip} rule del fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable} 2>/dev/null || true
  '';

  systemServiceEntries = [
    {
      enable = singBoxCfg.enable;
      name = serviceNames.socks;
      value = mkRestartingService {
        description = "sing-box proxy client (SOCKS + TProxy-ready)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        execStart = scripts.startSocks;
        runtimeDirectory = serviceNames.socks;
        stateDirectory = "proxy-suite";
      };
    }
    {
      enable = singBoxCfg.enable && globalTproxy.enable;
      name = serviceNames.tproxy;
      value = mkOneshotService {
        description = "sing-box TProxy – nftables rules and policy routing";
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
      enable = singBoxCfg.enable && globalTun.enable;
      name = serviceNames.tun;
      value = mkRestartingService {
        description = "sing-box TUN proxy client";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = lib.optionals globalTun.autostart [ "multi-user.target" ];
        conflicts = [ "${serviceNames.tproxy}.service" ];
        execStart = scripts.startTun;
        runtimeDirectory = serviceNames.tun;
        stateDirectory = "proxy-suite";
      };
    }
    {
      enable = singBoxCfg.enable && perAppRoutingTun.enable;
      name = serviceNames.perAppTun;
      value = mkRestartingService {
        description = "sing-box per-app-routing TUN backend";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        execStart = scripts.startPerAppTun;
        execStartPost = perAppRouting.perAppTunUpScript;
        execStopPost = perAppRouting.perAppTunDownScript;
        runtimeDirectory = serviceNames.perAppTun;
        stateDirectory = "proxy-suite";
      };
    }
    {
      enable = singBoxCfg.enable && perAppRoutingTun.enable;
      name = "${serviceNames.perAppTun}-user@";
      value = mkUserRuleService {
        description = "Enable proxy-suite app TUN marking for user %i";
        backendService = serviceNames.perAppTun;
        execStart = "${perAppRouting.perAppTunUserRuleStart} %i";
        execStop = "${perAppRouting.perAppTunUserRuleStop} %i";
      };
    }
    {
      enable = singBoxCfg.enable && perAppRoutingTproxy.enable;
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
      enable = singBoxCfg.enable && perAppRoutingTproxy.enable;
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
      enable = singBoxCfg.enable && hasSubscriptions;
      name = serviceNames.subscriptionUpdate;
      value = mkOneshotService {
        description = "Refresh proxy-suite subscription caches";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        execStart = scripts.subscriptionUpdateScript;
        stateDirectory = "proxy-suite";
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
      enable = singBoxCfg.enable && hasSubscriptions;
      name = serviceNames.subscriptionUpdate;
      value = {
        description = "Periodic proxy-suite subscription refresh";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = singBoxCfg.subscriptionUpdateInterval;
        };
      };
    }
  ];
in
{
  environment.systemPackages = [ control.proxyCtl ];

  # nftables must be on for TProxy to work.
  networking.nftables.enable = lib.mkIf (
    globalTproxy.enable || perAppRoutingTun.enable || perAppRoutingTproxy.enable || perAppZapretEnabled
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
