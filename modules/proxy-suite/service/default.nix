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

  # A spool directory the groups holding `scope` write to. userControl.group owns it; with
  # only userControl.groups holding the scope, root does, and they get it through ACLs
  # (proxy-suite-acls), which the group bits must leave open: they are the ACL mask.
  spoolDirMode =
    scope:
    if userControlAllows scope then
      "2770 root ${userControlCfg.group}"
    else if derived.userControlAnyAllows scope then
      "2770 root root"
    else if constants.privileged then
      "0700 root root"
    else
      "0700 - -";

  # What proxy-suite-acls opens to userControl.groups: the spools made by tmpfiles, which no
  # unit of their own sets up.
  aclSpools =
    lib.optionals proxyEnabled [
      {
        path = constants.runtimeOutboundsDir;
        scope = "outbounds";
      }
      {
        path = constants.runtimeSubscriptionsDir;
        scope = "outbounds";
      }
    ]
    ++ lib.optional derived.proxyInboundsRuntimeEnabled {
      path = constants.runtimeInboundsDir;
      scope = "inbounds";
    }
    ++ lib.optional derived.awgRuntimeGlobal {
      path = constants.runtimeAwgDir;
      scope = "amneziaWg";
    }
    ++ lib.optional cfg.perAppRouting.enable {
      path = constants.runtimeAppsDir;
      scope = "perApp";
    }
    ++ lib.optional proxyEnabled {
      path = constants.runtimeRoutingDir;
      scope = "routing";
    }
    ++ lib.optional derived.zapretCutoffEnabled {
      path = "${constants.zapret2CutoffDir}/requests";
      scope = "zapret";
    }
    ++ lib.optional cfg.whitelistBypass.enable {
      path = "${constants.stateDir}/whitelist-bypass";
      scope = "whitelistBypass";
    }
    ++ lib.optional cfg.proxy.autoProxy.enable {
      path = constants.autoProxySpoolDir;
      scope = "autoProxy";
    };

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
      inherit (constants)
        autoProxyStateDir
        autoProxySpoolDir
        runtimeDir
        journalctl
        ;
      inherit userControlAllows;
    }
  );
  # `proxy-ctl proxy groups watch`: failover groups and "failover" selection, through the Clash API.
  outboundGroupsUnit = lib.mkIf derived.outboundGroupsWatch {
    services.proxy-suite.internal.services.proxy-suite-outbound-groups = {
      description = "proxy-suite - move failover groups off outbounds that stop working";
      after = [ "proxy-suite-socks.service" ];
      bindsTo = [ "proxy-suite-socks.service" ];
      wantedBy = [ "proxy-suite-socks.service" ];
      serviceConfig = {
        ExecStart = "${control.proxyCtl}/bin/proxy-ctl proxy groups watch";
        Restart = "on-failure";
        RestartSec = 5;
        # health/ takes hints from watchdogs; groups-state.json is for the front ends.
        RuntimeDirectory = "proxy-suite-outbound-groups";
        RuntimeDirectoryMode = "0755";
      }
      // lib.optionalAttrs cfg.host.privileged {
        # health/ is the watchdogs' (root's and the service user's) to write to, not every
        # local user's. Made here, with the capabilities the watcher lacks.
        ExecStartPre = "+${pkgs.coreutils}/bin/install -d -m 1730 -o root -g ${constants.serviceUser} ${constants.runtimeDir}/proxy-suite-outbound-groups/health";
      }
      // {
        NoNewPrivileges = true;
        PrivateTmp = true;
        # Root without capabilities still owns the disks' device nodes.
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = [ "" ];
      };
    };
  };

  # The Clash API's secret is root's: members of the userControl groups reach the API through
  # this, and only for what their scopes cover (proxy_ctl.py, _broker_allows).
  clashBrokerUnit = lib.mkIf (cfg.enable && derived.clashBrokerEnabled) {
    services.proxy-suite.internal.services.proxy-suite-clash-api = {
      description = "proxy-suite - the Clash API for userControl's groups, as their scopes allow";
      after = [ "proxy-suite-socks.service" ];
      bindsTo = [ "proxy-suite-socks.service" ];
      wantedBy = [ "proxy-suite-socks.service" ];
      serviceConfig = {
        ExecStart = "${control.proxyCtl}/bin/proxy-ctl proxy clash-broker";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "proxy-suite-clash";
        RuntimeDirectoryMode = "0755";
        # Root for the secret's sake (its file is root's), with no capability at all.
        CapabilityBoundingSet = [ "" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        # Root without capabilities still owns the disks' device nodes.
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        # The API is on loopback; nothing else to reach.
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = [ "any" ];
      };
    };
  };

  # userControl.groups cannot own the spools the way userControl.group does: POSIX ACLs let
  # them in, set again on every boot and whenever the groups change (a changed unit
  # restarts), so a group dropped from the configuration loses what it had. With
  # userControl off too: it then only takes away what an earlier configuration granted.
  aclUnit = lib.mkIf (cfg.enable && constants.privileged && aclSpools != [ ]) {
    services.proxy-suite.internal.services.proxy-suite-acls = {
      description = "proxy-suite - give userControl.groups their access to the runtime spools";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      script = lib.concatMapStrings (
        spool:
        constants.grantDirAcl pkgs (lib.escapeShellArg spool.path)
          (derived.userControlExtraGroupsFor spool.scope)
          "rwX"
      ) aclSpools;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # It walks directories the groups write to: whatever a name there comes to point
        # at, nothing but the spools can change.
        ProtectSystem = "strict";
        ReadWritePaths = map (spool: "-${spool.path}") aclSpools;
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [
          "CAP_FOWNER"
          "CAP_DAC_OVERRIDE"
          "CAP_DAC_READ_SEARCH"
        ];
      };
    };
  };
