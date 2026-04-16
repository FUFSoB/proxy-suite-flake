# Assembles all sing-box systemd services from the sub-modules.
{
  config,
  lib,
  pkgs,
  cfg,
  tproxyFile,
  tunFile,
  appTunFile,
  nftablesRulesFile,
  appTproxyRulesFile,
  appZapretRulesFile,
  appTunChainFile,
  ip,
  nft,
}:

let
  singBoxCfg = cfg.singBox;
  appRoutingCfg = cfg.appRouting;
  appRoutingTun = appRoutingCfg.backends.tun;
  appRoutingTproxy = appRoutingCfg.backends.tproxy;
  appRoutingZapret = appRoutingCfg.backends.zapret;
  userControlCfg = cfg.userControl;

  builtinTags = [ "proxy" "direct" "block" ];
  outboundTags = map (ob: ob.tag) singBoxCfg.outbounds;
  invalidRoutingTargets = lib.unique (
    map (rule: rule.outbound) (
      builtins.filter (rule: !builtins.elem rule.outbound (builtinTags ++ outboundTags)) singBoxCfg.routing.rules
    )
  );

  # Tool paths – defined once here and passed into sub-modules as needed.
  jq = "${pkgs.jq}/bin/jq";
  python3 = "${pkgs.python3}/bin/python3";
  singBox = "${pkgs.sing-box}/bin/sing-box";
  proxychains4 = "${pkgs.proxychains-ng}/bin/proxychains4";
  systemdRun = "${pkgs.systemd}/bin/systemd-run";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  journalctl = "${pkgs.systemd}/bin/journalctl";
  idBin = "${pkgs.coreutils}/bin/id";
  grepBin = "${pkgs.gnugrep}/bin/grep";
  awk = "${pkgs.gawk}/bin/awk";
  sleepBin = "${pkgs.coreutils}/bin/sleep";
  headBin = "${pkgs.coreutils}/bin/head";
  seqBin = "${pkgs.coreutils}/bin/seq";
  findBin = "${pkgs.findutils}/bin/find";

  proxySuiteScriptsDir = ../../../scripts;
  parserScriptsPythonPath = proxySuiteScriptsDir;
  buildOutboundPy = "${proxySuiteScriptsDir}/build-outbound.py";
  fetchSubscriptionPy = "${proxySuiteScriptsDir}/fetch-subscription.py";

  polkit = import ./polkit.nix {
    inherit lib cfg userControlCfg;
  };

  scripts = import ./scripts.nix {
    inherit lib pkgs singBoxCfg appRoutingTun;
    inherit jq python3 singBox parserScriptsPythonPath buildOutboundPy fetchSubscriptionPy;
    inherit tproxyFile tunFile appTunFile;
  };

  appRouting = import ./app-routing.nix {
    inherit lib pkgs cfg singBoxCfg appRoutingCfg appRoutingTun appRoutingTproxy appRoutingZapret;
    inherit appTunChainFile appTproxyRulesFile appZapretRulesFile;
    inherit ip nft;
    inherit awk grepBin findBin headBin seqBin sleepBin;
    inherit jq proxychains4 systemdRun systemctl journalctl idBin;
    clashApi = "http://127.0.0.1:${toString singBoxCfg.clashApiPort}";
    selection = singBoxCfg.selection;
    inherit (scripts) subscriptionTagsList;
  };
