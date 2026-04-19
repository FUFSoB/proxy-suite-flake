# TProxy nftables rules
{
  lib,
  pkgs,
  cfg,
}:

let
  singBoxCfg = cfg.singBox;
  globalTproxy = singBoxCfg.tproxy;
  perAppTun = singBoxCfg.tun.perApp;
  perAppTproxy = singBoxCfg.tproxy.perApp;
  zapretApp = cfg.zapret.perApp;

  # Shared across all three nftables rule files that do IPv4 routing.
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
  '';

  mkLocalSubnetLines =
    subnets:
    lib.concatMapStrings (cidr: ''
      ip daddr ${cidr} tcp dport != 53 return
      ip daddr ${cidr} udp dport != 53 return
    '') subnets;

  tproxyLocalSubnetLines = mkLocalSubnetLines globalTproxy.localSubnets;
  perAppTproxyLocalSubnetLines = mkLocalSubnetLines perAppTproxy.localSubnets;

  nftablesRulesFile = pkgs.writeText "proxy-suite-tproxy.nft" ''
        ${reservedIpBlock}
          table ip singbox {
              chain prerouting {
                  type filter hook prerouting priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
                  # Packets re-entering via loopback after output marking should not
                  # be skipped just because the host has an RFC1918 source address.
                  iifname != "lo" ip saddr $RESERVED_IP return
        ${tproxyLocalSubnetLines}
                  ip protocol tcp tproxy to 127.0.0.1:${toString globalTproxy.port} meta mark set ${toString globalTproxy.fwmark}
                  ip protocol udp tproxy to 127.0.0.1:${toString globalTproxy.port} meta mark set ${toString globalTproxy.fwmark}
              }
              chain output {
                  type route hook output priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
        ${tproxyLocalSubnetLines}
                  meta mark ${toString globalTproxy.proxyMark} return
    ${lib.optionalString perAppTun.enable "              meta mark ${toString perAppTun.fwmark} return\n"}${lib.optionalString perAppTproxy.enable "              meta mark ${toString perAppTproxy.fwmark} return\n"}              ip protocol tcp meta mark set ${toString globalTproxy.fwmark}
                  ip protocol udp meta mark set ${toString globalTproxy.fwmark}
              }
          }
  '';

  perAppTproxyRulesFile = pkgs.writeText "proxy-suite-per-app-tproxy.nft" ''
        ${reservedIpBlock}
          table ip proxy_suite_per_app_tproxy {
              chain prerouting {
                  type filter hook prerouting priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
                  iifname != "lo" ip saddr $RESERVED_IP return
        ${perAppTproxyLocalSubnetLines}
                  ct mark ${toString perAppTproxy.fwmark} meta mark set ${toString perAppTproxy.fwmark}
                  meta mark ${toString perAppTproxy.fwmark} ip protocol tcp tproxy to 127.0.0.1:${toString globalTproxy.port}
                  meta mark ${toString perAppTproxy.fwmark} ip protocol udp tproxy to 127.0.0.1:${toString globalTproxy.port}
              }

              chain output {
                  type route hook output priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
        ${perAppTproxyLocalSubnetLines}
                  meta mark ${toString globalTproxy.proxyMark} return
    ${lib.optionalString perAppTun.enable "              meta mark ${toString perAppTun.fwmark} return\n"}              ct mark ${toString perAppTproxy.fwmark} meta mark set ${toString perAppTproxy.fwmark}
                  meta mark ${toString perAppTproxy.fwmark} return
              }
          }
  '';

  perAppZapretRulesFile = pkgs.writeText "proxy-suite-per-app-zapret.nft" ''
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

  perAppTunChainFile = pkgs.writeText "proxy-suite-per-app-tun-chain.nft" ''
        ${reservedIpBlock}
          table inet proxy_suite_per_app_tun {
              chain output {
                  type route hook output priority mangle; policy accept;
                  ip daddr $RESERVED_IP return
    ${lib.concatMapStrings (cidr: ''
      ip daddr ${cidr} return
    '') perAppTun.localSubnets}
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
    nftablesRulesFile
    perAppTproxyRulesFile
    perAppZapretRulesFile
    perAppTunChainFile
    ip
    nft
    ;
}
