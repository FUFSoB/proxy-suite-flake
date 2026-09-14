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
  proxyInboundsFile,
  proxyInboundsSpecFile,
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
      proxyInboundsFile
      proxyInboundsSpecFile
      perAppTunChainFile
      perAppTproxyRulesFile
      perAppZapretRulesFile
      ip
      nft
      ;
  };

  builders = import ./builders.nix { inherit lib pkgs; };
  inherit (builders) mkNamedUnits;

  inherit (context)
    derived
    polkit
    scripts
    perAppRouting
    control
    ;

  inherit (derived)
    proxyCfg
    proxyEnabled
    hybridEnabled
    pureXrayEnabled
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    userControlCfg
    userControlEnabled
    perAppZapretEnabled
    sshProxyOutboundEnabled
    sshProxyUnitEnabled
    proxyInboundsEnabled
    proxyInboundsNeedLocalProxy
    proxyInboundFirewallPorts
    proxyInboundFirewallUdpPorts
    outboundTags
    effectiveOutboundTags
    subscriptionTags
    invalidRoutingTargets
    builtinTags
    ;
  constants = derived.constants;
  routingScripts = import ./routing-scripts.nix {
    inherit
      lib
      pkgs
      builders
      ip
      nft
      nftablesRulesFile
      constants
      globalTun
      globalTproxy
      perAppRoutingTun
      perAppRoutingTproxy
      ;
  };

  serviceUnits = import ./units.nix {
    inherit
      lib
      builders
      proxyCfg
      proxyEnabled
      hybridEnabled
      pureXrayEnabled
      globalTun
      globalTproxy
      perAppRoutingTun
      perAppRoutingTproxy
      perAppZapretEnabled
      sshProxyOutboundEnabled
      sshProxyUnitEnabled
      proxyInboundsEnabled
      proxyInboundsNeedLocalProxy
      scripts
      perAppRouting
      routingScripts
      ;
    inherit (cfg) geodata;
  };
  inherit (serviceUnits)
    localProxyAuthEnabled
    systemServiceEntries
    userServiceEntries
    timerEntries
    ;
  # autoProxy shells out to the built proxy-ctl, which only exists in this
  # scope, so its units are merged in here rather than alongside the other
  # feature modules in ../default.nix.
  autoProxyUnits = lib.mkIf cfg.proxy.autoProxy.enable (
    import ../autoproxy.nix {
      inherit lib pkgs cfg;
      inherit (control) proxyCtl;
      inherit (constants) autoProxyStateDir;
    }
  );
in
lib.mkMerge [
  autoProxyUnits
  {
    environment.systemPackages = [
      control.proxyCtl
    ]
    ++ lib.optional cfg.tui.enable control.proxyCtl.tui
    ++ lib.optional cfg.gui.enable control.proxyCtl.gui;

    # nftables must be on for transparent routing backends. Global TUN uses
    # SingBox auto_redirect programs an `inet sing-box` nftables table.
    networking.nftables.enable = lib.mkIf (
      globalTun.enable
      || globalTproxy.enable
      || perAppRoutingTun.enable
      || perAppRoutingTproxy.enable
      || perAppZapretEnabled
    ) (lib.mkDefault true);

    # Inbound listeners are reached from outside, so their ports have to be open.
    networking.firewall = lib.mkIf (proxyInboundsEnabled && cfg.inbounds.openFirewall) {
      allowedTCPPorts = proxyInboundFirewallPorts;
      allowedUDPPorts = proxyInboundFirewallUdpPorts;
    };

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

    # Spool dirs for outbounds and subscriptions added at runtime. Setgid so the
    # files proxy-ctl drops here inherit the group; without userControl only root
    # writes them. tmpfiles rather than the start scripts, so the group can add an
    # outbound before the proxy has ever run.
    systemd.tmpfiles.rules = lib.mkIf (cfg.enable && proxyEnabled) (
      map
        (
          dir:
          "d ${dir} ${
            if userControlEnabled then "2770 root ${userControlCfg.group}" else "0700 root root"
          } -"
        )
        [
          constants.runtimeOutboundsDir
          constants.runtimeSubscriptionsDir
        ]
    );

    systemd.user.services = lib.mkMerge [
      (mkNamedUnits userServiceEntries)
      (lib.mkIf (cfg.gui.enable && cfg.gui.autostart) {
        # Starts hidden in the tray with every graphical session.
        proxy-suite-gui = {
          description = "Proxy Suite GUI (tray icon)";
          wantedBy = [ "graphical-session.target" ];
          partOf = [ "graphical-session.target" ];
          after = [ "graphical-session.target" ];
          unitConfig.ConditionEnvironment = [
            "|WAYLAND_DISPLAY"
            "|DISPLAY"
          ];
          serviceConfig = {
            ExecStart = "${control.proxyCtl.gui}/bin/proxy-suite-gui --hidden";
            Restart = "on-failure";
            RestartSec = 3;
          };
        };
      })
    ];

    assertions = import ../service-assertions.nix {
      inherit lib cfg derived;
      tgWsProxyCfg = cfg.tgWsProxy;
      inherit
        builtinTags
        outboundTags
        effectiveOutboundTags
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

    warnings = lib.optional (proxyEnabled && !derived.hasAvailableOutbounds) (
      "proxy-suite: no outbounds or subscriptions are declared; the proxy will not start"
      + " until one is added with `proxy-ctl proxy outbounds add`"
    );

    systemd.services = mkNamedUnits systemServiceEntries;

    systemd.timers = mkNamedUnits timerEntries;
  }
]
