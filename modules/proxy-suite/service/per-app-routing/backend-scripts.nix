# Per-app TUN and TProxy backend lifecycle scripts.
{
  lib,
  pkgs,
  builders,
  pureXrayEnabled,
  perAppRoutingTun,
  perAppRoutingTproxy,
  constants,
  perAppTunChainFile,
  perAppTproxyRulesFile,
  ip,
  nft,
  awk,
  seqBin,
  sleepBin,
}:

let
  defaultUplinkIPv4Source = builders.mkDefaultUplinkIPv4Source {
    inherit ip awk;
    errorMessage = "proxy-suite: could not determine the default uplink IPv4 address for app TUN";
  };

  inherit (constants)
    xrayPerAppTunIPv6Address
    xrayPerAppTunIPv6RoutePrefix
    ;

  perAppTunWaitForInterface = pkgs.writeShellScript "proxy-suite-per-app-tun-wait-for-interface" ''
    set -euo pipefail
    for _ in $(${seqBin} 1 50); do
      if ${ip} link show dev ${lib.escapeShellArg perAppRoutingTun.interface} >/dev/null 2>&1; then
        exit 0
      fi
      ${sleepBin} 0.1
    done
    echo "proxy-suite: app TUN interface ${perAppRoutingTun.interface} did not appear in time" >&2
    exit 1
  '';

  perAppTunUpScript = pkgs.writeShellScript "proxy-suite-per-app-tun-up" ''
    set -euo pipefail

    tun_cidr=${lib.escapeShellArg perAppRoutingTun.address}
    tun6_cidr=${lib.escapeShellArg xrayPerAppTunIPv6Address}
    tun6_route_prefix=${lib.escapeShellArg xrayPerAppTunIPv6RoutePrefix}
    tun_addr=""
    tun_route_prefix=""
    uplink_addr=""

    ${builders.cidrNetworkFunction}

    ${builders.mkNftDeleteTable { inherit nft; family = "inet"; table = "proxy_suite_per_app_tun"; }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      family = "-4";
      fwmark = perAppRoutingTun.fwmark;
      table = perAppRoutingTun.routeTable;
    }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      family = "-6";
      fwmark = perAppRoutingTun.fwmark;
      table = perAppRoutingTun.routeTable;
    }}
    ${builders.mkIpRouteFlushTable { inherit ip; family = "-4"; table = perAppRoutingTun.routeTable; }}
    ${builders.mkIpRouteFlushTable { inherit ip; family = "-6"; table = perAppRoutingTun.routeTable; }}
    ${nft} -f ${perAppTunChainFile}
    ${perAppTunWaitForInterface}
    ${defaultUplinkIPv4Source}
    tun_addr="''${tun_cidr%%/*}"
    tun_route_prefix="$(cidr_network "$tun_cidr")"
    ${ip} -4 addr replace "$tun_cidr" dev ${lib.escapeShellArg perAppRoutingTun.interface}
    ${ip} -4 route replace "$tun_route_prefix" dev ${lib.escapeShellArg perAppRoutingTun.interface} src "$tun_addr" table ${toString perAppRoutingTun.routeTable}
    ${ip} -4 route replace default dev ${lib.escapeShellArg perAppRoutingTun.interface} src "$uplink_addr" table ${toString perAppRoutingTun.routeTable}
    ${ip} -4 rule add fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
    ${lib.optionalString pureXrayEnabled ''
      ${ip} -6 addr replace "$tun6_cidr" dev ${lib.escapeShellArg perAppRoutingTun.interface}
      ${ip} -6 route replace "$tun6_route_prefix" dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable}
      ${ip} -6 route replace default dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable}
      ${ip} -6 rule add fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
    ''}
  '';

  perAppTunDownScript = pkgs.writeShellScript "proxy-suite-per-app-tun-down" ''
    set +e

    # Best-effort cleanup for graceful stops and for unclean previous exits.
    ${builders.mkNftDeleteTable { inherit nft; family = "inet"; table = "proxy_suite_per_app_tun"; }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      family = "-4";
      fwmark = perAppRoutingTun.fwmark;
      table = perAppRoutingTun.routeTable;
    }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      family = "-6";
      fwmark = perAppRoutingTun.fwmark;
      table = perAppRoutingTun.routeTable;
    }}
    ${builders.mkIpRouteFlushTable { inherit ip; family = "-4"; table = perAppRoutingTun.routeTable; }}
    ${builders.mkIpRouteFlushTable { inherit ip; family = "-6"; table = perAppRoutingTun.routeTable; }}
    ${builders.mkIpLinkDelete { inherit ip; interface = perAppRoutingTun.interface; }}
    ${builders.flushResolvedCaches}
  '';

  perAppTproxyUpScript = pkgs.writeShellScript "proxy-suite-per-app-tproxy-up" ''
    set -euo pipefail

    ${builders.mkNftDeleteTable { inherit nft; family = "ip"; table = "proxy_suite_per_app_tproxy"; }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      fwmark = perAppRoutingTproxy.fwmark;
      table = perAppRoutingTproxy.routeTable;
    }}
    ${builders.mkIpLocalDefaultRouteDelete { inherit ip; table = perAppRoutingTproxy.routeTable; }}

    ${nft} -f ${perAppTproxyRulesFile}
    ${ip} route replace local default dev lo table ${toString perAppRoutingTproxy.routeTable}
    ${ip} rule add fwmark ${toString perAppRoutingTproxy.fwmark} table ${toString perAppRoutingTproxy.routeTable}
  '';

  perAppTproxyDownScript = pkgs.writeShellScript "proxy-suite-per-app-tproxy-down" ''
    set +e

    ${builders.mkNftDeleteTable { inherit nft; family = "ip"; table = "proxy_suite_per_app_tproxy"; }}
    ${builders.mkIpRuleDeleteByFwmark {
      inherit ip;
      fwmark = perAppRoutingTproxy.fwmark;
      table = perAppRoutingTproxy.routeTable;
    }}
    ${builders.mkIpLocalDefaultRouteDelete { inherit ip; table = perAppRoutingTproxy.routeTable; }}
  '';
in
{
  inherit
    perAppTunUpScript
    perAppTunDownScript
    perAppTproxyUpScript
    perAppTproxyDownScript
    ;
}
