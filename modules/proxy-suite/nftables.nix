# TProxy nftables rules
{
  lib,
  pkgs,
  cfg,
}:

let
  inherit ((import ./derived.nix { inherit lib cfg; }).constants) serviceUser;
  proxyCfg = cfg.proxy;
  globalTproxy = proxyCfg.tproxy;
  perAppTun = cfg.perAppRouting.tun;
  perAppTproxy = cfg.perAppRouting.tproxy;
  zapretApp = cfg.perAppRouting.zapret;
  tgWsProxyCfg = cfg.tgWsProxy;
  tgWsProxyBypassEnabled = tgWsProxyCfg.enable && tgWsProxyCfg.bypassTransparentProxy;
  tgWsProxyBypassMarkLine = lib.optionalString tgWsProxyBypassEnabled ''
    meta mark ${toString tgWsProxyCfg.fwmark} return
  '';

  # Shared across all three nftables rule files that do IP routing.
  reservedIpBlock = ''
    define RESERVED_IP = {
        10.0.0.0/8,
        100.64.0.0/10,
        127.0.0.0/8,
        169.254.0.0/16,
        172.16.0.0/12,
        192.0.0.0/24,
        224.0.0.0/4,
        240.0.0.0/4,
        255.255.255.255/32
    }
    define RESERVED_IP6 = {
        ::/128,
        ::1/128,
        ::ffff:0:0/96,
        fc00::/7,
        fe80::/10,
        ff00::/8
    }
  '';

  ipFamily = cidr: if lib.hasInfix ":" cidr then "ip6" else "ip";

  mkLocalSubnetLines =
    subnets:
    lib.concatMapStrings (cidr: ''
      ${ipFamily cidr} daddr ${cidr} tcp dport != 53 return
      ${ipFamily cidr} daddr ${cidr} udp dport != 53 return
    '') subnets;

  tproxyLocalSubnetLines = mkLocalSubnetLines globalTproxy.localSubnets;
  perAppTproxyLocalSubnetLines = mkLocalSubnetLines perAppTproxy.localSubnets;

  # Without ipv6, IPv6 packets are left alone, as if the table were still `ip`.
  tproxyProtocols = "${
    lib.optionalString (!proxyCfg.ipv6) "meta nfproto ipv4 "
  }meta l4proto { tcp, udp }";
  # Both listeners share the port; `tproxy ip`/`tproxy ip6` only match their own family.
  mkTproxyLines = prefix: suffix: ''
    ${prefix}meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${toString globalTproxy.port}${suffix}
    ${lib.optionalString proxyCfg.ipv6 "${prefix}meta l4proto { tcp, udp } tproxy ip6 to [::1]:${toString globalTproxy.port}${suffix}"}
  '';

  nftablesRulesFile = pkgs.writeText "proxy-suite-routing" ''
        ${reservedIpBlock}
          table inet singbox {
              chain prerouting {
                  type filter hook prerouting priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
                  ip6 daddr $RESERVED_IP6 return
                  # Connections to this host itself (inbounds, sshd on a public address)
                  # are served here, not taken by the tproxy socket.
                  fib daddr type local return
                  # Packets re-entering via loopback after output marking should not
                  # be skipped just because the host has an RFC1918 source address.
                  iifname != "lo" ip saddr $RESERVED_IP return
                  iifname != "lo" ip6 saddr $RESERVED_IP6 return
        ${tproxyLocalSubnetLines}
        ${mkTproxyLines "" " meta mark set ${toString globalTproxy.fwmark}"}
              }
              chain output {
                  type route hook output priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
                  ip6 daddr $RESERVED_IP6 return
        ${tproxyLocalSubnetLines}
                  meta mark ${toString globalTproxy.proxyMark} return
                  # Replies to connections from outside, and proxy-suite's own daemons (the
                  # inbound XRay dials unmarked, lacking CAP_NET_ADMIN), leave as they are.
                  ct direction reply return
                  meta skuid "${serviceUser}" return
    ${tgWsProxyBypassMarkLine}${lib.optionalString perAppTun.enable "              meta mark ${toString perAppTun.fwmark} return\n"}${lib.optionalString perAppTproxy.enable "              meta mark ${toString perAppTproxy.fwmark} return\n"}              ${tproxyProtocols} meta mark set ${toString globalTproxy.fwmark}
              }
          }
  '';

  perAppTproxyRulesFile = pkgs.writeText "proxy-suite-routing" ''
        ${reservedIpBlock}
          table inet proxy_suite_per_app_tproxy {
              chain prerouting {
                  type filter hook prerouting priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
                  ip6 daddr $RESERVED_IP6 return
                  iifname != "lo" ip saddr $RESERVED_IP return
                  iifname != "lo" ip6 saddr $RESERVED_IP6 return
                  # This host's own addresses are served here, not detoured through the proxy.
                  fib daddr type local return
        ${perAppTproxyLocalSubnetLines}
                  # The backend's forged UDP replies belong to the app's flow too; an unconnected
                  # app socket is no match for the tproxy lookup, so the listener would take them.
                  ct direction reply return
                  ct mark ${toString perAppTproxy.fwmark} meta mark set ${toString perAppTproxy.fwmark}
        ${mkTproxyLines "meta mark ${toString perAppTproxy.fwmark} " ""}
              }

              chain output {
                  type route hook output priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
                  ip6 daddr $RESERVED_IP6 return
        ${perAppTproxyLocalSubnetLines}
                  meta mark ${toString globalTproxy.proxyMark} return
                  ct direction reply return
    ${lib.optionalString perAppTun.enable "              meta mark ${toString perAppTun.fwmark} return\n"}              ct mark ${toString perAppTproxy.fwmark} meta mark set ${toString perAppTproxy.fwmark}
                  meta mark ${toString perAppTproxy.fwmark} return
              }
          }
  '';

  perAppZapretRulesFile = pkgs.writeText "proxy-suite-routing" ''
    table inet proxy_suite_per_app_zapret_mark {
        chain prerouting {
            type filter hook prerouting priority -103; policy accept;
            ct mark and ${toString zapretApp.filterMark} == ${toString zapretApp.filterMark} meta mark set meta mark or ${toString zapretApp.filterMark}
        }

        chain output {
            type route hook output priority -103; policy accept;
            ct mark and ${toString zapretApp.filterMark} == ${toString zapretApp.filterMark} meta mark set meta mark or ${toString zapretApp.filterMark}
            meta mark and ${toString zapretApp.filterMark} == ${toString zapretApp.filterMark} return
        }
    }
  '';

  perAppTunChainFile = pkgs.writeText "proxy-suite-routing" ''
        ${reservedIpBlock}
          table inet proxy_suite_per_app_tun {
              chain output {
                  type route hook output priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
    ${lib.concatMapStrings (cidr: ''
      ${ipFamily cidr} daddr ${cidr} return
    '') perAppTun.localSubnets}
                  # Replies to connections from outside leave the way they came, not through the TUN.
                  ct direction reply return
                  ct mark ${toString perAppTun.fwmark} meta mark set ${toString perAppTun.fwmark}
                  meta mark ${toString perAppTun.fwmark} return
              }
          }
  '';

  ip = "${pkgs.iproute2}/bin/ip";
  nft = "${pkgs.nftables}/bin/nft";

in
{
  inherit
    reservedIpBlock
    nftablesRulesFile
    perAppTproxyRulesFile
    perAppZapretRulesFile
    perAppTunChainFile
    ip
    nft
    ;
}
