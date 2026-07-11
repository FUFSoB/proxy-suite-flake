{
  lib,
  pkgs,
  builders,
  ip,
  nft,
  nftablesRulesFile,
  constants,
  globalTun,
  globalTproxy,
  perAppRoutingTun,
  perAppRoutingTproxy,
}:

let
  inherit (constants)
    tunAutoRouteTableIndex
    tunAutoRouteRulePriority
    xrayTunPerAppTproxyRulePriority
    xrayTunPerAppTunRulePriority
    xrayGlobalTunIPv6Address
    xrayGlobalTunIPv6RoutePrefix
    ;

  defaultUplinkIPv4Source = builders.mkDefaultUplinkIPv4Source {
    inherit ip;
    awk = "${pkgs.gawk}/bin/awk";
    errorMessage = "proxy-suite: could not determine the default uplink IPv4 address for XRay TUN";
  };
in
{
  xrayTunUpScript = pkgs.writeShellScript "proxy-suite-xray-tun-up" ''
    set -euo pipefail

    tun_cidr=${lib.escapeShellArg globalTun.address}
    tun6_cidr=${lib.escapeShellArg xrayGlobalTunIPv6Address}
    tun6_route_prefix=${lib.escapeShellArg xrayGlobalTunIPv6RoutePrefix}
    tun_addr=""
    tun_route_prefix=""
    uplink_addr=""

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

    ${defaultUplinkIPv4Source}

    while ${ip} -4 rule del pref ${toString xrayTunPerAppTproxyRulePriority} 2>/dev/null; do :; done
    while ${ip} -4 rule del pref ${toString xrayTunPerAppTunRulePriority} 2>/dev/null; do :; done
    while ${ip} -4 rule del pref ${toString tunAutoRouteRulePriority} 2>/dev/null; do :; done
    while ${ip} -6 rule del pref ${toString xrayTunPerAppTunRulePriority} 2>/dev/null; do :; done
    while ${ip} -6 rule del pref ${toString tunAutoRouteRulePriority} 2>/dev/null; do :; done

    tun_addr="''${tun_cidr%%/*}"
    tun_route_prefix="$(cidr_network "$tun_cidr")"

    ${ip} -4 addr replace "$tun_cidr" dev ${lib.escapeShellArg globalTun.interface}
    ${ip} -6 addr replace "$tun6_cidr" dev ${lib.escapeShellArg globalTun.interface}
    ${ip} -4 route replace "$tun_route_prefix" dev ${lib.escapeShellArg globalTun.interface} src "$tun_addr" table ${toString tunAutoRouteTableIndex}
    ${ip} -4 route replace default dev ${lib.escapeShellArg globalTun.interface} src "$uplink_addr" table ${toString tunAutoRouteTableIndex}
    ${ip} -6 route replace "$tun6_route_prefix" dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
    ${ip} -6 route replace default dev ${lib.escapeShellArg globalTun.interface} table ${toString tunAutoRouteTableIndex}
    ${lib.optionalString perAppRoutingTproxy.enable ''
      ${ip} -4 rule add pref ${toString xrayTunPerAppTproxyRulePriority} fwmark ${toString perAppRoutingTproxy.fwmark} table ${toString perAppRoutingTproxy.routeTable}
    ''}
    ${lib.optionalString perAppRoutingTun.enable ''
      ${ip} -4 rule add pref ${toString xrayTunPerAppTunRulePriority} fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable}
      ${ip} -6 rule add pref ${toString xrayTunPerAppTunRulePriority} fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable}
    ''}
    ${ip} -4 rule add pref ${toString tunAutoRouteRulePriority} not fwmark ${toString globalTproxy.proxyMark} table ${toString tunAutoRouteTableIndex}
    ${ip} -6 rule add pref ${toString tunAutoRouteRulePriority} not fwmark ${toString globalTproxy.proxyMark} table ${toString tunAutoRouteTableIndex}
  '';

  tproxyUpScript = pkgs.writeShellScript "proxy-suite-tproxy-up" ''
    set -euo pipefail

    # Start from a clean policy-routing state.  `ip rule add` permits duplicate
    # rules on some iproute2 versions, and a stale rule can keep packets routed
    # into a dead local table after a failed restart.
    ${builders.mkNftDeleteTable { inherit nft; family = "ip"; table = "singbox"; }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      fwmark = globalTproxy.fwmark;
      table = globalTproxy.routeTable;
    }}
    ${builders.mkIpLocalDefaultRouteDelete { inherit ip; table = globalTproxy.routeTable; }}

    ${nft} -f ${nftablesRulesFile}
    ${ip} route replace local default dev lo table ${toString globalTproxy.routeTable}
    ${ip} rule add fwmark ${toString globalTproxy.fwmark} table ${toString globalTproxy.routeTable}
  '';

  tproxyDownScript = pkgs.writeShellScript "proxy-suite-tproxy-down" ''
    set +e

    ${builders.mkNftDeleteTable { inherit nft; family = "ip"; table = "singbox"; }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      fwmark = globalTproxy.fwmark;
      table = globalTproxy.routeTable;
    }}
    ${builders.mkIpLocalDefaultRouteDelete { inherit ip; table = globalTproxy.routeTable; }}
  '';

  tunCleanupScript = pkgs.writeShellScript "proxy-suite-tun-cleanup" ''
    set +e

    # SingBox normally removes these on graceful shutdown, but stale
    # auto_route/auto_redirect state leaves the host routing through a dead TUN
    # interface after `proxy-ctl tun off` or an unclean service stop.
    ${builders.mkNftDeleteTable { inherit nft; family = "inet"; table = "sing-box"; }}
    ${builders.mkIpRuleDeleteByTable { inherit ip; family = "-4"; table = tunAutoRouteTableIndex; }}
    ${builders.mkIpRuleDeleteByTable { inherit ip; family = "-6"; table = tunAutoRouteTableIndex; }}
    ${builders.mkIpRuleDeleteByPriority {
      inherit ip;
      family = "-4";
      priority = xrayTunPerAppTproxyRulePriority;
    }}
    ${builders.mkIpRuleDeleteByPriority {
      inherit ip;
      family = "-4";
      priority = xrayTunPerAppTunRulePriority;
    }}
    ${builders.mkIpRuleDeleteByPriority {
      inherit ip;
      family = "-6";
      priority = xrayTunPerAppTunRulePriority;
    }}
    ${builders.mkIpRouteFlushTable { inherit ip; family = "-4"; table = tunAutoRouteTableIndex; }}
    ${builders.mkIpRouteFlushTable { inherit ip; family = "-6"; table = tunAutoRouteTableIndex; }}
    ${builders.mkIpLinkDelete { inherit ip; interface = globalTun.interface; }}
    ${builders.flushResolvedCaches}
  '';
}
