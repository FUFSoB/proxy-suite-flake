# Per-app TUN and TProxy backend lifecycle scripts.
{
  lib,
  pkgs,
  builders,
  perAppRoutingTun,
  perAppRoutingTproxy,
  ipv6,
  constants,
  perAppTunChainFile,
  perAppTproxyRulesFile,
  ip,
  nft,
  seqBin,
  sleepBin,
}:

let
  inherit (constants)
    perAppTunIPv6Address
    perAppTunIPv6RoutePrefix
    ;

  perAppTunWaitForInterface = pkgs.writeShellScript "proxy-suite-per-app" ''
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

  perAppTunUpScript = pkgs.writeShellScript "proxy-suite-per-app" ''
    set -euo pipefail

    tun_cidr=${lib.escapeShellArg perAppRoutingTun.address}
    tun6_cidr=${lib.escapeShellArg perAppTunIPv6Address}
    tun6_route_prefix=${lib.escapeShellArg perAppTunIPv6RoutePrefix}
    tun_addr=""
    tun_route_prefix=""

    ${builders.cidrNetworkFunction}

    ${builders.mkNftDeleteTable {
      inherit nft;
      family = "inet";
      table = "proxy_suite_per_app_tun";
    }}
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
    ${builders.mkIpRouteFlushTable {
      inherit ip;
      family = "-4";
      table = perAppRoutingTun.routeTable;
    }}
    ${builders.mkIpRouteFlushTable {
      inherit ip;
      family = "-6";
      table = perAppRoutingTun.routeTable;
    }}
    ${nft} -f ${perAppTunChainFile}
    ${perAppTunWaitForInterface}
    tun_addr="''${tun_cidr%%/*}"
    tun_route_prefix="$(cidr_network "$tun_cidr")"
    ${ip} -4 addr replace "$tun_cidr" dev ${lib.escapeShellArg perAppRoutingTun.interface}
    ${ip} -4 route replace "$tun_route_prefix" dev ${lib.escapeShellArg perAppRoutingTun.interface} src "$tun_addr" table ${toString perAppRoutingTun.routeTable}
    # No uplink src, as in xrayTunUpScript: it goes stale when the uplink address changes.
    ${ip} -4 route replace default dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable}
    ${ip} -4 rule add fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
    ${
      if ipv6 then
        ''
          ${ip} -6 addr replace "$tun6_cidr" dev ${lib.escapeShellArg perAppRoutingTun.interface}
          ${ip} -6 route replace "$tun6_route_prefix" dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable}
          ${ip} -6 route replace default dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable}
        ''
      else
        ''
          # No IPv6 in the app TUN: unreachable, so wrapped apps fall back to IPv4 instead of
          # leaving directly.
          ${ip} -6 route replace unreachable default table ${toString perAppRoutingTun.routeTable}
        ''
    }
    ${ip} -6 rule add fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
  '';

  perAppTunDownScript = pkgs.writeShellScript "proxy-suite-per-app" ''
    set +e

    # Best-effort cleanup for graceful stops and for unclean previous exits.
    ${builders.mkNftDeleteTable {
      inherit nft;
      family = "inet";
      table = "proxy_suite_per_app_tun";
    }}
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
    ${builders.mkIpRouteFlushTable {
      inherit ip;
      family = "-4";
      table = perAppRoutingTun.routeTable;
    }}
    ${builders.mkIpRouteFlushTable {
      inherit ip;
      family = "-6";
      table = perAppRoutingTun.routeTable;
    }}
    ${builders.mkIpLinkDelete {
      inherit ip;
      interface = perAppRoutingTun.interface;
    }}
    ${builders.flushResolvedCaches}
  '';

  perAppTproxyUpScript = pkgs.writeShellScript "proxy-suite-per-app" ''
    set -euo pipefail

    ${builders.mkNftDeleteTable {
      inherit nft;
      family = "inet";
      table = "proxy_suite_per_app_tproxy";
    }}
    ${builders.mkTproxyRoutingDown {
      inherit ip;
      fwmark = perAppRoutingTproxy.fwmark;
      table = perAppRoutingTproxy.routeTable;
    }}

    ${nft} -f ${perAppTproxyRulesFile}
    ${builders.mkTproxyRoutingUp {
      inherit ip;
      inherit ipv6;
      fwmark = perAppRoutingTproxy.fwmark;
      table = perAppRoutingTproxy.routeTable;
    }}
  '';

  perAppTproxyDownScript = pkgs.writeShellScript "proxy-suite-per-app" ''
    set +e

    ${builders.mkNftDeleteTable {
      inherit nft;
      family = "inet";
      table = "proxy_suite_per_app_tproxy";
    }}
    ${builders.mkTproxyRoutingDown {
      inherit ip;
      fwmark = perAppRoutingTproxy.fwmark;
      table = perAppRoutingTproxy.routeTable;
    }}
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
