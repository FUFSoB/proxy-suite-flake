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

  scriptsDir = import ./lib/scripts-dir.nix { inherit lib; };
  python3 = "${pkgs.python3}/bin/python3";
  awg = "${awgCfg.toolsPackage}/bin/awg";
  awgCommon = import ./awg-common.nix { inherit lib pkgs awgCfg; };

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
          # Cloud instance metadata (credentials, IAM tokens): for this host alone, never
          # for its clients, "lan" or not.
          ip daddr { ${lib.concatStringsSep ", " derived.constants.cloudMetadata.ipv4} } drop
          ip6 daddr { ${lib.concatStringsSep ", " derived.constants.cloudMetadata.ipv6} } drop
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

  # The table swapped in whole, in one transaction, also after a firewall reload flushed it.
  nftReplaceFile = pkgs.writeText "proxy-suite-routing" ''
    table inet ${nftTable}
    delete table inet ${nftTable}
    include "${nftRulesFile}"
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

    ${awgCommon.modprobe}

    ${stop}

    # Before any interface is up: its iifname matches already, so no client packet comes
    # in ahead of the confinement.
    ${nft} -f ${nftRulesFile}

    PYTHONPATH=${scriptsDir} ${python3} ${scriptsDir}/awg_inbound.py prepare \
      --spec ${proxyInboundsSpecFile} --awg ${awg} --runtime-dir "$RUNTIME_DIRECTORY" \
      > "$RUNTIME_DIRECTORY/interfaces"

    while read -r _interface implementation config; do
      ${awgCommon.awgQuickUp "$implementation" "\"$config\""}
    done < "$RUNTIME_DIRECTORY/interfaces"

    ${lib.concatStrings (
      lib.mapAttrsToList (name: value: ''
        ${pkgs.procps}/bin/sysctl -q -w ${name}=${toString value}
      '') sysctl
    )}

    # Diverted packets are for the local XRay sockets, whatever their destination. Only as
    # they come in: with src_valid_mark on (awg-quick turns it on for a global profile and
    # leaves it), the kernel checks a packet's source by its mark too, and the local route
    # here would make every client's IPv4 address a martian.
    ${lib.concatMapStrings (family: ''
      ${ip} ${family} route replace local default dev lo table ${toString awgInboundRouteTable}
      ${lib.concatMapStrings (listener: ''
        ${ip} ${family} rule add pref ${toString awgInboundRulePriority} iif ${lib.escapeShellArg listener.interface} fwmark ${toString awgInboundFwmark} table ${toString awgInboundRouteTable}
      '') listeners}
    '') ([ "-4" ] ++ lib.optional ipv6 "-6")}
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
      # After nftables, whose start flushes what came before it on flushRuleset hosts.
      after = [
        "network-online.target"
        "nftables.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # Put back after a firewall reload that flushed the ruleset, and restarted along with a
      # restart of nftables, which a reload hook never hears of.
      unitConfig = {
        ReloadPropagatedFrom = [ "nftables.service" ];
        PartOf = [ "nftables.service" ];
      };
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
        ExecReload = "${nft} -f ${nftReplaceFile}";
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
