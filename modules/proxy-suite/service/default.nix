# Assembles proxy-suite services from the sub-modules, as host-neutral declarations
# under services.proxy-suite.internal (see ../hosts).
{
  lib,
  pkgs,
  cfg,
  context,
}:

let
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
    tproxyLanSysctl
    perAppRoutingTun
    perAppRoutingTproxy
    userControlCfg
    userControlEnabled
    userControlAllows
    perAppZapretEnabled
    sshProxyOutboundEnabled
    sshProxyUnitEnabled
    torOutboundEnabled
    torOnionEnabled
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
  hopRedirects = lib.concatMapStrings (
    ib:
    lib.optionalString (ib.listener.type == "hysteria2" && ib.listener.hysteria.portHopping != null) ''
      fib daddr type local udp dport ${ib.listener.hysteria.portHopping} redirect to :${toString ib.listener.port}
    ''
  ) derived.proxyInbounds;
  routingScripts = import ./routing-scripts.nix { inherit (context) ctx; };

  serviceUnits = import ./units.nix {
    ctx = context.ctx // {
      inherit routingScripts;
    };
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
      inherit (constants) autoProxyStateDir runtimeDir journalctl;
      inherit userControlAllows;
    }
  );
in
lib.mkMerge [
  autoProxyUnits
  {
    services.proxy-suite.internal = {
      # The GUI's pkexec needs its setuid wrapper.
      polkit.pkexecWrapper = lib.mkIf (cfg.enable && cfg.gui.enable) true;
      # See constants.serviceUser.
      systemUsers = [ constants.serviceUser ];

      packages = [
        control.proxyCtl
      ]
      ++ lib.optional cfg.tui.enable control.proxyCtl.tui
      ++ lib.optional cfg.gui.enable control.proxyCtl.gui;

      # nftables must be on for transparent routing backends. Global TUN uses
      # SingBox auto_redirect programs an `inet sing-box` nftables table.
      nftables = lib.mkIf (
        globalTun.enable
        || globalTproxy.enable
        || perAppRoutingTun.enable
        || perAppRoutingTproxy.enable
        || perAppZapretEnabled
      ) true;

      # hysteria2 port hopping: the range lands on the listener's port before the firewall
      # sees it, so only that port needs opening.
      nftablesTables = lib.mkIf (proxyInboundsEnabled && hopRedirects != "") {
        proxy-suite-hysteria-hop = ''
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;
          ${hopRedirects}}
        '';
      };

      # Inbound listeners are reached from outside, so their ports have to be open.
      firewall = lib.mkMerge [
        (lib.mkIf (proxyInboundsEnabled && cfg.inbounds.openFirewall) {
          allowedTCPPorts = proxyInboundFirewallPorts;
          allowedUDPPorts = proxyInboundFirewallUdpPorts;
        })
        # Gateway clients' diverted packets reach input with their original destination, and
        # carry a mark whose table has no route back. Only those: the LAN is not trusted.
        (lib.mkIf (tproxyLanSysctl != { }) (
          let
            rules = lib.concatMapStrings (interface: ''
              iifname "${interface}" meta mark ${toString globalTproxy.fwmark} accept
            '') globalTproxy.lanInterfaces;
          in
          {
            extraInputRules = rules;
            extraReversePathFilterRules = rules;
          }
        ))
      ];
      sysctl = tproxyLanSysctl;

      groups = lib.mkIf (cfg.enable && (userControlEnabled || localProxyAuthEnabled)) [
        userControlCfg.group
      ];

      polkit.enable = lib.mkIf (cfg.enable && (userControlEnabled || cfg.gui.enable)) true;
      # The GUI's "Retry as Root" and root toggle run proxy-ctl through pkexec: one
      # admin password then covers the next few minutes, as sudo's does in the TUI.
      polkit.rules = lib.mkMerge [
        (lib.mkIf (cfg.enable && cfg.gui.enable) ''
          polkit.addRule(function(action, subject) {
            if (action.id === "org.freedesktop.policykit.exec" &&
                action.lookup("program") === "${control.proxyCtl}/bin/proxy-ctl") {
              return polkit.Result.AUTH_ADMIN_KEEP;
            }
            return null;
          });
        '')
        (lib.mkIf (cfg.enable && userControlEnabled) ''
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
        '')
      ];

      # Spool dirs for outbounds and subscriptions added at runtime. Setgid so the
      # files proxy-ctl drops here inherit the group; without the outbounds scope
      # only root writes them. tmpfiles rather than the start scripts, so the group can add an
      # outbound before the proxy has ever run.
      tmpfiles = lib.mkMerge [
        (lib.mkIf (cfg.enable && proxyEnabled) (
          map
            (
              dir:
              "d ${dir} ${
                if userControlAllows "outbounds" then
                  "2770 root ${userControlCfg.group}"
                else if constants.privileged then
                  "0700 root root"
                else
                  "0700 - -"
              } -"
            )
            [
              constants.runtimeOutboundsDir
              constants.runtimeSubscriptionsDir
            ]
        ))
        # Global AmneziaWG profiles added at runtime. Listable, so the tray and TUI show
        # their names to everyone; each file is 0600 (amneziawg_config.py writes it so).
        (lib.mkIf (cfg.enable && derived.awgRuntimeGlobal) [
          "d ${constants.runtimeAwgDir} ${
            if userControlAllows "amneziaWg" then "2775 root ${userControlCfg.group}" else "0755 root root"
          } -"
        ])
      ];

      userServices = lib.mkMerge [
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

      services = mkNamedUnits systemServiceEntries;

      timers = mkNamedUnits timerEntries;
    };
  }
  {
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

    warnings =
      lib.optional (proxyEnabled && !derived.hasAvailableOutbounds) (
        "proxy-suite: no outbounds or subscriptions are declared; the proxy will not start"
        + " until one is added with `proxy-ctl proxy outbounds add`"
      )
      ++
        lib.optional
          (
            proxyEnabled
            && !localProxyAuthEnabled
            && !(
              lib.hasPrefix "127." proxyCfg.listener.address
              || proxyCfg.listener.address == "::1"
              || proxyCfg.listener.address == "localhost"
            )
          )
          (
            "proxy-suite: proxy.listener.address is ${proxyCfg.listener.address} without listener.auth:"
            + " anyone who reaches the port uses your outbounds; set listener.auth, or keep it off the"
            + " firewall's allowed ports"
          )
      # rules/proxy-inbounds.nix guards the names of this host only where XRay leaves names
      # unresolved, or where IP aliases catch a name that resolves here first.
      ++
        lib.optional
          (
            proxyInboundsEnabled
            && !derived.proxyInboundsResolveInSingBox
            # Only a listener whose traffic is not direct anyway loses anything by it.
            && lib.any (
              ib:
              !builtins.elem ib.via [
                "direct"
                "block"
              ]
            ) derived.proxyInbounds
            && (cfg.inbounds.serverAddress != null || cfg.inbounds.serverAliases != [ ])
            && lib.all (a: lib.hasPrefix "domain:" a || builtins.match "[0-9.]+|.*:.*" a == null) (
              lib.optional (cfg.inbounds.serverAddress != null) cfg.inbounds.serverAddress
              ++ cfg.inbounds.serverAliases
            )
          )
          (
            "proxy-suite: with a direct listener or the XRay backend, list this host's IPs in"
            + " inbounds.serverAliases: without them a client can name this host in its TLS handshake"
            + " while connecting to any other address, which XRay then dials direct, from this host"
          );
  }

  # A certificate or key XRay cannot read is copied in at start (proxy-inbounds-scripts.nix),
  # and a copy never sees a renewal: restart the inbounds when a declared one changes.
  # ponytail: files named only inside xrayJson are not watched; declare tls.* for those.
  (
    let
      certFiles = lib.unique (
        lib.concatMap (
          l:
          lib.filter (f: f != null) [
            l.tls.certificateFile
            l.tls.keyFile
          ]
        ) (builtins.attrValues cfg.inbounds.listeners)
      );
    in
    lib.mkIf (cfg.enable && proxyInboundsEnabled && certFiles != [ ]) {
      services.proxy-suite.internal.paths.proxy-suite-inbounds-certs = {
        description = "proxy-suite - watch the inbounds' TLS certificates for renewals";
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = certFiles;
      };
      services.proxy-suite.internal.services.proxy-suite-inbounds-certs = {
        description = "proxy-suite - restart the inbounds onto a renewed certificate";
        serviceConfig.Type = "oneshot";
        script = ''
          # XRay reloads the files it reads itself; only copies go stale.
          [ -d ${constants.runtimeDir}/proxy-suite-inbounds/tls ] || exit 0
          # A renewal writes the chain and the key one after the other.
          sleep 10
          ${constants.systemctl} try-restart proxy-suite-inbounds.service
        '';
      };
    }
  )
]
