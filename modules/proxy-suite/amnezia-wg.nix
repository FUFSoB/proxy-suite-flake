# Native AmneziaWG client profile services.
{
  config,
  lib,
  pkgs,
  cfg,
}:

let
  awgCfg = cfg.amneziaWg;
  profiles = awgCfg.profiles;
  profileNames = builtins.attrNames profiles;
  serviceName = name: "proxy-suite-awg-${name}";
  serviceNames = map serviceName profileNames;
  allProfileConflicts =
    name:
    map (other: "${serviceName other}.service") (builtins.filter (other: other != name) profileNames);
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
  inlineVpnFile = name: profile: pkgs.writeText "proxy-suite-awg-${name}.vpn" profile.vpn;
  sourceKind =
    profile:
    if profile.configFile != null then
      "configFile"
    else if profile.vpnFile != null then
      "vpnFile"
    else if profile.vpn != null then
      "vpn"
    else
      "settings";
  sourcePath =
    name: profile:
    if profile.configFile != null then
      profile.configFile
    else if profile.vpnFile != null then
      profile.vpnFile
    else if profile.vpn != null then
      inlineVpnFile name profile
    else
      null;
  manifestFor =
    name: profile:
    pkgs.writeText "proxy-suite-awg-${name}-manifest.json" (
      builtins.toJSON (
        {
          kind = sourceKind profile;
          allowConfigHooks = profile.allowConfigHooks;
          vpnContainer = profile.vpnContainer;
        }
        // lib.optionalAttrs (sourcePath name profile != null) { path = sourcePath name profile; }
        // lib.optionalAttrs (profile.settings != null) { settings = profile.settings; }
      )
    );
  configTool = ../../scripts/amneziawg_config.py;
  runtimeDir = name: "/run/${serviceName name}";
  runtimeConfig = name: profile: "${runtimeDir name}/${profile.interfaceName}.conf";
  # Keep proxy backend sockets (which already carry proxyMark) out of AWG's
  # default-route policy table. This priority sits ahead of the global TUN
  # rules while leaving the per-app rules at 8996/8997 untouched.
  proxyBypassRulePriority = 8998;

  mkService =
    name: profile:
    let
      manifest = manifestFor name profile;
      configPath = runtimeConfig name profile;
      prepare = pkgs.writeShellScript "proxy-suite-awg-${name}-prepare" ''
        set -euo pipefail
        ${pkgs.python3}/bin/python3 ${configTool} \
          --manifest ${lib.escapeShellArg (toString manifest)} \
          --output ${lib.escapeShellArg configPath}
      '';
      proxyBypassUp = pkgs.writeShellScript "proxy-suite-awg-${name}-proxy-bypass-up" ''
        set -euo pipefail

        add_bypass_rule() {
          local family="$1"
          while ${pkgs.iproute2}/bin/ip "$family" rule del \
            pref ${toString proxyBypassRulePriority} \
            fwmark ${toString cfg.proxy.tproxy.proxyMark} lookup main 2>/dev/null; do :; done
          if ! ${pkgs.iproute2}/bin/ip "$family" rule add \
            pref ${toString proxyBypassRulePriority} \
            fwmark ${toString cfg.proxy.tproxy.proxyMark} lookup main 2>/dev/null; then
            # IPv4 is required: without this rule the proxy backend itself is
            # captured by AWG's default-route table and HTTP_PROXY clients can
            # hang or recurse.  IPv6 is best-effort for hosts without IPv6
            # policy-routing support.
            if [ "$family" = "-4" ]; then
              echo "proxy-suite: unable to install the AWG proxy-backend bypass rule" >&2
              return 1
            fi
          fi
        }

        add_bypass_rule -4
        add_bypass_rule -6
      '';
      proxyBypassDown = pkgs.writeShellScript "proxy-suite-awg-${name}-proxy-bypass-down" ''
        set +e

        while ${pkgs.iproute2}/bin/ip -4 rule del \
          pref ${toString proxyBypassRulePriority} \
          fwmark ${toString cfg.proxy.tproxy.proxyMark} lookup main 2>/dev/null; do :; done
        while ${pkgs.iproute2}/bin/ip -6 rule del \
          pref ${toString proxyBypassRulePriority} \
          fwmark ${toString cfg.proxy.tproxy.proxyMark} lookup main 2>/dev/null; do :; done
      '';
      start = pkgs.writeShellScript "proxy-suite-awg-${name}-start" ''
        set -Eeuo pipefail

        cleanup() {
          set +e
          ${awgCfg.toolsPackage}/bin/awg-quick down ${lib.escapeShellArg configPath}

          # If the userspace control socket died, awg-quick cannot discover its
          # fwmark. Remove only routing/firewall state tied to this interface.
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

        implementation="$(${pkgs.python3}/bin/python3 ${configTool} \
          --transport-implementation ${lib.escapeShellArg configPath})"
        # The official 3.1.20260812 kernel module silently drops transport
        # packets for RandomTrailers with ranged H1-H3. The bundled userspace
        # build carries the receive-path repair until upstream publishes it.
        if [[ "$implementation" == userspace ]]; then
          WG_QUICK_FORCE_USERSPACE_IMPLEMENTATION=1 \
            WG_QUICK_USERSPACE_IMPLEMENTATION=${awgCfg.userspacePackage}/bin/amneziawg-go \
            ${awgCfg.toolsPackage}/bin/awg-quick up ${lib.escapeShellArg configPath}
        else
          WG_QUICK_USERSPACE_IMPLEMENTATION=${awgCfg.userspacePackage}/bin/amneziawg-go \
            ${awgCfg.toolsPackage}/bin/awg-quick up ${lib.escapeShellArg configPath}
        fi

        probe="$(${pkgs.python3}/bin/python3 ${configTool} --probe-address ${lib.escapeShellArg configPath})"
        for _ in $(${pkgs.coreutils}/bin/seq 1 15); do
          ${pkgs.iputils}/bin/ping -n -c 1 -W 1 "$probe" >/dev/null 2>&1 || true
          if ${awgCfg.toolsPackage}/bin/awg show ${lib.escapeShellArg profile.interfaceName} latest-handshakes 2>/dev/null \
            | ${pkgs.gawk}/bin/awk '$2 + 0 > 0 { found = 1 } END { exit !found }'; then
            trap - ERR
            exit 0
          fi
        done

        echo "proxy-suite: AmneziaWG profile '${name}' did not complete a handshake; rolling back routes" >&2
        false
      '';
      stop = pkgs.writeShellScript "proxy-suite-awg-${name}-stop" ''
        set -euo pipefail
        exec ${awgCfg.toolsPackage}/bin/awg-quick down ${lib.escapeShellArg configPath}
      '';
    in
    {
      description = "proxy-suite AmneziaWG client profile ${name}";
      # When the normal proxy stack is enabled, bring its local HTTP/SOCKS
      # listener up before installing AWG's default-route policy.  This keeps
      # applications using HTTP_PROXY/HTTPS_PROXY (for example Codex) from
      # racing the proxy backend during boot or an explicit `awg on`.
      after = [
        "network-online.target"
        "zapret-discord-youtube.service"
      ]
      ++ lib.optional cfg.proxy.enable "proxy-suite-socks.service";
      wants = [ "network-online.target" ] ++ lib.optional cfg.proxy.enable "proxy-suite-socks.service";
      wantedBy = lib.optionals profile.autostart [ "multi-user.target" ];
      conflicts = allProfileConflicts name ++ [
        "proxy-suite-tun.service"
        "proxy-suite-tproxy.service"
        "zapret-discord-youtube.service"
        "proxy-suite-per-app-zapret.service"
        "proxy-suite-zapret-vm-exempt.service"
      ];
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
        ExecStartPre = [ prepare ] ++ lib.optionals cfg.proxy.enable [ proxyBypassUp ];
        ExecStart = start;
        ExecStop = stop;
      }
      // lib.optionalAttrs cfg.proxy.enable {
        ExecStopPost = proxyBypassDown;
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
          || ((obfuscation.headerProtectionKey != null) != (obfuscation.headerProtectionKeyFile != null))
          || (obfuscation.headerProtectionKey == null && obfuscation.headerProtectionKeyFile == null);
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
  autostartProfiles = builtins.filter (name: profiles.${name}.autostart) profileNames;
  globalAutostartCount =
    builtins.length autostartProfiles
    + (if cfg.proxy.tun.autostart then 1 else 0)
    + (if cfg.proxy.tproxy.autostart then 1 else 0);
in
{
  environment.systemPackages = [
    awgCfg.toolsPackage
    awgCfg.userspacePackage
  ];

  boot.extraModulePackages = lib.optionals (awgCfg.kernelModulePackage != null) [
    awgCfg.kernelModulePackage
  ];

  systemd.services = lib.mkMerge [
    (lib.mapAttrs' (
      name: profile: lib.nameValuePair (serviceName name) (mkService name profile)
    ) profiles)
    (lib.mkIf cfg.proxy.tun.enable {
      proxy-suite-tun.conflicts = map (name: "${name}.service") serviceNames;
    })
    (lib.mkIf cfg.proxy.tproxy.enable {
      proxy-suite-tproxy.conflicts = map (name: "${name}.service") serviceNames;
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
        !cfg.proxy.tun.perApp.enable
        || builtins.all (interface: interface != cfg.proxy.tun.perApp.interface) interfaceNames;
      message = "proxy-suite: AmneziaWG interfaces must differ from proxy.tun.perApp.interface";
    }
  ];
}
