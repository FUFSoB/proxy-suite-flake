# Systemd unit definitions for proxy-suite services and timers.
{ ctx }:

let
  inherit (ctx)
    lib
    builders
    proxyCfg
    proxyEnabled
    hybridEnabled
    pureXrayEnabled
    globalTun
    globalTproxy
    killSwitchEnabled
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretEnabled
    perAppViaInterfaceOutbounds
    perAppViaRuntime
    sshProxyOutboundEnabled
    sshProxyUnitEnabled
    torOutboundEnabled
    torOnionEnabled
    whitelistBypassJoiners
    proxyInboundsEnabled
    proxyInboundsRuntimeEnabled
    proxyInboundsNeedLocalProxy
    scripts
    perAppRouting
    routingScripts
    cfg
    ;
  inherit (cfg) geodata;
  inherit (builders)
    mkAnchorService
    mkRestartingService
    mkOneshotService
    mkUserRuleService
    ;

  inherit (routingScripts)
    xrayTunUpScript
    xrayTunReloadScript
    tproxyUpScript
    tproxyReloadScript
    tproxyDownScript
    killSwitchUpScript
    killSwitchDownScript
    tunCleanupScript
    ;

  serviceNames = {
    socks = "proxy-suite-socks";
    tproxy = "proxy-suite-tproxy";
    tun = "proxy-suite-tun";
    killSwitch = "proxy-suite-killswitch";
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

  localProxyAuthEnabled = ctx.localProxy.authEnabled;
  # `apps run --via`: an "interface" AmneziaWG outbound to run through, declared or to come.
  perAppViaAwg = perAppViaInterfaceOutbounds != [ ] || perAppViaRuntime || ctx.perAppViaProfiles;
  # Or any outbound, through a pin slot: either way, the apps' slices and their marking.
  perAppViaEnabled = perAppViaAwg || perAppRouting.pinUp != { };
  # A per-app backend every user's apps share. perApp members may only start it (polkit.nix):
  # it goes once the last user's marking unit that requires it stops, or the last pin of it,
  # unless it is kept running (perAppRouting.<route>.keepRunning; the standby unit below).
  perAppSharedBackend =
    name: unit:
    restartOnSwitch (
      lib.recursiveUpdate unit {
        unitConfig.StopWhenUnneeded =
          !builtins.elem [ name ] (map (entry: entry.units) ctx.perAppKeepRunning);
      }
    );
  # Starts what is kept running, but what a global mode carrying its traffic holds down
  # (constants.refuseUnderGlobal): its stop runs this again (constants.withPerAppStandby).
  # A global AmneziaWG profile's copy for apps goes up first, waited for: the via unit reads
  # its slot as it starts, so it starts again if the copy was down.
  perAppStandbyStart =
    entry:
    let
      units = entry.units;
      last = "${lib.last units}.service";
      first = "${builtins.head units}.service";
    in
    lib.optionalString (entry.modes != [ ]) "under_global ${lib.escapeShellArgs entry.modes} || "
    + (
      if builtins.length units == 1 then
        "$systemctl start --no-block ${last}\n"
      else
        ''
          if $systemctl is-active --quiet ${first}; then
            $systemctl start --no-block ${last}
          else
            $systemctl start ${first} && $systemctl restart --no-block ${last}
          fi
        ''
    );
  perAppStandbyScript = ctx.pkgs.writeShellScript "proxy-suite-per-app" ''
    set -u
    systemctl=${ctx.constants.systemctl}
    # A global mode still stopping, maybe the one whose stop started this, is waited out.
    under_global() {
      for _ in $(${ctx.seqBin} 1 100); do
        [[ -n $($systemctl list-units --plain --no-legend --state=deactivating "$@") ]] || break
        ${ctx.sleepBin} 0.1
      done
      [[ -n $($systemctl list-units --plain --no-legend --state=active,activating,reloading "$@") ]]
    }
    # The waits last: an AmneziaWG handshake.
    ${lib.concatMapStrings perAppStandbyStart (
      builtins.sort (a: b: builtins.length a.units < builtins.length b.units) ctx.perAppKeepRunning
    )}
  '';
  # A switch restarts it rather than stopping it across activation: a shorter gap, and a
  # restart keeps the per-app holds (user-rules.nix). [Service] is where the switch reads it.
  restartOnSwitch = unit: lib.recursiveUpdate unit { serviceConfig."X-StopIfChanged" = false; };
  # Rules a firewall reload can flush, put back by `reload` (a start of the firewall: by
  # proxy-suite-firewall-reapply). After=, or the firewall's flush could come after it.
  reloadAfterFirewall =
    reload: unit:
    lib.recursiveUpdate unit {
      after = (unit.after or [ ]) ++ [ "nftables.service" ];
      serviceConfig.ExecReload = reload;
      unitConfig.ReloadPropagatedFrom = [ "nftables.service" ];
    };
  # NixOS's firewall loads the static tables itself (constants.persistedNftDir); the per-app
  # ones hold cgroup matches, which fail the firewall's whole load once the cgroup is gone.
  firewallIncludes = ctx.firewallIncludesTables;
  reloadAfterFirewallUnlessIncluded =
    reload: if firewallIncludes then lib.id else reloadAfterFirewall reload;
  # What proxy-suite-firewall-reapply reloads, as systemctl patterns.
  firewallReapplyUnits =
    lib.optionals (!firewallIncludes) (
      lib.optional killSwitchEnabled "${serviceNames.killSwitch}.service"
      ++ lib.optional (proxyEnabled || proxyInboundsEnabled) "proxy-suite-daemon-guard.service"
      ++ lib.optional (proxyEnabled && globalTproxy.enable) "${serviceNames.tproxy}.service"
      # Only XRay's TUN has a reload; sing-box's would be restarted.
      ++ lib.optional (proxyEnabled && globalTun.enable && pureXrayEnabled) "${serviceNames.tun}.service"
    )
    ++ lib.optionals (proxyEnabled && perAppRoutingTun.enable) [
      "${serviceNames.perAppTun}.service"
      "${serviceNames.perAppTun}-user@*.service"
    ]
    ++ lib.optionals (proxyEnabled && perAppRoutingTproxy.enable) [
      "${serviceNames.perAppTproxy}.service"
      "${serviceNames.perAppTproxy}-user@*.service"
    ]
    ++ lib.optional perAppViaAwg "proxy-suite-per-app-via@*.service"
    ++ map (route: "proxy-suite-per-app-via-${route}@*.service") (
      builtins.attrNames perAppRouting.pinUp
    );
  # A per-app route's DNS forwarder (nftables.nix's dns_redirect), up while the route or one
  # of its pin slots is: a listener for the route's own mark, and one for each slot's.
  perAppDnsUnit = route: "proxy-suite-per-app-${route}-dns.service";
  mkPerAppDnsForwarder =
    {
      route,
      mark,
      basePort,
      pinMarkBase,
      pins,
      bind ? [ ],
    }:
    let
      listeners = [
        "${toString basePort}:${toString mark}"
      ]
      ++ lib.genList (slot: "${toString (basePort + 1 + slot)}:${toString (pinMarkBase + slot)}") (
        if pins then ctx.perAppPinSlots else 0
      );
    in
    restartOnSwitch (mkRestartingService {
      description = "proxy-suite per-app ${route} DNS forwarder";
      execStart = lib.concatStringsSep " " (
        [
          ctx.python3
          "${ctx.proxySuiteScriptsDir}/per_app_dns.py"
        ]
        ++ map (l: "--listen ${l}") listeners
        ++ map (a: "--bind ${a}") bind
        ++ [ ctx.constants.perAppDnsUpstream ]
      );
      runtimeDirectory = "proxy-suite-per-app-${route}-dns";
      extraServiceConfig = {
        # Ready once it listens, so the route's apps' first lookup finds it.
        Type = "notify";
        NotifyAccess = "main";
        RestartSec = 2;
        DynamicUser = true;
        # SO_MARK on its sockets, and nothing else.
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallFilter = [ "@system-service" ];
        # The apps' queries on loopback, sent on to the upstream the backend answers for.
        IPAddressAllow = [
          "localhost"
          ctx.constants.perAppDnsUpstream
        ];
        IPAddressDeny = "any";
      };
    })
    // {
      unitConfig.StopWhenUnneeded = true;
    };
  # The global TUN and TProxy carry every app already: the per-app TProxy backend, its pin
  # slots and per-app zapret refuse to start under them, and go when one starts
  # (constants.refuseUnderGlobal).
  globalModeUnits = [
    "${serviceNames.tproxy}.service"
    "${serviceNames.tun}.service"
  ];
  perAppUnderGlobalModes = [
    "${serviceNames.perAppTproxy}.service"
    "proxy-suite-per-app-via-tproxy@*.service"
    "proxy-suite-per-app-via-tun@*.service"
    "${serviceNames.perAppZapret}.service"
  ];

  # For the root units reading what userControl's group writes (outbounds.d,
  # subscriptions.d): the file system read-only but for their own directories, so no
  # mistake in reading those spools can write anywhere else. Reads are untouched, secrets
  # under /root or /home included. `extra`: other paths they update.
  spoolReaderSandbox =
    extra:
    lib.optionalAttrs ctx.constants.privileged (
      {
        ProtectSystem = "strict";
      }
      # "-": the socks unit may not have made its runtime directory yet.
      // lib.optionalAttrs (extra != [ ]) { ReadWritePaths = map (path: "-${path}") extra; }
    );
  socksRuntimeDir = "${ctx.constants.runtimeDir}/${serviceNames.socks}";

  # XRay finds geoip.dat/geosite.dat through this; sing-box ignores it.
  xrayAssetEnv = lib.optionalAttrs (geodata.xray.assets != null) {
    Environment = [ "XRAY_LOCATION_ASSET=${geodata.xray.assets}/share/v2ray" ];
  };

  systemServiceEntries = [
    {
      enable = proxyEnabled;
      name = serviceNames.socks;
      # No PropagatesStopTo= TProxy: it stops TProxy on a restart too, which should hold the
      # traffic meanwhile. `proxy off` stops TProxy itself.
      value = restartOnSwitch (mkRestartingService {
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
        ++ lib.optional torOutboundEnabled "proxy-suite-tor.service"
        ++ map (j: "proxy-suite-wb-joiner-${j.tag}.service") whitelistBypassJoiners;
        wantedBy = [ "multi-user.target" ];
        # The hop login drawn as root, ahead of the start script, which ProtectSystem keeps
        # from writing /run (constants.ensureHopLogin).
        execStartPre = lib.filter (x: x != null) [
          (ctx.constants.daemonMetadataGuard ctx.pkgs)
          "+${ctx.constants.ensureHopLogin ctx.pkgs}"
        ];
        execStart = scripts.startSocks;
        runtimeDirectory = serviceNames.socks;
        stateDirectory = "proxy-suite";
        # The hybrid sidecar's config has no geo rules: only XRay as the backend reads them.
        extraServiceConfig = lib.optionalAttrs pureXrayEnabled xrayAssetEnv // spoolReaderSandbox [ ];
      });
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
        execStartPre = ctx.constants.daemonMetadataGuard ctx.pkgs;
        execStart = scripts.startInbounds;
        # inbounds.routing.serverSource's dummy interface.
        execStopPost = scripts.stopInboundsInterface;
        runtimeDirectory = serviceNames.inbounds;
        # The collector's file.
        stateDirectory = "proxy-suite";
        # While XRay still runs: what it counted since the last timer run.
        extraServiceConfig =
          xrayAssetEnv
          // {
            ExecStop = scripts.collectInboundStats;
          }
          # Nothing it runs is setuid (setpriv drops to the service user by itself), and no
          # other unit shares its temporary files.
          // lib.optionalAttrs ctx.constants.privileged {
            NoNewPrivileges = true;
            PrivateTmp = true;
            # Root parses the group-writable inbounds.d: it writes nowhere but its runtime
            # and state directories, which systemd leaves writable.
            ProtectSystem = "strict";
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            # The stats API's directory is the daemon's alone now, no setgid one to make.
            RestrictSUIDSGID = true;
          };
      };
    }
    {
      enable = proxyInboundsRuntimeEnabled;
      name = "proxy-suite-inbounds-reload";
      value = mkOneshotService {
        description = "Apply proxy-suite inbound users and listeners added at runtime";
        execStart = scripts.reloadInbounds;
        stateDirectory = "proxy-suite";
        # Root, over the spool userControl's group writes.
        extraServiceConfig = {
          RemainAfterExit = false;
        }
        // spoolReaderSandbox [ ];
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
    # Up from boot, before any network, and pulled in by every global tunnel; only proxy-ctl's
    # off verbs take it down. What the tunnels fetch to come up goes as a user it lets past.
    {
      enable = killSwitchEnabled;
      name = serviceNames.killSwitch;
      value =
        mkOneshotService {
          description = "proxy-suite kill switch - reject traffic outside the global tunnel";
          # After the firewall: its start flushes the whole ruleset on some hosts.
          after = [
            "sysinit.target"
            "nftables.service"
            "firewall.service"
          ];
          wants = [ "network-pre.target" ];
          wantedBy = [ "multi-user.target" ];
          execStart = killSwitchUpScript;
          execStop = killSwitchDownScript;
          extraServiceConfig.ExecReload = killSwitchUpScript;
        }
        # A restart runs ExecStop, which lifts the kill switch until ExecStart puts it back:
        # new rules from a switch are swapped in by a reload instead, in one transaction.
        // {
          reloadIfChanged = true;
          before = [ "network-pre.target" ];
          unitConfig = {
            # Not stopped at shutdown either, unlike the units it guards.
            DefaultDependencies = false;
          }
          # Put back after a firewall reload that flushed the ruleset (see reloadAfterFirewall).
          // lib.optionalAttrs (!firewallIncludes) {
            ReloadPropagatedFrom = [ "nftables.service" ];
          };
        };
    }
    # A start or restart of the firewall, which flushes the ruleset on some hosts, reloads
    # what reloadAfterFirewall covers; a reload does nothing to a unit that is not up.
    {
      enable = ctx.constants.privileged && firewallReapplyUnits != [ ];
      name = "proxy-suite-firewall-reapply";
      value = mkOneshotService {
        description = "proxy-suite - put its nftables tables back after the firewall starts";
        after = [ "nftables.service" ];
        wantedBy = [ "nftables.service" ];
        # --no-block: the units it reloads are ordered after nftables, whose start this is
        # part of.
        execStart = "-${ctx.constants.systemctl} try-reload-or-restart --no-block ${lib.concatStringsSep " " firewallReapplyUnits}";
        # Inactive once done, so the firewall's next start runs it again.
        extraServiceConfig.RemainAfterExit = false;
      };
    }
    # The daemon guard (constants.daemonMetadataGuard) on its own as well, so that a firewall
    # that flushed the ruleset gets it back, not only the next start of the units that load it.
    {
      enable = ctx.constants.privileged && (proxyEnabled || proxyInboundsEnabled);
      name = "proxy-suite-daemon-guard";
      value =
        let
          load = [
            (ctx.constants.daemonMetadataGuard ctx.pkgs)
          ]
          ++ lib.optional firewallIncludes "-${routingScripts.persistDaemonGuardScript}";
        in
        mkOneshotService {
          description = "proxy-suite - keep cloud metadata and the loopback hops from other users";
          after = [ "nftables.service" ];
          wantedBy = [ "multi-user.target" ];
          execStart = load;
          extraServiceConfig.ExecReload = load;
        }
        // {
          reloadIfChanged = true;
        }
        // lib.optionalAttrs (!firewallIncludes) {
          unitConfig.ReloadPropagatedFrom = [ "nftables.service" ];
        };
    }
    {
      enable = proxyEnabled && globalTproxy.enable;
      name = serviceNames.tproxy;
      # Put back with the firewall: all the host's (and the LAN's) traffic, otherwise.
      value = restartOnSwitch (
        reloadAfterFirewallUnlessIncluded tproxyReloadScript (mkOneshotService {
          description = "proxy-suite TProxy - nftables rules and policy routing";
          after = [
            "network.target"
            "${serviceNames.socks}.service"
          ];
          wantedBy = lib.optionals (proxyCfg.autostart == "tproxy") [ "multi-user.target" ];
          # Wants=, not Requires=: a restart of the backend would restart this too, and the
          # host's traffic go direct until it is back.
          wants = [
            "${serviceNames.socks}.service"
          ]
          ++ lib.optional killSwitchEnabled "${serviceNames.killSwitch}.service";
          conflicts = [ "${serviceNames.tun}.service" ];
          execStartPre = ctx.constants.stopPerAppUnits ctx.pkgs perAppUnderGlobalModes;
          execStart = tproxyUpScript;
          # Post: also after a start that failed partway, whose marking table would
          # otherwise outlive it and send marked traffic out past the kill switch.
          execStopPost = ctx.constants.withPerAppStandby "${serviceNames.tproxy}.service" tproxyDownScript;
        })
      );
    }
    {
      enable = proxyEnabled && globalTun.enable;
      name = serviceNames.tun;
      value = restartOnSwitch (
        (if pureXrayEnabled then reloadAfterFirewallUnlessIncluded xrayTunReloadScript else lib.id)
          (mkRestartingService {
            description = "${backendDescription} TUN proxy client";
            after = [ "network-online.target" ];
            wants = [
              "network-online.target"
            ]
            ++ lib.optional killSwitchEnabled "${serviceNames.killSwitch}.service";
            wantedBy = lib.optionals (proxyCfg.autostart == "tun") [ "multi-user.target" ];
            conflicts = [ "${serviceNames.tproxy}.service" ];
            execStartPre = [
              (ctx.constants.stopPerAppUnits ctx.pkgs perAppUnderGlobalModes)
              tunCleanupScript
              (ctx.constants.ensureHopLogin ctx.pkgs)
            ];
            execStart = scripts.startTun;
            execStartPost = if pureXrayEnabled then xrayTunUpScript else null;
            execStopPost = ctx.constants.withPerAppStandby "${serviceNames.tun}.service" tunCleanupScript;
            runtimeDirectory = serviceNames.tun;
            stateDirectory = "proxy-suite";
          })
      );
    }
    {
      enable = proxyEnabled && perAppRoutingTun.enable;
      name = serviceNames.perAppTun;
      value = reloadAfterFirewall perAppRouting.perAppTunReloadScript (
        perAppSharedBackend serviceNames.perAppTun (mkRestartingService {
          description = "proxy-suite per-app-routing TUN backend";
          after = [
            "network-online.target"
            (perAppDnsUnit "tun")
          ];
          wants = [
            "network-online.target"
            (perAppDnsUnit "tun")
          ];
          execStartPre = [
            perAppRouting.perAppTunDownScript
            (ctx.constants.ensureHopLogin ctx.pkgs)
          ];
          execStart = scripts.startPerAppTun;
          execStartPost = perAppRouting.perAppTunUpScript;
          execStopPost = perAppRouting.perAppTunDownScript;
          runtimeDirectory = serviceNames.perAppTun;
          stateDirectory = "proxy-suite";
        })
      );
    }
    {
      enable = proxyEnabled && perAppRoutingTun.enable;
      name = "${serviceNames.perAppTun}-user@";
      # Its rules back in after the backend's table, and the hold's, came back (After=).
      value = reloadAfterFirewall "${perAppRouting.perAppTunUserRuleStart} %i" (mkUserRuleService {
        description = "Enable proxy-suite app TUN marking for user %i";
        backendService = serviceNames.perAppTun;
        execStart = "${perAppRouting.perAppTunUserRuleStart} %i";
        execStop = "${perAppRouting.perAppTunUserRuleStop} %i";
      });
    }
    {
      enable = proxyEnabled && perAppRoutingTproxy.enable;
      name = serviceNames.perAppTproxy;
      value = reloadAfterFirewall perAppRouting.perAppTproxyReloadScript (
        perAppSharedBackend serviceNames.perAppTproxy (mkOneshotService {
          description = "proxy-suite per-app-routing TProxy backend";
          after = [
            "network.target"
            "${serviceNames.socks}.service"
            (perAppDnsUnit "tproxy")
          ];
          requires = [ "${serviceNames.socks}.service" ];
          wants = [ (perAppDnsUnit "tproxy") ];
          execStartPre = ctx.constants.refuseUnderGlobal ctx.pkgs globalModeUnits;
          execStart = perAppRouting.perAppTproxyUpScript;
          # Post: after a start that failed partway too (see the global TProxy unit).
          execStopPost = perAppRouting.perAppTproxyDownScript;
        })
      );
    }
    {
      enable = proxyEnabled && perAppRoutingTun.enable;
      name = "proxy-suite-per-app-tun-dns";
      value = mkPerAppDnsForwarder {
        route = "tun";
        mark = perAppRoutingTun.fwmark;
        basePort = ctx.constants.perAppTunDnsBasePort;
        pinMarkBase = ctx.constants.perAppPinTunFwmarkBase;
        pins = ctx.perAppPinTun;
      };
    }
    {
      enable = proxyEnabled && perAppRoutingTproxy.enable;
      name = "proxy-suite-per-app-tproxy-dns";
      value = mkPerAppDnsForwarder {
        route = "tproxy";
        mark = perAppRoutingTproxy.fwmark;
        basePort = ctx.constants.perAppTproxyDnsBasePort;
        pinMarkBase = ctx.constants.perAppPinTproxyFwmarkBase;
        pins = ctx.perAppPinTproxy;
        # The mark takes the queries to a local route (see per_app_dns.py's BIND).
        bind = [ "127.0.0.1" ];
      };
    }
    {
      enable = proxyEnabled && perAppRoutingTproxy.enable;
      name = "${serviceNames.perAppTproxy}-user@";
      # Its rules back in after the backend's table, and the hold's, came back (After=).
      value = reloadAfterFirewall "${perAppRouting.perAppTproxyUserRuleStart} %i" (mkUserRuleService {
        description = "Enable proxy-suite app TProxy marking for user %i";
        backendService = serviceNames.perAppTproxy;
        execStart = "${perAppRouting.perAppTproxyUserRuleStart} %i";
        execStop = "${perAppRouting.perAppTproxyUserRuleStop} %i";
      });
    }
    # Declared with zapret's own units (zapret.nix, zapret2.nix).
    {
      enable = perAppZapretEnabled;
      name = serviceNames.perAppZapret;
      value = perAppSharedBackend serviceNames.perAppZapret { };
    }
    {
      enable = ctx.perAppKeepRunning != [ ];
      name = "proxy-suite-per-app-standby";
      value = mkOneshotService {
        description = "Start the proxy-suite per-app backends kept running";
        # After the global modes: one starting at boot is up by then, and the stop of one that
        # started this is over. A template's instances are waited out by the script.
        after = builtins.filter (unit: !lib.hasInfix "*" unit) ctx.perAppStandbyGlobalModes;
        wantedBy = [ "multi-user.target" ];
        execStart = perAppStandbyScript;
        # Run again by each global mode's stop.
        extraServiceConfig.RemainAfterExit = false;
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
    # `apps run --via <tag>`: an instance per outbound, up while anyone runs through it: its
    # rules, and the forwarder its apps' lookups go to. Each user's apps in its slice are
    # marked by the next unit (<uid>-<instance>).
    {
      enable = perAppViaAwg;
      name = "proxy-suite-per-app-via@";
      # Its table, rules and users' rules back after a firewall reload that flushed them.
      value = restartOnSwitch (
        reloadAfterFirewall
          [
            "${perAppRouting.viaUp} %i"
            "${perAppRouting.viaReapply} %i"
          ]
          (mkRestartingService {
            description = "proxy-suite per-app routing via %i";
            execStartPre = "${perAppRouting.viaUp} %i";
            execStart = "${perAppRouting.viaDns} %i";
            # viaUp starts the table empty: after a restart, the users' rules go back in.
            execStartPost = "${perAppRouting.viaReapply} %i";
            execStopPost = "${perAppRouting.viaDown} %i";
            runtimeDirectory = "proxy-suite-per-app-via-%i";
            extraServiceConfig = {
              # Ready once the forwarder listens, so the app's first lookup finds it.
              Type = "notify";
              NotifyAccess = "main";
              RestartSec = 2;
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              ProtectClock = true;
              ProtectHostname = true;
              ProtectKernelLogs = true;
              # Root still, though with one capability: the disks' device nodes, /proc/sys and
              # cgroups are root's to write without any, and the forwarder answers apps.
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
              # nft and ip rules, and SO_MARK on the forwarder's sockets.
              CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
              # Netlink for nft and ip, unix for the readiness notice, IP for the forwarder.
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
                "AF_NETLINK"
              ];
            };
          })
      );
    }
  ]
  # `apps run --via <tag>` for any other outbound: a pin slot of per-app TProxy or TUN for
  # each outbound apps run through. Part of the backend whose selector it switches: a
  # restart of that switches it again.
  ++ map (route: {
    enable = true;
    name = "proxy-suite-per-app-via-${route}@";
    value =
      let
        backend = perAppRouting.pinRoutes.${route}.backend;
      in
      # Its table and its users' rules back after a firewall reload that flushed them. The
      # users' holds keep their apps in while it rebuilds.
      restartOnSwitch (
        reloadAfterFirewall
          [
            "${perAppRouting.pinUp.${route}} %i"
            "${perAppRouting.viaReapply} ${route}-%i"
          ]
          (
            mkOneshotService {
              description = "proxy-suite per-app ${route} pin for the outbound %i (in hex)";
              execStart = "${perAppRouting.pinUp.${route}} %i";
              execStartPost = "${perAppRouting.viaReapply} ${route}-%i";
              execStop = "${perAppRouting.pinDown.${route}} %i";
              after = [
                backend
                (perAppDnsUnit route)
              ];
              requires = [ backend ];
              wants = [ (perAppDnsUnit route) ];
              # As per-app TProxy: under a global mode, proxy-ctl runs the app without its route.
              execStartPre = ctx.constants.refuseUnderGlobal ctx.pkgs globalModeUnits;
            }
            // {
              partOf = [ backend ];
            }
          )
      );
  }) (builtins.attrNames perAppRouting.pinUp)
  ++ [
    {
      enable = perAppViaEnabled;
      name = "proxy-suite-per-app-via-user@";
      value = mkOneshotService {
        description = "Enable proxy-suite per-app via marking for %i";
        execStart = "${perAppRouting.viaUserStart} %i";
        execStop = "${perAppRouting.viaUserStop} %i";
        # No unit names the via unit from <uid>-<key>, so no Requires= can hold it for
        # StopWhenUnneeded=: the last user's unit takes it down itself.
        execStopPost = "${perAppRouting.viaRetire} %i";
        # A switch's stop would take the via unit down under the running apps; a new via
        # unit puts the rules back itself (viaReapply). In [Service], where the switch reads it.
        extraServiceConfig.X-RestartIfChanged = false;
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
        extraServiceConfig = {
          RemainAfterExit = false;
        }
        // spoolReaderSandbox [ ];
      };
    }
    {
      enable = proxyEnabled;
      name = "proxy-suite-route-mode@";
      value = mkOneshotService {
        description = "Set proxy-suite route mode to %i";
        execStart = "${scripts.setRouteModeScript} %i";
        # Root, started by userControl's group: it writes the mode file and restarts the
        # proxy, nothing else.
        extraServiceConfig = {
          RemainAfterExit = false;
        }
        // spoolReaderSandbox [ ]
        // lib.optionalAttrs ctx.constants.privileged {
          # Where the mode file lives, which nothing else makes: kept between runs, and
          # writable under ProtectSystem, whether or not it exists yet.
          RuntimeDirectory = "proxy-suite";
          RuntimeDirectoryPreserve = "yes";
          NoNewPrivileges = true;
          PrivateTmp = true;
        };
      };
    }
    {
      enable = proxyEnabled;
      name = "proxy-suite-routing-apply";
      value = mkOneshotService {
        description = "Apply proxy-suite routing rules added at runtime";
        execStart = scripts.applyRoutingScript;
        # Root, over the spool the routing scope writes: it renders the rules into the state
        # directory and restarts the backends whose config they change.
        stateDirectory = "proxy-suite";
        extraServiceConfig = {
          RemainAfterExit = false;
        }
        // spoolReaderSandbox [ ];
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
        # It updates the pin in the running proxy's inventory.
        extraServiceConfig = {
          RemainAfterExit = false;
        }
        // spoolReaderSandbox [ socksRuntimeDir ];
      };
    }
    {
      enable = proxyEnabled;
      name = "proxy-suite-outbound-unpin";
      value = mkOneshotService {
        description = "Unpin the proxy-suite outbound";
        execStart = "${scripts.pinOutboundScript}";
        stateDirectory = "proxy-suite";
        extraServiceConfig = {
          RemainAfterExit = false;
        }
        // spoolReaderSandbox [ socksRuntimeDir ];
      };
    }
    {
      enable = proxyEnabled;
      name = "proxy-suite-outbound-reload";
      value = mkOneshotService {
        description = "Apply proxy-suite outbounds and subscriptions added at runtime";
        execStart = scripts.reloadOutboundsScript;
        stateDirectory = "proxy-suite";
        extraServiceConfig = {
          RemainAfterExit = false;
        }
        // spoolReaderSandbox [ ];
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
    {
      enable = perAppViaEnabled;
      name = "proxy-suite-per-app-via-anchor@";
      value = mkAnchorService "proxy-suite-per-app-via-%i.slice" "Anchor service for the proxy-suite per-app via %i slice";
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
    localProxyAuthEnabled
    systemServiceEntries
    userServiceEntries
    timerEntries
    ;
}
