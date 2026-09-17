# AmneziaWG server listeners of services.proxy-suite.inbounds: one interface per listener,
# whose TCP and UDP is diverted by TProxy to the listener's loopback XRay inbound, so it
# leaves by the same routing as every other inbound. "lan" listeners also reach this host,
# its private networks and each other natively; "proxy" listeners reach nothing but that.
{
  lib,
  pkgs,
  cfg,
  derived,
  proxyInboundsSpecFile,
  reservedIpBlock,
  ip,
  nft,
}:

let
  awgCfg = cfg.amneziaWg;
  listeners = derived.proxyInboundsAwg;
  inherit (derived.constants) awgInboundFwmark awgInboundRouteTable awgInboundRulePriority;
  unitName = "proxy-suite-inbounds-awg";
  nftTable = "proxy_suite_awg_inbounds";
  ipv6 = lib.any (listener: listener.subnet6 != null) listeners;
  lanListeners = builtins.filter (listener: listener.mode == "lan") listeners;
  lanIPv6 = lib.any (listener: listener.subnet6 != null) lanListeners;

  scriptsDir = builtins.path {
    name = "proxy-suite-scripts";
    path = ../../scripts;
  };
  python3 = "${pkgs.python3}/bin/python3";
  awg = "${awgCfg.toolsPackage}/bin/awg";
  awgQuick = "${awgCfg.toolsPackage}/bin/awg-quick";

  # Diverted packets are delivered locally; only "lan" listeners forward.
  sysctl =
    lib.optionalAttrs (lanListeners != [ ]) {
      "net.ipv4.ip_forward" = 1;
    }
    // lib.optionalAttrs lanIPv6 {
      "net.ipv6.conf.all.forwarding" = 1;
    };

  quote = value: ''"${value}"'';

  # Everything a listener's clients send that is not theirs to reach natively.
  mkListenerChain =
    index: listener:
    let
      verdict = if listener.mode == "lan" then "return" else "drop";
      port = toString listener.internalPort;
      mark = toString awgInboundFwmark;
    in
    ''
      chain listener_${toString index} {
          fib daddr type { local, broadcast, multicast } ${verdict}
          ip daddr $RESERVED_IP ${verdict}
          # Not in RESERVED_IP, whose other users route it by the local subnets instead.
          ip daddr 192.168.0.0/16 ${verdict}
          ip6 daddr $RESERVED_IP6 ${verdict}
          ip daddr ${listener.subnet} ${verdict}
      ${lib.optionalString (listener.subnet6 != null) "    ip6 daddr ${listener.subnet6} ${verdict}"}
          meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${port} meta mark set ${mark} accept
      ${lib.optionalString (
        listener.subnet6 != null
      ) "    meta l4proto { tcp, udp } tproxy ip6 to [::1]:${port} meta mark set ${mark} accept"}
          # Nothing else can follow the listener's routing (ICMP to the internet among it).
          drop
      }
    '';

  nftRulesFile = pkgs.writeText "proxy-suite-routing" ''
    ${reservedIpBlock}
    table inet ${nftTable} {
    ${lib.concatStrings (lib.imap0 mkListenerChain listeners)}
        chain prerouting {
            # Ahead of TProxy and TUN capture, and of the reverse-path filter.
            type filter hook prerouting priority mangle - 5; policy accept;
            # The XRay inbounds only take what is diverted to them.
            iifname != "lo" meta l4proto { tcp, udp } th dport { ${
              lib.concatMapStringsSep ", " (listener: toString listener.internalPort) listeners
            } } fib daddr type local drop
    ${lib.concatStrings (
      lib.imap0 (index: listener: ''
        iifname ${quote listener.interface} jump listener_${toString index}
      '') listeners
    )}
        }
    ${lib.optionalString (lanListeners != [ ]) ''
      # Private networks need no route back to the clients.
      chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
      ${lib.concatMapStrings (listener: ''
        ip saddr ${listener.subnet} oifname != ${quote listener.interface} masquerade
        ${lib.optionalString (
          listener.subnet6 != null
        ) "ip6 saddr ${listener.subnet6} oifname != ${quote listener.interface} masquerade"}
      '') lanListeners}
      }
    ''}
    }
  '';

  routingDown =
    lib.concatMapStrings
      (family: ''
        while ${ip} ${family} rule del pref ${toString awgInboundRulePriority} 2>/dev/null; do :; done
        ${ip} ${family} route flush table ${toString awgInboundRouteTable} 2>/dev/null || true
      '')
      [
        "-4"
        "-6"
      ];

  # The interfaces run with Table=off and no DNS, so deleting them undoes awg-quick.
  interfacesDown = lib.concatMapStrings (listener: ''
    ${ip} link del dev ${lib.escapeShellArg listener.interface} 2>/dev/null || true
  '') listeners;

  stop = pkgs.writeShellScript unitName ''
    set +e
    ${nft} delete table inet ${nftTable} 2>/dev/null
    ${routingDown}
    ${interfacesDown}
    true
  '';

  start = pkgs.writeShellScript unitName ''
    set -Eeuo pipefail
    trap ${stop} ERR

    ${lib.optionalString (awgCfg.kernelModulePackage != null) ''
      ${pkgs.kmod}/bin/modprobe amneziawg 2>/dev/null || true
    ''}

    ${stop}

    PYTHONPATH=${scriptsDir} ${python3} ${scriptsDir}/awg_inbound.py prepare \
      --spec ${proxyInboundsSpecFile} --awg ${awg} --runtime-dir "$RUNTIME_DIRECTORY" \
      > "$RUNTIME_DIRECTORY/interfaces"

    while read -r _interface implementation config; do
      # The 3.1 kernel module drops RandomTrailers packets with ranged H1-H3; userspace does not.
      if [[ "$implementation" == userspace ]]; then
        WG_QUICK_FORCE_USERSPACE_IMPLEMENTATION=1 \
          WG_QUICK_USERSPACE_IMPLEMENTATION=${awgCfg.userspacePackage}/bin/amneziawg-go \
          ${awgQuick} up "$config"
      else
        WG_QUICK_USERSPACE_IMPLEMENTATION=${awgCfg.userspacePackage}/bin/amneziawg-go \
          ${awgQuick} up "$config"
      fi
    done < "$RUNTIME_DIRECTORY/interfaces"

    ${lib.concatStrings (
      lib.mapAttrsToList (name: value: ''
        ${pkgs.procps}/bin/sysctl -q -w ${name}=${toString value}
      '') sysctl
    )}

    # Diverted packets are for the local XRay sockets, whatever their destination.
    ${lib.concatMapStrings (family: ''
      ${ip} ${family} route replace local default dev lo table ${toString awgInboundRouteTable}
      ${ip} ${family} rule add pref ${toString awgInboundRulePriority} fwmark ${toString awgInboundFwmark} table ${toString awgInboundRouteTable}
    '') ([ "-4" ] ++ lib.optional ipv6 "-6")}

    ${nft} -f ${nftRulesFile}
  '';