in
{
  environment.systemPackages = [ appRouting.proxyCtl ];

  # nftables must be on for TProxy to work.
  networking.nftables.enable = lib.mkIf (
    singBoxCfg.tproxy.enable || appRoutingTun.enable || appRoutingTproxy.enable || appRoutingZapret.enable
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
    lib.optionalAttrs appRoutingTun.enable {
      proxy-suite-app-tun-anchor =
        appRouting.mkAnchorService appRouting.appTunSliceName "Anchor service for proxy-suite app TUN slice";
    }
    // lib.optionalAttrs appRoutingTproxy.enable {
      proxy-suite-app-tproxy-anchor =
        appRouting.mkAnchorService appRouting.appTproxySliceName "Anchor service for proxy-suite app TProxy slice";
    }
    // lib.optionalAttrs (appRoutingZapret.enable && cfg.zapret.enable) {
      proxy-suite-app-zapret-anchor =
        appRouting.mkAnchorService appRouting.appZapretSliceName "Anchor service for proxy-suite app zapret slice";
    };

  assertions = import ../service-assertions.nix {
    inherit lib cfg;
    inherit singBoxCfg appRoutingCfg appRoutingTun appRoutingTproxy appRoutingZapret;
    tgWsProxyCfg = cfg.tgWsProxy;
    inherit builtinTags outboundTags invalidRoutingTargets;
    inherit (appRouting)
      effectiveAppRoutingProfileNames
      hasProxychainsProfiles
      hasTunProfiles
      hasTproxyProfiles
      hasZapretProfiles
      ;
  };

  systemd.services = {
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
  // lib.optionalAttrs singBoxCfg.tproxy.enable {
    proxy-suite-tproxy = {
      description = "sing-box TProxy – nftables rules and policy routing";
      after = [
        "network.target"
        "proxy-suite-socks.service"
      ];
      wantedBy = lib.optionals singBoxCfg.tproxy.autostart [ "multi-user.target" ];
      requires = [ "proxy-suite-socks.service" ];
      conflicts = [
        "proxy-suite-tun.service"
        "proxy-suite-app-tproxy.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "proxy-suite-tproxy-up" ''
          ${nft} delete table ip singbox 2>/dev/null || true
          ${nft} -f ${nftablesRulesFile}
          ${ip} route add local default dev lo table ${toString singBoxCfg.routeTable}
          ${ip} rule add fwmark ${toString singBoxCfg.fwmark} table ${toString singBoxCfg.routeTable}
        '';
        ExecStop = pkgs.writeShellScript "proxy-suite-tproxy-down" ''
          ${nft} delete table ip singbox 2>/dev/null || true
          ${ip} route del local default dev lo table ${toString singBoxCfg.routeTable} 2>/dev/null || true
          ${ip} rule del fwmark ${toString singBoxCfg.fwmark} table ${toString singBoxCfg.routeTable} 2>/dev/null || true
        '';
      };
    };
  }
  // lib.optionalAttrs singBoxCfg.tun.enable {
    proxy-suite-tun = {
      description = "sing-box TUN proxy client";
      after = [ "network-online.target" ];
      wantedBy = lib.optionals singBoxCfg.tun.autostart [ "multi-user.target" ];
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
  // lib.optionalAttrs appRoutingTun.enable {
    proxy-suite-app-tun = {
      description = "sing-box app-routing TUN backend";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${scripts.startAppTun}";
        ExecStartPost = "${appRouting.appTunUpScript}";
        ExecStopPost = "${appRouting.appTunDownScript}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "proxy-suite-app-tun";
        StateDirectory = "proxy-suite";
      };
    };

    "proxy-suite-app-tun-user@" = {
      description = "Enable proxy-suite app TUN marking for user %i";
      requires = [ "proxy-suite-app-tun.service" ];
      after = [ "proxy-suite-app-tun.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${appRouting.appTunUserRuleStart} %i";
        ExecStop = "${appRouting.appTunUserRuleStop} %i";
      };
    };
  }
  // lib.optionalAttrs appRoutingTproxy.enable {
    proxy-suite-app-tproxy = {
      description = "proxy-suite app-routing TProxy backend";
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
        ExecStart = "${appRouting.appTproxyUpScript}";
        ExecStop = "${appRouting.appTproxyDownScript}";
      };
    };

    "proxy-suite-app-tproxy-user@" = {
      description = "Enable proxy-suite app TProxy marking for user %i";
      requires = [ "proxy-suite-app-tproxy.service" ];
      after = [ "proxy-suite-app-tproxy.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${appRouting.appTproxyUserRuleStart} %i";
        ExecStop = "${appRouting.appTproxyUserRuleStop} %i";
      };
    };
  }
  // lib.optionalAttrs (appRoutingZapret.enable && cfg.zapret.enable) {
    "proxy-suite-app-zapret-user@" = {
      description = "Enable proxy-suite app zapret marking for user %i";
      requires = [ "proxy-suite-app-zapret.service" ];
      after = [ "proxy-suite-app-zapret.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${appRouting.appZapretUserRuleStart} %i";
        ExecStop = "${appRouting.appZapretUserRuleStop} %i";
      };
    };
  }
  // lib.optionalAttrs scripts.hasSubscriptions {
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

  systemd.timers = lib.optionalAttrs scripts.hasSubscriptions {
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