in
lib.mkMerge [
  autoProxyUnits
  outboundGroupsUnit
  clashBrokerUnit
  aclUnit
  {
    services.proxy-suite.internal = {
      # The GUI's pkexec needs its setuid wrapper.
      polkit.pkexecWrapper = lib.mkIf (cfg.enable && cfg.gui.enable) true;
      # See constants.serviceUser; and the subscription fetcher's (subscriptions.nix).
      systemUsers =
        constants.ownTrafficUsers
        ++ lib.optional (constants.privileged && proxyEnabled) context.ctx.subscriptionFetchUser;

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
          allowedTCPPorts = proxyInboundFirewallPorts ++ derived.proxyInboundRuntimeSinglePorts;
          allowedUDPPorts = proxyInboundFirewallUdpPorts ++ derived.proxyInboundRuntimeSinglePorts;
        })
        # Only the NixOS adapter forwards ranges.
        (lib.mkIf
          (proxyInboundsEnabled && cfg.inbounds.openFirewall && derived.proxyInboundRuntimePortRanges != [ ])
          {
            allowedTCPPortRanges = derived.proxyInboundRuntimePortRanges;
            allowedUDPPortRanges = derived.proxyInboundRuntimePortRanges;
          }
        )
        # Gateway clients' diverted packets reach input with their original destination, and
        # carry a mark whose table has no route back. Only those: the LAN is not trusted.
        (lib.mkIf (tproxyLanSysctl != { }) (
          let
            rules =
              extra:
              lib.concatMapStrings (interface: ''
                iifname "${interface}" meta mark ${toString globalTproxy.fwmark}${extra} accept
              '') globalTproxy.lanInterfaces;
          in
          {
            # Into the backend's transparent socket alone: while it restarts, the mark would
            # otherwise let a gateway client into any of this host's own listeners.
            extraInputRules = rules " socket transparent 1";
            extraReversePathFilterRules = rules "";
          }
        ))
      ];
      sysctl = tproxyLanSysctl;

      groups = lib.mkIf (cfg.enable && (userControlEnabled || localProxyAuthEnabled)) (
        [ userControlCfg.group ] ++ derived.userControlExtraGroups
      );

      polkit.enable = lib.mkIf (cfg.enable && (userControlEnabled || cfg.gui.enable)) true;
      # The GUI's "Retry as Root" runs proxy-ctl through pkexec (polkit.nix), by the path
      # proxy_model.elevated uses.
      polkit.actions = lib.mkIf (cfg.enable && cfg.gui.enable) {
        "${polkit.proxyCtlActionId}.policy" = polkit.mkProxyCtlAction "${control.proxyCtl}/bin/proxy-ctl";
      };
      polkit.rules = lib.mkMerge [
        (lib.mkIf (cfg.enable && userControlEnabled) ''
          polkit.addRule(function(action, subject) {
            if (!(${polkit.userControlPolkitMember})) {
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
          map (dir: "d ${dir} ${spoolDirMode "outbounds"} -") [
            constants.runtimeOutboundsDir
            constants.runtimeSubscriptionsDir
          ]
        ))
        # Routing rules added at runtime (`proxy rules`): the routing scope's. Nothing secret
        # in them, but root renders what is there into every backend's route.
        (lib.mkIf (cfg.enable && proxyEnabled) [
          "d ${constants.runtimeRoutingDir} ${spoolDirMode "routing"} -"
        ])
        # inbounds.runtime: the users' and listeners' files hold their secrets, so the dir is
        # as closed as outbounds.d, and group-writable only with the inbounds scope.
        (lib.mkIf (cfg.enable && derived.proxyInboundsRuntimeEnabled) (
          map (dir: "d ${dir} ${spoolDirMode "inbounds"} -") [
            constants.runtimeInboundsDir
            "${constants.runtimeInboundsDir}/users"
            "${constants.runtimeInboundsDir}/listeners"
          ]
        ))
        # inbound_runtime.py's lock, outside the spool the members write to; it opens it
        # read-only and never makes it, so it must be here first.
        (lib.mkIf (cfg.enable && derived.proxyInboundsRuntimeEnabled && constants.privileged) (
          [
            "f ${constants.runtimeInboundsLock} 0640 root ${
              if userControlAllows "inbounds" then userControlCfg.group else "root"
            } -"
          ]
          ++ map (g: "a+ ${constants.runtimeInboundsLock} - - - - g:${g}:r") (
            derived.userControlExtraGroupsFor "inbounds"
          )
        ))
        # Per-app profiles added at runtime: read by everyone who runs apps, written with the
        # perApp scope.
        (lib.mkIf (cfg.enable && cfg.perAppRouting.enable) [
          "d ${constants.runtimeAppsDir} ${
            if !constants.privileged then
              "0700 - -"
            else if userControlAllows "perApp" then
              "2775 root ${userControlCfg.group}"
            else if derived.userControlAnyAllows "perApp" then
              "2775 root root"
            else
              "0755 root root"
          } -"
        ])
        # Global AmneziaWG profiles added at runtime. Listable, so the tray and TUI show
        # their names to everyone; each file is 0600 (amneziawg_config.py writes it so).
        (lib.mkIf (cfg.enable && derived.awgRuntimeGlobal) [
          "d ${constants.runtimeAwgDir} ${
            if userControlAllows "amneziaWg" then
              "2775 root ${userControlCfg.group}"
            else if derived.userControlAnyAllows "amneziaWg" then
              "2775 root root"
            else
              "0755 root root"
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
      # On Android every app reaches loopback: one that finds the proxy there learns its exit,
      # or tells whoever asks that this phone runs one.
      ++ lib.optional (cfg.host.kind == "nix-on-droid" && proxyEnabled && !localProxyAuthEnabled) (
        "proxy-suite: proxy.listener takes no login, and on Android every app can use it;"
        + " set proxy.listener.auth"
      )
      # Tor's SOCKS port and OpenSSH's -D take no login: without the nftables guard
      # (constants.daemonMetadataGuard), every local user reaches those exits.
      ++
        lib.optional
          (
            !constants.privileged
            && (
              derived.torOutboundEnabled || (derived.sshProxyOutboundEnabled && !derived.sshProxyNativeOutbound)
            )
          )
          (
            "proxy-suite: without root, nothing keeps other local users (on Android, other apps) off"
            + " the loopback SOCKS ports of ${
               lib.concatStringsSep " and " (
                 lib.optional derived.torOutboundEnabled "Tor (tor.socksPort)"
                 ++ lib.optional (
                   derived.sshProxyOutboundEnabled && !derived.sshProxyNativeOutbound
                 ) "the OpenSSH tunnel (sshProxy.listener.port)"
               )
             }: neither takes a login. sing-box dials SSH natively, with no listener"
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
      # OpenSSH's -D takes no login at all.
      ++
        lib.optional
          (
            cfg.sshProxy.enable
            && !(
              lib.hasPrefix "127." cfg.sshProxy.listener.address
              || cfg.sshProxy.listener.address == "::1"
              || cfg.sshProxy.listener.address == "localhost"
            )
          )
          (
            "proxy-suite: sshProxy.listener.address is ${cfg.sshProxy.listener.address}: its SOCKS port takes"
            + " no login, so anyone who reaches it uses the SSH server; keep it on loopback, or off the"
            + " firewall's allowed ports"
          )
      ++
        lib.optional
          (
            cfg.warp.enable && cfg.warp.generatorUrl != null && !lib.hasPrefix "https://" cfg.warp.generatorUrl
          )
          (
            "proxy-suite: warp.generatorUrl is not https://: anyone on the way can hand back a profile"
            + " of their own, and the WARP traffic goes to them"
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
