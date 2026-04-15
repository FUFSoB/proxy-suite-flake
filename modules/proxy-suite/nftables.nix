# TProxy nftables rules
{
  lib,
  pkgs,
  cfg,
}:

let
  sb = cfg.singBox;
  art = cfg.appRouting.backends.tun;
  artp = cfg.appRouting.backends.tproxy;
  arz = cfg.appRouting.backends.zapret;

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

  mkLocalSubnetLines = subnets: lib.concatMapStrings (cidr: ''
    ip daddr ${cidr} tcp dport != 53 return
    ip daddr ${cidr} udp dport != 53 return
  '') subnets;

  tproxyLocalSubnetLines = mkLocalSubnetLines sb.tproxy.localSubnets;
  appTproxyLocalSubnetLines = mkLocalSubnetLines artp.localSubnets;

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
              ip protocol tcp tproxy to 127.0.0.1:${toString sb.tproxyPort} meta mark set ${toString sb.fwmark}
              ip protocol udp tproxy to 127.0.0.1:${toString sb.tproxyPort} meta mark set ${toString sb.fwmark}
          }
          chain output {
              type route hook output priority mangle; policy accept;
              ip daddr $RESERVED_IP return
    ${tproxyLocalSubnetLines}
              meta mark ${toString sb.proxyMark} return
${lib.optionalString art.enable "              meta mark ${toString art.fwmark} return\n"}${lib.optionalString artp.enable "              meta mark ${toString artp.fwmark} return\n"}              ip protocol tcp meta mark set ${toString sb.fwmark}
              ip protocol udp meta mark set ${toString sb.fwmark}
          }
      }
  '';

  appTproxyRulesFile = pkgs.writeText "proxy-suite-app-tproxy.nft" ''
    ${reservedIpBlock}
      table ip proxy_suite_app_tproxy {
          chain prerouting {
              type filter hook prerouting priority mangle; policy accept;
              ip daddr $RESERVED_IP return
              iifname != "lo" ip saddr $RESERVED_IP return
    ${appTproxyLocalSubnetLines}
              ct mark ${toString artp.fwmark} meta mark set ${toString artp.fwmark}
              meta mark ${toString artp.fwmark} ip protocol tcp tproxy to 127.0.0.1:${toString sb.tproxyPort}
              meta mark ${toString artp.fwmark} ip protocol udp tproxy to 127.0.0.1:${toString sb.tproxyPort}
          }

          chain output {
              type route hook output priority mangle; policy accept;
              ip daddr $RESERVED_IP return
    ${appTproxyLocalSubnetLines}
              meta mark ${toString sb.proxyMark} return
${lib.optionalString art.enable "              meta mark ${toString art.fwmark} return\n"}              ct mark ${toString artp.fwmark} meta mark set ${toString artp.fwmark}
              meta mark ${toString artp.fwmark} return
          }
      }
  '';

  appZapretRulesFile = pkgs.writeText "proxy-suite-app-zapret.nft" ''
      table inet proxy_suite_app_zapret_mark {
          chain prerouting {
              type filter hook prerouting priority -103; policy accept;
              ct mark and ${toString arz.filterMark} == ${toString arz.filterMark} meta mark set meta mark or ${toString arz.filterMark}
          }

          chain output {
              type route hook output priority -103; policy accept;
              ct mark and ${toString arz.filterMark} == ${toString arz.filterMark} meta mark set meta mark or ${toString arz.filterMark}
              meta mark and ${toString arz.filterMark} == ${toString arz.filterMark} return
          }
      }
  '';

  appTunChainFile = pkgs.writeText "proxy-suite-app-tun-chain.nft" ''
    ${reservedIpBlock}
      table inet proxy_suite_app_tun {
          chain output {
              type route hook output priority mangle; policy accept;
              ip daddr $RESERVED_IP return
${lib.concatMapStrings (cidr: ''
              ip daddr ${cidr} return
  '') art.localSubnets}
              ct mark ${toString art.fwmark} meta mark set ${toString art.fwmark}
              meta mark ${toString art.fwmark} return
          }
      }
  '';

  ip = "${pkgs.iproute2}/bin/ip";
  nft = "${pkgs.nftables}/bin/nft";

in
{
  inherit nftablesRulesFile appTproxyRulesFile appZapretRulesFile appTunChainFile ip nft;
}
