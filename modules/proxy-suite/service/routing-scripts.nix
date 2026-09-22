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
  killSwitchUpScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set -euo pipefail
    ${deleteKillSwitchTable}
    ${nft} -f ${killSwitchRulesFile}
  '';

  killSwitchDownScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set +e
    ${deleteKillSwitchTable}
  '';

  xrayTunUpScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set -euo pipefail

    tun_cidr=${lib.escapeShellArg globalTun.address}
    tun6_cidr=${lib.escapeShellArg globalTunIPv6Address}
    tun6_route_prefix=${lib.escapeShellArg globalTunIPv6RoutePrefix}
    tun_addr=""
    tun_route_prefix=""

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

    tun_addr="''${tun_cidr%%/*}"
    tun_route_prefix="$(cidr_network "$tun_cidr")"

    ${ip} -4 addr replace "$tun_cidr" dev ${lib.escapeShellArg globalTun.interface}
    ${lib.optionalString ipv6 ''${ip} -6 addr replace "$tun6_cidr" dev ${lib.escapeShellArg globalTun.interface}''}
    ${ip} -4 route replace "$tun_route_prefix" dev ${lib.escapeShellArg globalTun.interface} src "$tun_addr" table ${toString tunAutoRouteTableIndex}
    # No uplink src: it goes stale when the uplink address changes, and XRay's own sockets
    # (routed by uid and mark, not bound to an interface) pick theirs from main.
    ${ip} -4 route replace default dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
    ${lib.optionalString ipv6 ''
      ${ip} -6 route replace "$tun6_route_prefix" dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
      ${ip} -6 route replace default dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
    ''}
    ${lib.optionalString perAppRoutingTun.enable ''
      ${ip} -4 rule add pref ${toString xrayTunPerAppTunRulePriority} fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable}
      ${ip} -6 rule add pref ${toString xrayTunPerAppTunRulePriority} fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable}
    ''}
    service_uid=$(${pkgs.coreutils}/bin/id -u ${constants.serviceUser})
    ${ip} -4 rule add pref ${toString xrayTunServiceUserRulePriority} uidrange "$service_uid-$service_uid" lookup main
    ${ip} -6 rule add pref ${toString xrayTunServiceUserRulePriority} uidrange "$service_uid-$service_uid" lookup main
    for family in -4 -6; do
      ${ip} "$family" rule add pref ${toString xrayTunMarkBypassRulePriority} fwmark ${toString globalTproxy.proxyMark} lookup main
      ${ip} "$family" rule add pref ${toString xrayTunDnsRulePriority} ipproto udp dport 53 table ${toString tunAutoRouteTableIndex}
      ${ip} "$family" rule add pref ${toString xrayTunDnsRulePriority} ipproto tcp dport 53 table ${toString tunAutoRouteTableIndex}
      ${ip} "$family" rule add pref ${toString xrayTunMainRulePriority} lookup main suppress_prefixlength 0
    done
    ${ip} -4 rule add pref ${toString tunAutoRouteRulePriority} not fwmark ${toString globalTproxy.proxyMark} table ${toString tunAutoRouteTableIndex}
    ${ip} -6 rule add pref ${toString tunAutoRouteRulePriority} not fwmark ${toString globalTproxy.proxyMark} table ${toString tunAutoRouteTableIndex}
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

    ${nft} -f ${nftablesRulesFile}
    # Set on NixOS already; system-manager hosts only get them here.
    ${lib.concatStrings (
      lib.mapAttrsToList (name: value: ''
        ${pkgs.procps}/bin/sysctl -q -w ${name}=${toString value}
      '') tproxyLanSysctl
    )}
    ${builders.mkTproxyRoutingUp {
      inherit ip;
      inherit ipv6;
      fwmark = globalTproxy.fwmark;
      table = globalTproxy.routeTable;
    }}
  '';

  tproxyDownScript = pkgs.writeShellScript "proxy-suite-routing" ''
    set +e

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
