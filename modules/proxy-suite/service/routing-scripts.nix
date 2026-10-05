{ ctx }:

let
  inherit (ctx)
    lib
    pkgs
    builders
    ip
    nft
    nftablesRulesFile
    killSwitchRulesFile
    constants
    globalTun
    globalTproxy
    tproxyLanSysctl
    perAppRoutingTun
    proxyCfg
    cfg
    ;
  inherit (proxyCfg) ipv6;
  inherit (constants)
    tunAutoRouteTableIndex
    tunAutoRouteRulePriority
    xrayTunMarkBypassRulePriority
    xrayTunServiceUserRulePriority
    xrayTunPerAppTunRulePriority
    xrayTunDnsRulePriority
    xrayTunMainRulePriority
    globalTunIPv6Address
    globalTunIPv6RoutePrefix
    ;

  deleteXrayTunRules =
    lib.concatMapStrings
      (
        family:
        lib.concatMapStrings (priority: builders.mkIpRuleDeleteByPriority { inherit ip family priority; }) [
          xrayTunMarkBypassRulePriority
          xrayTunServiceUserRulePriority
          xrayTunPerAppTunRulePriority
          xrayTunDnsRulePriority
          xrayTunMainRulePriority
          tunAutoRouteRulePriority
        ]
      )
      [
        "-4"
        "-6"
      ];

  # A table, as NixOS's firewall includes it (constants.persistedNftDir): written aside and
  # renamed, never half there. `lines`: its rules, as shell words printed one per line.
  persistedNftDir = ctx.constants.persistedNftDir;
  persistTable =
    table: lines:
    lib.optionalString ctx.firewallIncludesTables ''
      ${pkgs.coreutils}/bin/install -d -m 0700 ${persistedNftDir}
      (
        umask 077
        printf '%s\n' "add table inet ${table}" "delete table inet ${table}" ${lines} \
          > ${persistedNftDir}/${table}.nft.tmp
      ) && mv -f ${persistedNftDir}/${table}.nft.tmp ${persistedNftDir}/${table}.nft
    '';
  # Before the table goes: a firewall reload in between would bring it back.
  unpersistTable =
    table: lib.optionalString ctx.firewallIncludesTables "rm -f ${persistedNftDir}/${table}.nft";

  # Replies to connections from outside (sshd, a game server, anything listening) take
  # proxyMark, so the fwmark rule sends them back out the way they came instead of into
  # the TUN, where nothing expects them. Locally started connections stay "original".
  xrayTunReplyTable = "proxy_suite_xray_tun";
  xrayTunReplyRules = pkgs.writeText "proxy-suite-xray-tun.nft" ''
    table inet ${xrayTunReplyTable} {
      chain output {
        type route hook output priority mangle; policy accept;
        ct direction reply meta mark 0 meta mark set ${toString globalTproxy.proxyMark}
      }
    }
  '';
  deleteXrayTunReplyTable = builders.mkNftDeleteTable {
    inherit nft;
    family = "inet";
    table = xrayTunReplyTable;
  };
  deleteKillSwitchTable = builders.mkNftDeleteTable {
    inherit nft;
    family = "inet";
    table = "proxy_suite_killswitch";
  };