in
{
  services.proxy-suite.internal = {
    nftables = true;
    packages = [
      awgCfg.toolsPackage
      awgCfg.userspacePackage
    ];
    kernelModulePackages = lib.optionals (awgCfg.kernelModulePackage != null) [
      awgCfg.kernelModulePackage
    ];
    inherit sysctl;
    firewall = {
      # Past the host firewall: diverted packets reach input with their original destination,
      # and "proxy" listeners already drop the rest in prerouting.
      trustedInterfaces = map (listener: listener.interface) listeners;
      # Diverted packets carry a mark whose table has no route back.
      extraReversePathFilterRules = lib.concatMapStrings (listener: ''
        iifname "${listener.interface}" accept
      '') listeners;
    };

    services.${unitName} = {
      description = "proxy-suite AmneziaWG inbound interfaces";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        awgCfg.toolsPackage
        awgCfg.userspacePackage
        pkgs.coreutils
        pkgs.iproute2
        pkgs.kmod
        pkgs.nftables
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = unitName;
        RuntimeDirectoryMode = "0700";
        StateDirectory = "proxy-suite";
        UMask = "0077";
        ExecStart = start;
        ExecStop = stop;
        LockPersonality = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };

    # Client configs and links are rendered from the state this unit keeps.
    services.proxy-suite-inbounds = {
      after = [ "${unitName}.service" ];
      wants = [ "${unitName}.service" ];
    };
  };
}
