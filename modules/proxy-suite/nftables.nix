# TProxy nftables rules
{ lib, pkgs, cfg }:

let
  sb = cfg.singBox;

  localSubnetLines = lib.concatMapStrings (cidr: ''
            ip daddr ${cidr} tcp dport != 53 return
            ip daddr ${cidr} udp dport != 53 return
  '') sb.tproxy.localSubnets;

  nftablesRulesFile = pkgs.writeText "proxy-suite-tproxy.nft" ''
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

    table ip singbox {
        chain prerouting {
            type filter hook prerouting priority mangle; policy accept;
            ip daddr $RESERVED_IP return
            # Packets re-entering via loopback after output marking should not
            # be skipped just because the host has an RFC1918 source address.
            iifname != "lo" ip saddr $RESERVED_IP return
  ${localSubnetLines}
            ip protocol tcp tproxy to 127.0.0.1:${toString sb.tproxyPort} meta mark set ${toString sb.fwmark}
            ip protocol udp tproxy to 127.0.0.1:${toString sb.tproxyPort} meta mark set ${toString sb.fwmark}
        }
        chain output {
            type route hook output priority mangle; policy accept;
            ip daddr $RESERVED_IP return
  ${localSubnetLines}
            meta mark ${toString sb.proxyMark} return
            ip protocol tcp meta mark set ${toString sb.fwmark}
            ip protocol udp meta mark set ${toString sb.fwmark}
        }
    }
  '';

  ip = "${pkgs.iproute2}/bin/ip";
  nft = "${pkgs.nftables}/bin/nft";

in
{
  inherit nftablesRulesFile ip nft;
}