in
{
  # One nft transaction swaps the old table for the new: traffic never sees neither. Also the
  # unit's reload, which a switch runs instead of a restart (units.nix). The time daemons'
  # users are looked up here rather than named in the rules: a missing one would fail them all.
  killSwitchUpScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set -euo pipefail
    uids=()
    for user in ${lib.escapeShellArgs cfg.killSwitch.timeSyncUsers}; do
      uid=$(${pkgs.coreutils}/bin/id -u -- "$user" 2>/dev/null) && uids+=("$uid")
    done
    time_sync=
    if (( ''${#uids[@]} )); then
      time_sync="add element inet proxy_suite_killswitch time_sync_uids { $(IFS=,; echo "''${uids[*]}") }"
    fi
    ${nft} -f - <<EOF
    add table inet proxy_suite_killswitch
    delete table inet proxy_suite_killswitch
    include "${killSwitchRulesFile}"
    $time_sync
    EOF
    ${persistTable "proxy_suite_killswitch" '''include "${killSwitchRulesFile}"' ''${time_sync:+"$time_sync"}''}
  '';

  killSwitchDownScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set +e
    ${unpersistTable "proxy_suite_killswitch"}
    ${deleteKillSwitchTable}
  '';

  xrayTunUpScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set -euo pipefail

    tun_cidr=${lib.escapeShellArg globalTun.address}
    tun6_cidr=${lib.escapeShellArg globalTunIPv6Address}
    tun6_route_prefix=${lib.escapeShellArg globalTunIPv6RoutePrefix}
    tun_addr=""
    tun_route_prefix=""
    # A kernel booted with ipv6.disable=1 refuses every -6 command: the TUN still comes up.
    families=(-4)
    if [ -e /proc/net/if_inet6 ]; then families+=(-6); fi
    has_ipv6() { [ "''${#families[@]}" = 2 ]; }

    ${builders.cidrNetworkFunction}

    for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
      if ${ip} link show dev ${lib.escapeShellArg globalTun.interface} >/dev/null 2>&1; then
        break
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done

    if ! ${ip} link show dev ${lib.escapeShellArg globalTun.interface} >/dev/null 2>&1; then
      echo "proxy-suite: XRay TUN interface ${globalTun.interface} did not appear in time" >&2
      exit 1
    fi

    ${deleteXrayTunRules}
    ${deleteXrayTunReplyTable}
    ${nft} -f ${xrayTunReplyRules}
    ${persistTable xrayTunReplyTable "'include \"${xrayTunReplyRules}\"'"}

    # XRay may not have brought the link up yet, and routes via a down link fail with
    # "Device for nexthop is not up".
    ${ip} link set dev ${lib.escapeShellArg globalTun.interface} up
    tun_addr="''${tun_cidr%%/*}"
    tun_route_prefix="$(cidr_network "$tun_cidr")"

    ${ip} -4 addr replace "$tun_cidr" dev ${lib.escapeShellArg globalTun.interface}
    ${lib.optionalString ipv6 ''has_ipv6 && ${ip} -6 addr replace "$tun6_cidr" dev ${lib.escapeShellArg globalTun.interface}''}
    ${ip} -4 route replace "$tun_route_prefix" dev ${lib.escapeShellArg globalTun.interface} src "$tun_addr" table ${toString tunAutoRouteTableIndex}
    # No uplink src: it goes stale when the uplink address changes, and XRay's own sockets
    # (routed by uid and mark, not bound to an interface) pick theirs from main.
    ${ip} -4 route replace default dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
    ${
      if ipv6 then
        ''
          if has_ipv6; then
            ${ip} -6 route replace "$tun6_route_prefix" dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
            ${ip} -6 route replace default dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
          fi
        ''
      else
        ''
          # No IPv6 in the TUN: unreachable, as sing-box's strict_route and the per-app TUN
          # have it, so apps fall back to IPv4. Without, the rules below would find nothing
          # in this table and go on to main: every IPv6 connection straight out the uplink.
          ${ip} -6 route replace unreachable default table ${toString tunAutoRouteTableIndex} 2>/dev/null || true
        ''
    }
    ${lib.optionalString perAppRoutingTun.enable ''
      for family in "''${families[@]}"; do
        ${ip} "$family" rule add pref ${toString xrayTunPerAppTunRulePriority} fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable}
      done
    ''}
    for service_user in ${lib.escapeShellArgs constants.ownTrafficUsers}; do
      service_uid=$(${pkgs.coreutils}/bin/id -u "$service_user")
      for family in "''${families[@]}"; do
        ${ip} "$family" rule add pref ${toString xrayTunServiceUserRulePriority} uidrange "$service_uid-$service_uid" lookup main
      done
    done
    for family in "''${families[@]}"; do
      ${ip} "$family" rule add pref ${toString xrayTunMarkBypassRulePriority} fwmark ${toString globalTproxy.proxyMark} lookup main
      ${ip} "$family" rule add pref ${toString xrayTunDnsRulePriority} ipproto udp dport 53 table ${toString tunAutoRouteTableIndex}
      ${ip} "$family" rule add pref ${toString xrayTunDnsRulePriority} ipproto tcp dport 53 table ${toString tunAutoRouteTableIndex}
      ${ip} "$family" rule add pref ${toString xrayTunMainRulePriority} lookup main suppress_prefixlength 0
    done
    for family in "''${families[@]}"; do
      ${ip} "$family" rule add pref ${toString tunAutoRouteRulePriority} not fwmark ${toString globalTproxy.proxyMark} table ${toString tunAutoRouteTableIndex}
    done
  '';

  # The reply marking, after a firewall reload that flushed the ruleset: without it, replies
  # to connections from outside (sshd among them) are routed into the TUN until it restarts.
  xrayTunReloadScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set -euo pipefail
    ${builders.mkNftReplaceTable {
      inherit nft;
      family = "inet";
      table = xrayTunReplyTable;
      file = xrayTunReplyRules;
    }}
  '';

  tproxyUpScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set -euo pipefail

    # Start from a clean policy-routing state.  `ip rule add` permits duplicate
    # rules on some iproute2 versions, and a stale rule can keep packets routed
    # into a dead local table after a failed restart.
    ${builders.mkNftDeleteTable {
      inherit nft;
      family = "inet";
      table = "singbox";
    }}
    ${builders.mkTproxyRoutingDown {
      inherit ip;
      fwmark = globalTproxy.fwmark;
      table = globalTproxy.routeTable;
    }}

    # Set on NixOS already; system-manager hosts only get them here. Left on at the stop:
    # by then something else (Docker, libvirt) may rely on forwarding too.
    ${lib.concatStrings (
      lib.mapAttrsToList (name: value: ''
        ${pkgs.procps}/bin/sysctl -q -w ${name}=${toString value}
      '') tproxyLanSysctl
    )}
    # The route first, then the marking: a packet marked before its rule exists would leave
    # by the main table, and the kill switch lets the mark through.
    ${builders.mkTproxyRoutingUp {
      inherit ip;
      inherit ipv6;
      fwmark = globalTproxy.fwmark;
      table = globalTproxy.routeTable;
    }}
    ${nft} -f ${nftablesRulesFile}
    ${persistTable "singbox" "'include \"${nftablesRulesFile}\"'"}
  '';

  # After a firewall reload that flushed the ruleset (NixOS's flushRuleset, a distribution's
  # `flush ruleset` config): the marking alone, swapped in whole in one transaction. The
  # policy routing is no nftables state, and stays.
  tproxyReloadScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set -euo pipefail
    ${builders.mkNftReplaceTable {
      inherit nft;
      family = "inet";
      table = "singbox";
      file = nftablesRulesFile;
    }}
  '';

  # The daemon guard (constants.daemonMetadataGuard) as loaded: a static table, so its
  # listing loads again as it is.
  persistDaemonGuardScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set -euo pipefail
    rules=$(${nft} -s list table inet proxy_suite_daemon_guard) || exit 0
    ${persistTable "proxy_suite_daemon_guard" ''"$rules"''}
  '';

  tproxyDownScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set +e

    ${unpersistTable "singbox"}
    ${builders.mkNftDeleteTable {
      inherit nft;
      family = "inet";
      table = "singbox";
    }}
    ${builders.mkTproxyRoutingDown {
      inherit ip;
      fwmark = globalTproxy.fwmark;
      table = globalTproxy.routeTable;
    }}
  '';

  tunCleanupScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set +e

    # SingBox normally removes these on graceful shutdown, but stale
    # auto_route/auto_redirect state leaves the host routing through a dead TUN
    # interface after `proxy-ctl proxy tun off` or an unclean service stop.
    ${builders.mkNftDeleteTable {
      inherit nft;
      family = "inet";
      table = "sing-box";
    }}
    ${builders.mkIpRuleDeleteByTable {
      inherit ip;
      family = "-4";
      table = tunAutoRouteTableIndex;
    }}
    ${builders.mkIpRuleDeleteByTable {
      inherit ip;
      family = "-6";
      table = tunAutoRouteTableIndex;
    }}
    ${deleteXrayTunRules}
    ${unpersistTable xrayTunReplyTable}
    ${deleteXrayTunReplyTable}
    ${builders.mkIpRouteFlushTable {
      inherit ip;
      family = "-4";
      table = tunAutoRouteTableIndex;
    }}
    ${builders.mkIpRouteFlushTable {
      inherit ip;
      family = "-6";
      table = tunAutoRouteTableIndex;
    }}
    ${builders.mkIpLinkDelete {
      inherit ip;
      interface = globalTun.interface;
    }}
    ${builders.flushResolvedCaches}
  '';
}
