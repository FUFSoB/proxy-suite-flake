# Native AmneziaWG client profile services.
{
  config,
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  awgCfg = cfg.amneziaWg;
  profiles = awgCfg.profiles;
  profileNames = builtins.attrNames profiles;
  globalProfileNames = builtins.attrNames derived.awgGlobalProfiles;
  singBoxOutbounds = builtins.filter (ob: ob.kind == "singBox") derived.awgOutbounds;
  serviceName = name: "proxy-suite-awg-${name}";
  globalServiceNames = map serviceName globalProfileNames;
  allProfileConflicts =
    name:
    map (other: "${serviceName other}.service") (
      builtins.filter (other: other != name) globalProfileNames
    );
  inherit (import ./wg-tunnel.nix { inherit lib pkgs cfg derived; }) mkTunnel;
  sourceCount =
    profile:
    builtins.length (
      builtins.filter (value: value != null) [
        profile.configFile
        profile.vpnFile
        profile.vpn
        profile.settings
      ]
    );
  source =
    profile:
    if profile.configFile != null then
      {
        kind = "configFile";
        path = profile.configFile;
      }
    else if profile.vpnFile != null then
      {
        kind = "vpnFile";
        path = profile.vpnFile;
      }
    else if profile.vpn != null then
      {
        kind = "vpn";
        path = pkgs.writeText "proxy-suite-awg" profile.vpn;
      }
    else
      {
        kind = "settings";
        inherit (profile) settings;
      };
  manifestFor =
    profile:
    pkgs.writeText "proxy-suite-awg" (
      builtins.toJSON (
        {
          allowConfigHooks = profile.allowConfigHooks;
          vpnContainer = profile.vpnContainer;
        }
        // source profile
      )
    );
  configTool = "${
    builtins.path {
      name = "proxy-suite-scripts";
      path = ../../scripts;
    }
  }/amneziawg_config.py";
  runtimeDir = name: "/run/${serviceName name}";
  runtimeConfig = name: profile: "${runtimeDir name}/${profile.interfaceName}.conf";
  # Keep proxy backend sockets (proxyMark) out of AWG's default-route table.
  proxyBypassRulePriority = 8998;
  bypassRule =
    family: action:
    "${pkgs.iproute2}/bin/ip ${family} rule ${action} pref ${toString proxyBypassRulePriority} fwmark ${toString cfg.proxy.tproxy.proxyMark} lookup main";
  clearBypassRules = lib.concatMapStrings (family: ''
    while ${bypassRule family "del"} 2>/dev/null; do :; done
  '') [ "-4" "-6" ];

  # Some lines drop a share of fresh flows for good, handshakes included. A new source port
  # is a new flow, and moving the interface to one keeps its routes, so traffic never leaks
  # past the tunnel while it tries again. A pinned ListenPort is left alone.
  mkHandshakeHelpers = profile: ''
    awg=${awgCfg.toolsPackage}/bin/awg
    interface=${lib.escapeShellArg profile.interfaceName}

    # Seconds since the newest handshake of any peer; a large number before the first.
    handshake_age() {
      local latest
      latest=$("$awg" show "$interface" latest-handshakes 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '$2 > max { max = $2 } END { print max + 0 }')
      if (( latest == 0 )); then echo 1000000; else echo $(( $(${pkgs.coreutils}/bin/date +%s) - latest )); fi
    }

    new_source_port() {
      ${
        if profile.settings != null && profile.settings.listenPort != null then
          ":"
        else
          ''"$awg" set "$interface" listen-port 0 || true''
      }
    }
  '';

  # `ping` for the handshake probe. An outbound interface has no route to the probe address, so
  # the probe is bound to it.
  pingVia =
    profile:
    "${pkgs.iputils}/bin/ping -n -c 1"
    + lib.optionalString (profile.asOutbound == "interface") " -I ${lib.escapeShellArg profile.interfaceName}";

  # An outbound interface keeps the host's routes and resolver, and marks its packets so TUN and
  # TProxy let them past.
  prepareCommand = profile: output: ''
    ${pkgs.python3}/bin/python3 ${configTool} \
      --manifest ${lib.escapeShellArg (toString (manifestFor profile))} \
      --output ${output}${
        lib.optionalString (profile.asOutbound == "interface") " --outbound-fwmark ${toString cfg.proxy.tproxy.proxyMark}"
      }
  '';

  mkService =
    name: profile:
    let
      outbound = profile.asOutbound == "interface";
      configPath = runtimeConfig name profile;
      prepare = pkgs.writeShellScript "proxy-suite-awg" ''
        set -euo pipefail
        ${prepareCommand profile (lib.escapeShellArg configPath)}
      '';
      proxyBypassUp = pkgs.writeShellScript "proxy-suite-awg" ''
        set -euo pipefail
        ${clearBypassRules}
        # IPv4 is required, or the proxy backend is captured by AWG; IPv6 is best-effort.
        if ! ${bypassRule "-4" "add"} 2>/dev/null; then
          echo "proxy-suite: unable to install the AWG proxy-backend bypass rule" >&2
          exit 1
        fi
        ${bypassRule "-6" "add"} 2>/dev/null || true
      '';
      proxyBypassDown = pkgs.writeShellScript "proxy-suite-awg" ''
        set +e
        ${clearBypassRules}
      '';
      start = pkgs.writeShellScript "proxy-suite-awg" ''
        set -Eeuo pipefail

        cleanup() {
          set +e
          ${awgCfg.toolsPackage}/bin/awg-quick down ${lib.escapeShellArg configPath}

          # Without the control socket awg-quick cannot find its fwmark; clean up this
          # interface only.
          for family in -4 -6; do
            had_table=0
            for table in $(${pkgs.iproute2}/bin/ip "$family" route show table all 2>/dev/null \
              | ${pkgs.gawk}/bin/awk '$1 == "default" && $2 == "dev" && $3 == "${profile.interfaceName}" { for (i = 1; i <= NF; i++) if ($i == "table") print $(i + 1) }'); do
              had_table=1
              while ${pkgs.iproute2}/bin/ip "$family" rule delete table "$table" 2>/dev/null; do :; done
              ${pkgs.iproute2}/bin/ip "$family" route flush table "$table" 2>/dev/null || true
            done
            if (( had_table )); then
              ${pkgs.iproute2}/bin/ip "$family" rule delete table main suppress_prefixlength 0 2>/dev/null || true
            fi
          done
          if command -v nft >/dev/null; then
            nft list tables 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -F " wg-quick-${profile.interfaceName}" \
              | while read -r _ family table; do nft delete table "$family" "$table" 2>/dev/null || true; done
          fi
          ${config.networking.resolvconf.package}/bin/resolvconf -d "${profile.interfaceName}" -f 2>/dev/null || true
          ${pkgs.iproute2}/bin/ip link delete dev ${lib.escapeShellArg profile.interfaceName} 2>/dev/null || true
        }
        trap cleanup ERR

        ${lib.optionalString (awgCfg.kernelModulePackage != null) ''
          ${pkgs.kmod}/bin/modprobe amneziawg 2>/dev/null || true
        ''}

        read -r implementation probe _ < <(${pkgs.python3}/bin/python3 ${configTool} \
          --inspect ${lib.escapeShellArg configPath})
        # The 3.1 kernel module dropped RandomTrailers packets with ranged H1-H3 (seen on 20260812);
        # userspace carries the fix.
        if [[ "$implementation" == userspace ]]; then
          WG_QUICK_FORCE_USERSPACE_IMPLEMENTATION=1 \
            WG_QUICK_USERSPACE_IMPLEMENTATION=${awgCfg.userspacePackage}/bin/amneziawg-go \
            ${awgCfg.toolsPackage}/bin/awg-quick up ${lib.escapeShellArg configPath}
        else
          WG_QUICK_USERSPACE_IMPLEMENTATION=${awgCfg.userspacePackage}/bin/amneziawg-go \
            ${awgCfg.toolsPackage}/bin/awg-quick up ${lib.escapeShellArg configPath}
        fi

        ${mkHandshakeHelpers profile}
        # A handshake is retried every 5 seconds: each retry after the first gets a new port.
        for attempt in $(${pkgs.coreutils}/bin/seq 1 20); do
          ${pingVia profile} -W 1 "$probe" >/dev/null 2>&1 || true
          if (( $(handshake_age) < 1000000 )); then
            trap - ERR
            exit 0
          fi
          if (( attempt % 5 == 0 )); then
            new_source_port
          fi
        done

        echo "proxy-suite: AmneziaWG profile '${name}' did not complete a handshake; rolling back routes" >&2
        false
      '';
      stop = pkgs.writeShellScript "proxy-suite-awg" ''
        set -euo pipefail
        exec ${awgCfg.toolsPackage}/bin/awg-quick down ${lib.escapeShellArg configPath}
      '';
    in
    (
      if outbound then
        {
          description = "proxy-suite AmneziaWG interface behind the ${name} outbound";
          # Nothing waits for it: a slow handshake must not hold up the proxy.
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          startLimitIntervalSec = 0;
        }
      else
        {
          description = "proxy-suite AmneziaWG client profile ${name}";
          # Start the local proxy before AWG takes the default route, so HTTP_PROXY clients
          # do not race it.
          after = [
            "network-online.target"
            "proxy-suite-zapret.service"
          ]
          ++ lib.optional cfg.proxy.enable "proxy-suite-socks.service";
          wants = [ "network-online.target" ] ++ lib.optional cfg.proxy.enable "proxy-suite-socks.service";
          wantedBy = lib.optionals profile.autostart [ "multi-user.target" ];
          conflicts = allProfileConflicts name ++ [
            "proxy-suite-tun.service"
            "proxy-suite-tproxy.service"
            "proxy-suite-zapret.service"
            "proxy-suite-per-app-zapret.service"
            "proxy-suite-zapret-vm-exempt.service"
          ];
        }
    )
    // {
      path = [
        awgCfg.toolsPackage
        awgCfg.userspacePackage
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.iproute2
        pkgs.iputils
        pkgs.kmod
        config.networking.firewall.package
        config.networking.resolvconf.package
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = serviceName name;
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        NoNewPrivileges = true;
        LockPersonality = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        ExecStartPre = [ prepare ] ++ lib.optionals (cfg.proxy.enable && !outbound) [ proxyBypassUp ];
        ExecStart = start;
        ExecStop = stop;
      }
      // lib.optionalAttrs (cfg.proxy.enable && !outbound) {
        ExecStopPost = proxyBypassDown;
      }
      # A failed handshake leaves no routes behind here, so try again later.
      // lib.optionalAttrs outbound {
        Restart = "on-failure";
        RestartSec = 30;
      };
    };

  mkSingBoxService =
    ob:
    let
      profile = profiles.${ob.name};
    in
    mkTunnel {
      description = "proxy-suite AmneziaWG tunnel behind the ${ob.name} outbound";
      unit = serviceName ob.name;
      inherit (ob) tag tunnelPort directPort;
      profile = ''
        profile="$RUNTIME_DIRECTORY/profile.conf"
        ${prepareCommand profile ''"$profile"''}
      '';
    };

  # Runs alongside a started profile. Its pings keep traffic flowing, and traffic makes
  # WireGuard rekey every RekeyAfterTime (120 seconds by default); a handshake older than that
  # on two checks in a row is a rekey that is not getting through, so the interface moves to
  # a new port.
  mkWatchdog =
    name: profile:
    let
      watchdog = pkgs.writeShellScript "proxy-suite-awg" ''
        set -uo pipefail
        read -r _ probe rekey < <(${pkgs.python3}/bin/python3 ${configTool} \
          --inspect ${lib.escapeShellArg (runtimeConfig name profile)}) || exit 1
        if (( rekey == 0 )); then
          echo "proxy-suite: AmneziaWG profile '${name}' never rekeys; nothing to watch" >&2
          exec ${pkgs.coreutils}/bin/sleep infinity
        fi
        ${mkHandshakeHelpers profile}
        stale=0
        while sleep 15; do
          ${pingVia profile} -W 2 "$probe" >/dev/null 2>&1 || true
          if (( $(handshake_age) <= rekey + 10 )); then
            stale=0
          elif (( ++stale >= 2 )); then
            echo "proxy-suite: AmneziaWG profile '${name}' is not rekeying; moving to a new source port" >&2
            new_source_port
            stale=0
          fi
        done
      '';
    in
    {
      description = "proxy-suite AmneziaWG client profile ${name} watchdog";
      bindsTo = [ "${serviceName name}.service" ];
      after = [ "${serviceName name}.service" ];
      wantedBy = [ "${serviceName name}.service" ];
      serviceConfig = {
        ExecStart = watchdog;
        Restart = "on-failure";
        RestartSec = 5;
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "full";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

  profileAssertions = lib.concatMap (
    name:
    let
      profile = profiles.${name};
      settings = profile.settings;
      obfuscation = if settings == null then null else settings.obfuscation;
    in
    [
      {
        assertion = builtins.match "^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$" name != null;
        message = "proxy-suite: AmneziaWG profile '${name}' must be a safe 1-32 character identifier";
      }
      {
        assertion = sourceCount profile == 1;
        message = "proxy-suite: AmneziaWG profile '${name}' must set exactly one of configFile, vpnFile, vpn, or settings";
      }
      {
        assertion = profile.vpnContainer == null || profile.vpn != null || profile.vpnFile != null;
        message = "proxy-suite: AmneziaWG profile '${name}': vpnContainer requires vpn or vpnFile";
      }
      {
        assertion = profile.asOutbound == null || cfg.proxy.enable;
        message = "proxy-suite: AmneziaWG profile '${name}': asOutbound requires proxy.enable = true";
      }
      {
        assertion = profile.asOutbound == null || !profile.autostart;
        message = "proxy-suite: AmneziaWG profile '${name}': an outbound always runs; leave autostart off";
      }
      {
        assertion = profile.asOutbound != "interface" || settings == null || settings.table == null;
        message = "proxy-suite: AmneziaWG profile '${name}': an outbound interface has no routes; leave settings.table unset";
      }
      {
        assertion = settings == null || settings.addresses != [ ];
        message = "proxy-suite: AmneziaWG profile '${name}': declarative settings require at least one address";
      }
      {
        assertion = settings == null || settings.peers != [ ];
        message = "proxy-suite: AmneziaWG profile '${name}': declarative settings require at least one peer";
      }
      {
        assertion =
          settings == null || ((settings.privateKey != null) != (settings.privateKeyFile != null));
        message = "proxy-suite: AmneziaWG profile '${name}': set exactly one of settings.privateKey or settings.privateKeyFile";
      }
      {
        assertion =
          obfuscation == null
          || obfuscation.headerProtectionKey == null
          || obfuscation.headerProtectionKeyFile == null;
        message = "proxy-suite: AmneziaWG profile '${name}': set at most one header-protection key source";
      }
    ]
    ++ lib.optionals (settings != null) (
      lib.imap0 (index: peer: {
        assertion = peer.presharedKey == null || peer.presharedKeyFile == null;
        message = "proxy-suite: AmneziaWG profile '${name}' peer ${toString index}: set at most one preshared key source";
      }) settings.peers
    )
  ) profileNames;

  interfaceNames = map (name: profiles.${name}.interfaceName) profileNames;
  autostartProfiles = builtins.filter (name: profiles.${name}.autostart) globalProfileNames;
  globalAutostartCount = builtins.length autostartProfiles + (if cfg.proxy.autostart != null then 1 else 0);
in
{
  environment.systemPackages = [
    awgCfg.toolsPackage
    awgCfg.userspacePackage
  ];

  boot.extraModulePackages = lib.optionals (awgCfg.kernelModulePackage != null) [
    awgCfg.kernelModulePackage
  ];

  # Replies to the proxy's sockets come in on an interface the host has no route through.
  networking.firewall.extraReversePathFilterRules = lib.concatMapStrings (ob: ''
    iifname "${ob.interface}" accept
  '') derived.awgInterfaceOutbounds;

  systemd.services = lib.mkMerge [
    (lib.mapAttrs' (name: profile: lib.nameValuePair (serviceName name) (mkService name profile)) (
      lib.filterAttrs (_: profile: profile.asOutbound != "singBox") profiles
    ))
    (lib.mapAttrs' (
      name: profile: lib.nameValuePair "${serviceName name}-watchdog" (mkWatchdog name profile)
    ) (lib.filterAttrs (_: profile: profile.asOutbound != "singBox") profiles))
    (lib.listToAttrs (map (ob: lib.nameValuePair (serviceName ob.name) (mkSingBoxService ob)) singBoxOutbounds))
    (lib.mkIf cfg.proxy.tun.enable {
      proxy-suite-tun.conflicts = map (name: "${name}.service") globalServiceNames;
    })
    (lib.mkIf cfg.proxy.tproxy.enable {
      proxy-suite-tproxy.conflicts = map (name: "${name}.service") globalServiceNames;
    })
  ];

  assertions = profileAssertions ++ [
    {
      assertion = profiles != { };
      message = "proxy-suite: amneziaWg.enable requires at least one profile";
    }
    {
      assertion = builtins.length interfaceNames == builtins.length (lib.unique interfaceNames);
      message = "proxy-suite: AmneziaWG profile interface names must be unique";
    }
    {
      assertion = builtins.length autostartProfiles <= 1;
      message = "proxy-suite: at most one AmneziaWG profile may autostart";
    }
    {
      assertion = globalAutostartCount <= 1;
      message = "proxy-suite: at most one AmneziaWG, TUN, or TProxy global mode may autostart";
    }
    {
      assertion =
        !cfg.proxy.tun.enable
        || builtins.all (interface: interface != cfg.proxy.tun.interface) interfaceNames;
      message = "proxy-suite: AmneziaWG interfaces must differ from proxy.tun.interface";
    }
    {
      assertion =
        !cfg.perAppRouting.tun.enable
        || builtins.all (interface: interface != cfg.perAppRouting.tun.interface) interfaceNames;
      message = "proxy-suite: AmneziaWG interfaces must differ from perAppRouting.tun.interface";
    }
  ];
}
