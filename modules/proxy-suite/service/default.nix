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

  inherit (context)
    singBoxCfg
    perAppRoutingCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    userControlCfg
    builtinTags
    outboundTags
    subscriptionTags
    invalidRoutingTargets
    polkit
    scripts
    perAppRouting
    control
    ;
in
{
  environment.systemPackages = [ control.proxyCtl ];

  # nftables must be on for TProxy to work.
  networking.nftables.enable = lib.mkIf (
    globalTproxy.enable || perAppRoutingTun.enable || perAppRoutingTproxy.enable || perAppZapretCfg.enable
  ) (lib.mkDefault true);

  users.groups = lib.mkIf (cfg.enable && polkit.userControlEnabled) {
    "${userControlCfg.group}" = { };
  };

  security.polkit.enable = lib.mkIf (cfg.enable && polkit.userControlEnabled) true;
  security.polkit.extraConfig = lib.mkIf (cfg.enable && polkit.userControlEnabled) (lib.mkAfter ''
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
  '');

  systemd.user.services =
    lib.optionalAttrs perAppRoutingTun.enable {
      proxy-suite-per-app-tun-anchor =
        perAppRouting.mkAnchorService perAppRouting.perAppTunSliceName "Anchor service for proxy-suite app TUN slice";
    }
    // lib.optionalAttrs perAppRoutingTproxy.enable {
      proxy-suite-per-app-tproxy-anchor =
        perAppRouting.mkAnchorService perAppRouting.perAppTproxySliceName "Anchor service for proxy-suite app TProxy slice";
    }
    // lib.optionalAttrs (perAppZapretCfg.enable && cfg.zapret.enable) {
      proxy-suite-per-app-zapret-anchor =
        perAppRouting.mkAnchorService perAppRouting.perAppZapretSliceName "Anchor service for proxy-suite app zapret slice";
    };

  assertions = import ../service-assertions.nix {
    inherit lib cfg;
    inherit singBoxCfg perAppRoutingCfg perAppRoutingTun perAppRoutingTproxy;
    perAppZapretCfg = perAppZapretCfg;
    tgWsProxyCfg = cfg.tgWsProxy;
    inherit builtinTags outboundTags subscriptionTags invalidRoutingTargets;
    inherit (perAppRouting)
      effectivePerAppRoutingProfileNames
      hasProxychainsProfiles
      hasTunProfiles
      hasTproxyProfiles
      hasZapretProfiles
      ;
  };

  systemd.services = {
  }
  // lib.optionalAttrs singBoxCfg.enable {
    proxy-suite-socks = {
      description = "sing-box proxy client (SOCKS + TProxy-ready)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${scripts.startSocks}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "proxy-suite-socks";
        StateDirectory = "proxy-suite";
      };
    };
  }
  // lib.optionalAttrs (singBoxCfg.enable && globalTproxy.enable) {
    proxy-suite-tproxy = {
      description = "sing-box TProxy – nftables rules and policy routing";
      after = [
        "network.target"
        "proxy-suite-socks.service"
      ];
      wantedBy = lib.optionals globalTproxy.autostart [ "multi-user.target" ];
      requires = [ "proxy-suite-socks.service" ];
      conflicts = [
        "proxy-suite-tun.service"
        "proxy-suite-per-app-tproxy.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "proxy-suite-tproxy-up" ''
          ${nft} delete table ip singbox 2>/dev/null || true
          ${nft} -f ${nftablesRulesFile}
          ${ip} route add local default dev lo table ${toString globalTproxy.routeTable}
          ${ip} rule add fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable}
        '';
        ExecStop = pkgs.writeShellScript "proxy-suite-tproxy-down" ''
          ${nft} delete table ip singbox 2>/dev/null || true
          ${ip} route del local default dev lo table ${toString globalTproxy.routeTable} 2>/dev/null || true
          ${ip} rule del fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable} 2>/dev/null || true
        '';
      };
    };
  }
  // lib.optionalAttrs (singBoxCfg.enable && globalTun.enable) {
    proxy-suite-tun = {
      description = "sing-box TUN proxy client";
      after = [ "network-online.target" ];
      wantedBy = lib.optionals globalTun.autostart [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      conflicts = [ "proxy-suite-tproxy.service" ];
      serviceConfig = {
        ExecStart = "${scripts.startTun}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "proxy-suite-tun";
        StateDirectory = "proxy-suite";
      };
    };
  }
  // lib.optionalAttrs (singBoxCfg.enable && perAppRoutingTun.enable) {
    proxy-suite-per-app-tun = {
      description = "sing-box per-app-routing TUN backend";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${scripts.startPerAppTun}";
        ExecStartPost = "${perAppRouting.perAppTunUpScript}";
        ExecStopPost = "${perAppRouting.perAppTunDownScript}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "proxy-suite-per-app-tun";
        StateDirectory = "proxy-suite";
      };
    };

    "proxy-suite-per-app-tun-user@" = {
      description = "Enable proxy-suite app TUN marking for user %i";
      requires = [ "proxy-suite-per-app-tun.service" ];
      after = [ "proxy-suite-per-app-tun.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${perAppRouting.perAppTunUserRuleStart} %i";
        ExecStop = "${perAppRouting.perAppTunUserRuleStop} %i";
      };
    };
  }
  // lib.optionalAttrs (singBoxCfg.enable && perAppRoutingTproxy.enable) {
    proxy-suite-per-app-tproxy = {
      description = "proxy-suite per-app-routing TProxy backend";
      after = [
        "network.target"
        "proxy-suite-socks.service"
      ];
      requires = [ "proxy-suite-socks.service" ];
      conflicts = [
        "proxy-suite-tproxy.service"
        "proxy-suite-tun.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${perAppRouting.perAppTproxyUpScript}";
        ExecStop = "${perAppRouting.perAppTproxyDownScript}";
      };
    };

    "proxy-suite-per-app-tproxy-user@" = {
      description = "Enable proxy-suite app TProxy marking for user %i";
      requires = [ "proxy-suite-per-app-tproxy.service" ];
      after = [ "proxy-suite-per-app-tproxy.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${perAppRouting.perAppTproxyUserRuleStart} %i";
        ExecStop = "${perAppRouting.perAppTproxyUserRuleStop} %i";
      };
    };
  }
  // lib.optionalAttrs (perAppZapretCfg.enable && cfg.zapret.enable) {
    "proxy-suite-per-app-zapret-user@" = {
      description = "Enable proxy-suite app zapret marking for user %i";
      requires = [ "proxy-suite-per-app-zapret.service" ];
      after = [ "proxy-suite-per-app-zapret.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${perAppRouting.perAppZapretUserRuleStart} %i";
        ExecStop = "${perAppRouting.perAppZapretUserRuleStop} %i";
      };
    };
  }
  // lib.optionalAttrs (singBoxCfg.enable && scripts.hasSubscriptions) {
    proxy-suite-subscription-update = {
      description = "Refresh proxy-suite subscription caches";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "proxy-suite";
        ExecStart = "${scripts.subscriptionUpdateScript}";
      };
    };
  };

  systemd.timers = lib.optionalAttrs (singBoxCfg.enable && scripts.hasSubscriptions) {
    proxy-suite-subscription-update = {
      description = "Periodic proxy-suite subscription refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = singBoxCfg.subscriptionUpdateInterval;
      };
    };
  };
}
