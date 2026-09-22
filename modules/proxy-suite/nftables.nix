# TProxy nftables rules
{
  lib,
  pkgs,
  cfg,
}:

let
  inherit (import ./derived.nix { inherit lib cfg; }) constants awgGlobalProfiles;
  inherit (constants) serviceUser;
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

  # Skipping interception for these ranges excepts DNS, as localSubnets does: a resolver
  # living in one of them (a router on 10.0.0.1, CGNAT, 100.100.100.100) would otherwise
  # answer every name outside the proxy. Loopback is the exception to the exception -
  # taking the stub resolver would bypass its cache, split-DNS and mDNS, and its own
  # upstream queries pass through here anyway.
  reservedLines = ''
    ip daddr 127.0.0.0/8 return
    ip6 daddr ::1/128 return
    ip daddr $RESERVED_IP tcp dport != 53 return
    ip daddr $RESERVED_IP udp dport != 53 return
    ip daddr $RESERVED_IP meta l4proto != { tcp, udp } return
    ip6 daddr $RESERVED_IP6 tcp dport != 53 return
    ip6 daddr $RESERVED_IP6 udp dport != 53 return
    ip6 daddr $RESERVED_IP6 meta l4proto != { tcp, udp } return
  '';

  tproxyLocalSubnetLines = mkLocalSubnetLines globalTproxy.localSubnets;

  lanInterfaceSet = "{ ${lib.concatMapStringsSep ", " (i: ''"${i}"'') globalTproxy.lanInterfaces} }";
  # Devices using this host as their gateway, past the destinations nobody diverts.
  tproxyLanLines = lib.optionalString (globalTproxy.lanInterfaces != [ ]) (
    mkTproxyLines "iifname ${lanInterfaceSet} " " meta mark set ${toString globalTproxy.fwmark}"
  );
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
        ${reservedLines}
                  # Connections to this host itself (inbounds, sshd on a public address)
                  # are served here, not taken by the tproxy socket. A resolver this host
                  # runs for the LAN is one of them.
                  fib daddr type local return
        ${tproxyLocalSubnetLines}
        ${tproxyLanLines}
                  # Packets re-entering via loopback after output marking should not
                  # be skipped just because the host has an RFC1918 source address.
                  iifname != "lo" ip saddr $RESERVED_IP return
                  iifname != "lo" ip6 saddr $RESERVED_IP6 return
        ${mkTproxyLines "" " meta mark set ${toString globalTproxy.fwmark}"}
              }
              chain output {
                  type route hook output priority mangle; policy accept;
        ${reservedLines}
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
        ${reservedLines}
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
        ${reservedLines}
        ${perAppTproxyLocalSubnetLines}
                  meta mark ${toString globalTproxy.proxyMark} return
                  ct direction reply return
    ${lib.optionalString perAppTun.enable "              meta mark ${toString perAppTun.fwmark} return\n"}              ct mark ${toString perAppTproxy.fwmark} meta mark set ${toString perAppTproxy.fwmark}
                  meta mark ${toString perAppTproxy.fwmark} return
              }
          }
  '';

  # Everything proxy-suite sends itself, or has already taken into the proxy, gets past; the
  # rest is what TUN, TProxy or a global AmneziaWG profile would have taken, had it been up.
  sshProxyUser = cfg.sshProxy.serviceUser;
  killSwitchMarks = [
    globalTproxy.fwmark
    globalTproxy.proxyMark
  ]
  ++ lib.optional perAppTun.enable perAppTun.fwmark
  ++ lib.optional perAppTproxy.enable perAppTproxy.fwmark
  ++ lib.optional tgWsProxyBypassEnabled tgWsProxyCfg.fwmark
  ++ lib.optional (awgGlobalProfiles != { }) constants.awgGlobalFwmark;
  awgGlobalInterfaces = lib.mapAttrsToList (_: profile: profile.interfaceName) awgGlobalProfiles;
  globalTunEnabled = proxyCfg.enable && proxyCfg.tun.enable;
  killSwitchAllowLines = ''
    ip daddr $RESERVED_IP accept
    ip6 daddr $RESERVED_IP6 accept
    ${lib.concatMapStrings (cidr: ''
      ${ipFamily cidr} daddr ${cidr} accept
    '') globalTproxy.localSubnets}
    ct direction reply accept
  '';
  killSwitchRulesFile = pkgs.writeText "proxy-suite-routing" ''
    ${reservedIpBlock}
    table inet proxy_suite_killswitch {
        chain output {
            type filter hook output priority filter; policy accept;
            oifname "lo" accept
            meta skuid "${serviceUser}" accept
    ${lib.optionalString globalTunEnabled ''
      oifname "${proxyCfg.tun.interface}" accept
      # sing-box's auto_redirect hands DNS to the TUN by rewriting it to the TUN's peer,
      # while the route still points at the uplink.
      ip daddr ${proxyCfg.tun.address} accept
      ${lib.optionalString proxyCfg.ipv6 "ip6 daddr ${constants.globalTunIPv6Address} accept"}
    ''}
    ${lib.optionalString (awgGlobalProfiles != { }) ''
      oifname { ${lib.concatMapStringsSep ", " (i: ''"${i}"'') awgGlobalInterfaces} } accept
      meta skgid "${constants.awgGlobalGroup}" accept
    ''}
    ${lib.optionalString (
      cfg.sshProxy.enable && sshProxyUser != null && sshProxyUser != serviceUser
    ) ''meta skuid "${sshProxyUser}" accept''}
            meta mark { ${lib.concatMapStringsSep ", " toString (lib.unique killSwitchMarks)} } accept
            # A lookup the proxy did not take would name every site to the LAN resolver.
            meta l4proto { tcp, udp } th dport 53 reject with icmpx admin-prohibited
    ${killSwitchAllowLines}
            # DHCP keeps the uplink, NTP the clock that TLS depends on.
            udp dport { 67, 68, 123 } accept
            reject with icmpx admin-prohibited
        }
    ${lib.optionalString (globalTproxy.lanInterfaces != [ ]) ''
      # Gateway clients: what TProxy does not divert is forwarded, to the LAN only.
      chain forward {
          type filter hook forward priority filter; policy accept;
      ${killSwitchAllowLines}
          iifname ${lanInterfaceSet} reject with icmpx admin-prohibited
      }
    ''}
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
              # The per-user cgroup mark rules are added here at runtime; `output` reaches it
              # by two paths, so they are written once. Defined first: a jump only resolves
              # to a chain nft has already read.
              chain app_mark {
              }
              chain output {
                  type route hook output priority mangle; policy accept;
                  # Replies to connections from outside leave the way they came, not through the TUN.
                  ct direction reply return
                  ct mark ${toString perAppTun.fwmark} meta mark set ${toString perAppTun.fwmark}
                  meta mark ${toString perAppTun.fwmark} return
                  # A wrapped app's DNS goes through the TUN even when its resolver sits on a
                  # local or reserved address, as the global TUN's dport 53 ip rules do:
                  # otherwise names resolve outside the proxy, fake DNS never sees them, and
                  # domain rules match nothing.
                  meta l4proto { tcp, udp } th dport 53 goto app_mark
                  ip daddr $RESERVED_IP return
                  ip6 daddr $RESERVED_IP6 return
    ${lib.concatMapStrings (cidr: ''
      ${ipFamily cidr} daddr ${cidr} return
    '') perAppTun.localSubnets}
                  goto app_mark
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
    killSwitchRulesFile
    perAppTproxyRulesFile
    perAppZapretRulesFile
    perAppTunChainFile
    ip
    nft
    ;
}
