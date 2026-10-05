# TProxy nftables rules
{
  lib,
  pkgs,
  cfg,
}:

let
  inherit (import ./derived.nix { inherit lib cfg; })
    constants
    killSwitchEnabled
    awgGlobalProfiles
    awgGlobalAvailable
    awgRuntimeGlobal
    perAppViaMarks
    perAppPinTproxy
    perAppPinTun
    perAppPinSlots
    ;
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
  # Apps run `--via` an AmneziaWG interface are routed into it, not into the proxy.
  perAppViaMarkLine = lib.optionalString (perAppViaMarks != [ ]) ''
    meta mark { ${lib.concatMapStringsSep ", " toString perAppViaMarks} } return
  '';

  # Shared across the rule files; redefine, as the firewall's ruleset includes several at once.
  reservedIpBlock = ''
    redefine RESERVED_IP = {
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
    redefine RESERVED_IP6 = {
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
    + tproxyIPv6RefuseLine "iifname ${lanInterfaceSet} "
  );
  # Without proxy.ipv6 nothing takes IPv6: marked all the same, it meets the unreachable
  # route mkTproxyRoutingUp puts in the table, and apps fall back to IPv4; on-link prefixes
  # still go by the main table.
  tproxyIPv6RefuseLine =
    prefix:
    lib.optionalString (!proxyCfg.ipv6) ''
      ${prefix}meta nfproto ipv6 meta mark set ${toString globalTproxy.fwmark}
    '';
  perAppTproxyLocalSubnetLines = mkLocalSubnetLines perAppTproxy.localSubnets;

  # Without ipv6, IPv6 packets are left alone, as if the table were still `ip`.
  tproxyProtocols = "${
    lib.optionalString (!proxyCfg.ipv6) "meta nfproto ipv4 "
  }meta l4proto { tcp, udp }";
  # Both listeners share the port; `tproxy ip`/`tproxy ip6` only match their own family.
  # `mark` before the tproxy: with no listener tproxy ends the rule, and an unmarked gateway
  # client's packet would be forwarded out direct.
  mkTproxyLinesTo = port: prefix: mark: ''
    ${prefix}meta nfproto ipv4 meta l4proto { tcp, udp }${mark} tproxy ip to 127.0.0.1:${toString port}
    ${lib.optionalString proxyCfg.ipv6 "${prefix}meta nfproto ipv6 meta l4proto { tcp, udp }${mark} tproxy ip6 to [::1]:${toString port}"}
  '';
  mkTproxyLines = mkTproxyLinesTo globalTproxy.port;
  # The families a TProxy mark carries into the proxy.
  tproxyMarkedFamilies = lib.optionalString (!proxyCfg.ipv6) "meta nfproto ipv4 ";

  # A marked packet leaving by another interface: its ip rule is gone (`ip rule flush`, a
  # VPN tool) and the main table sends it out the uplink, past the kill switch, which lets
  # marked packets by. `match`: TProxy without proxy.ipv6 sends on-link IPv6 out marked.
  mkMisroutedGuard = mark: interfaces: match: ''
    chain misrouted {
        type filter hook postrouting priority filter; policy accept;
        ${match}meta mark ${toString mark} oifname != { ${
          lib.concatMapStringsSep ", " (i: ''"${i}"'') interfaces
        } } drop
    }
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
                  # Past lanInterfaces, only what the output chain below marked: a neighbour
                  # routing through this host is never handed the proxy's exits.
        ${mkTproxyLines "meta mark ${toString globalTproxy.fwmark} " ""}
              }
    ${killSwitchForwardTag}
              chain output {
                  type route hook output priority mangle; policy accept;
        ${reservedLines}
        ${tproxyLocalSubnetLines}
                  meta mark ${toString globalTproxy.proxyMark} return
                  # Replies to connections from outside, and proxy-suite's own daemons (the
                  # inbound XRay dials unmarked, lacking CAP_NET_ADMIN), leave as they are.
                  ct direction reply return
                  meta skuid ${constants.ownTrafficUsersNft} return
    ${tgWsProxyBypassMarkLine}${perAppViaMarkLine}${lib.optionalString perAppTun.enable "              meta mark ${toString perAppTun.fwmark} return\n"}${lib.optionalString perAppTproxy.enable "              meta mark ${toString perAppTproxy.fwmark} return\n"}              ${tproxyProtocols} meta mark set ${toString globalTproxy.fwmark}
    ${tproxyIPv6RefuseLine ""}
              }
    ${mkMisroutedGuard globalTproxy.fwmark [ "lo" ] tproxyMarkedFamilies}
          }
  '';

  # A marked app's lookup of a loopback resolver would be answered outside the route: the
  # forwarder on `dnsPort` asks again through it. `everywhere`: every lookup (TProxy's case).
  mkDnsRedirect =
    {
      mark,
      dnsPort,
      everywhere ? false,
    }:
    let
      lookup = "meta mark ${toString mark} meta l4proto { tcp, udp } th dport 53";
      to = "redirect to :${toString dnsPort}";
    in
    if everywhere then
      ''
        chain dns_redirect {
            type nat hook output priority dstnat; policy accept;
            ${lookup} ip daddr != ${constants.perAppDnsUpstream} ${to}
            ${lookup} meta nfproto ipv6 ${to}
        }
      ''
    else
      ''
        chain dns_redirect {
            type nat hook output priority dstnat; policy accept;
            ${lookup} ip daddr 127.0.0.0/8 ${to}
            ${lookup} ip6 daddr ::1 ${to}
        }
      '';

  # Per-app TProxy, and a pin slot of it (perAppRouting.via): `mark` on the app's packets, which
  # the backend takes on `port`.
  mkPerAppTproxyRules =
    {
      table,
      mark,
      port,
      dnsPort,
    }:
    ''
          ${reservedIpBlock}
            table inet ${table} {
                # The per-user cgroup mark rules are added here at runtime (user-rules.nix).
                # Defined first: a jump only resolves to a chain nft has already read.
                chain app_mark {
                }
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
                    ct mark ${toString mark} meta mark set ${toString mark}
          ${mkTproxyLinesTo port "meta mark ${toString mark} " ""}
                }

                chain output {
                    type route hook output priority mangle; policy accept;
                    meta mark ${toString globalTproxy.proxyMark} return
                    ct direction reply return
      ${lib.optionalString perAppTun.enable "              meta mark ${toString perAppTun.fwmark} return\n"}              ct mark ${toString mark} meta mark set ${toString mark}
                    # The DNS forwarder's own queries carry the mark on the socket alone: the
                    # connection takes it too, for prerouting to restore.
                    meta mark ${toString mark} ct mark set ${toString mark} return
                    # A lookup goes through the route wherever its resolver is (dns_redirect).
                    meta l4proto { tcp, udp } th dport 53 goto app_mark
          ${reservedLines}
          ${perAppTproxyLocalSubnetLines}
                    goto app_mark
                }
      ${mkDnsRedirect {
        inherit mark dnsPort;
        everywhere = true;
      }}
      ${mkMisroutedGuard mark [ "lo" ] tproxyMarkedFamilies}
            }
    '';

  perAppTproxyRulesFile = pkgs.writeText "proxy-suite-routing" (mkPerAppTproxyRules {
    table = "proxy_suite_per_app_tproxy";
    mark = perAppTproxy.fwmark;
    inherit (globalTproxy) port;
    dnsPort = constants.perAppTproxyDnsBasePort;
  });
  perAppPinTproxyRulesFiles = lib.genList (
    slot:
    pkgs.writeText "proxy-suite-routing" (mkPerAppTproxyRules {
      table = "proxy_suite_per_app_via_tproxy_${toString slot}";
      mark = constants.perAppPinTproxyFwmarkBase + slot;
      port = constants.perAppPinTproxyPortBase + slot;
      dnsPort = constants.perAppTproxyDnsBasePort + 1 + slot;
    })
  ) (if perAppPinTproxy then perAppPinSlots else 0);

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
  ++ lib.optional awgGlobalAvailable constants.awgGlobalFwmark
  ++ perAppViaMarks
  ++ killSwitchPinTproxyMarks
  ++ lib.optionals perAppPinTun (
    lib.genList (slot: constants.perAppPinTunFwmarkBase + slot) perAppPinSlots
  )
  # zapret's fakes and split segments carry its desync marks; rejected, split connections stall.
  ++ lib.optionals cfg.zapret.enable [
    1073741824 # 0x40000000, the global instance's (zapret2's, and zapret v1's default)
    536870912 # 0x20000000
  ]
  ++ lib.optionals zapretApp.enable [
    134217728 # 0x8000000, the per-app instance's (zapret/packages.nix, zapret2.nix)
    67108864 # 0x4000000
  ];
  killSwitchPinTproxyMarks = lib.optionals perAppPinTproxy (
    lib.genList (slot: constants.perAppPinTproxyFwmarkBase + slot) perAppPinSlots
  );
  # TProxy's marks carry only the families it takes into the proxy; without proxy.ipv6 a
  # marked IPv6 packet leaving at all is on-link or lost its ip rule.
  killSwitchTproxyMarks = [
    globalTproxy.fwmark
  ]
  ++ lib.optional perAppTproxy.enable perAppTproxy.fwmark
  ++ killSwitchPinTproxyMarks;
  killSwitchMarkLines =
    let
      set = marks: "{ ${lib.concatMapStringsSep ", " toString (lib.unique marks)} }";
    in
    if proxyCfg.ipv6 then
      "meta mark ${set killSwitchMarks} accept"
    else
      ''
        meta mark ${set (lib.subtractLists killSwitchTproxyMarks killSwitchMarks)} accept
        meta nfproto ipv4 meta mark ${set killSwitchTproxyMarks} accept
      '';
  awgGlobalInterfaces =
    lib.mapAttrsToList (_: profile: profile.interfaceName) awgGlobalProfiles
    ++ lib.optional awgRuntimeGlobal cfg.amneziaWg.runtime.interfaceName;
  globalTunEnabled = proxyCfg.enable && proxyCfg.tun.enable;
  # Forwarded traffic (containers, VMs) follows the routes TUN and a global AmneziaWG profile
  # take over, and leaves by the uplink once they go: held to the LAN until one is back.
  # TProxy diverts none of it, so while TProxy is up (its table tags it) it passes.
  killSwitchForward = globalTunEnabled || awgGlobalAvailable;
  killSwitchForwardTag = lib.optionalString (killSwitchEnabled && killSwitchForward) ''
    chain forward {
        type filter hook forward priority mangle; policy accept;
        ${
          lib.optionalString (globalTproxy.lanInterfaces != [ ]) "iifname != ${lanInterfaceSet} "
        }meta mark set meta mark or ${toString constants.killSwitchForwardMark}
    }
  '';
  killSwitchTunnelInterfaces =
    lib.optional globalTunEnabled proxyCfg.tun.interface
    ++ lib.optionals awgGlobalAvailable awgGlobalInterfaces;
  killSwitchAllowLines = ''
    ip daddr $RESERVED_IP accept
    ip6 daddr $RESERVED_IP6 accept
    ${lib.concatMapStrings (cidr: ''
      ${ipFamily cidr} daddr ${cidr} accept
    '') cfg.killSwitch.allowedSubnets}
    ct direction reply accept
  '';
  killSwitchRulesFile = pkgs.writeText "proxy-suite-routing" ''
    ${reservedIpBlock}
    table inet proxy_suite_killswitch {
        # The time daemons' uids, added by the up script: nft refuses a rule naming a user
        # that does not exist.
        set time_sync_uids {
            type uid
        }
        chain output {
            type filter hook output priority filter; policy accept;
            oifname "lo" accept
            meta skuid ${constants.ownTrafficUsersNft} accept
    ${lib.optionalString globalTunEnabled ''
      oifname "${proxyCfg.tun.interface}" accept
      # sing-box's auto_redirect hands DNS to the TUN by rewriting it to the TUN's peer,
      # while the route still points at the uplink.
      ip daddr ${proxyCfg.tun.address} accept
      ${lib.optionalString proxyCfg.ipv6 "ip6 daddr ${constants.globalTunIPv6Address} accept"}
    ''}
    ${lib.optionalString awgGlobalAvailable ''
      oifname { ${lib.concatMapStringsSep ", " (i: ''"${i}"'') awgGlobalInterfaces} } accept
      meta skgid "${constants.awgGlobalGroup}" accept
    ''}
    ${lib.optionalString (
      cfg.sshProxy.enable && sshProxyUser != null && sshProxyUser != serviceUser
    ) ''meta skuid "${sshProxyUser}" accept''}
    ${killSwitchMarkLines}
            # A lookup the proxy did not take would name every site to the LAN resolver.
            meta l4proto { tcp, udp } th dport 53 reject with icmpx admin-prohibited
    ${killSwitchAllowLines}
            # DHCP keeps the uplink, NTP the clock TLS needs: from privileged ports or time daemons
            # only, so no app's port-123 request learns the uplink address.
            meta nfproto ipv4 udp sport 68 udp dport 67 accept
            meta nfproto ipv6 udp sport 546 udp dport 547 accept
            udp sport 123 udp dport 123 accept
            meta skuid @time_sync_uids udp dport 123 accept
            reject with icmpx admin-prohibited
        }
    ${lib.optionalString (killSwitchForward || globalTproxy.lanInterfaces != [ ]) ''
      # Gateway clients: what TProxy does not divert goes to the LAN only. Containers and VMs
      # too while no TUN or AmneziaWG tunnel, nor TProxy, is up.
      chain forward {
          type filter hook forward priority filter; policy accept;
      ${lib.optionalString killSwitchForward ''
        oifname { ${lib.concatMapStringsSep ", " (i: ''"${i}"'') killSwitchTunnelInterfaces} } accept
        ${lib.optionalString globalTproxy.enable "meta mark and ${toString constants.killSwitchForwardMark} != 0 accept"}
      ''}
      ${killSwitchAllowLines}
      ${
        if killSwitchForward then
          "reject with icmpx admin-prohibited"
        else
          "iifname ${lanInterfaceSet} reject with icmpx admin-prohibited"
      }
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

  # Per-app TUN, and a pin slot of it: `mark` on the app's packets routes them into the TUN.
  # `snat`: the addresses a pin slot's packets enter the TUN from, which the backend tells the
  # slot by. The app picked its source on the host's route, before the mark moved it here.
  mkPerAppTunChain =
    {
      table,
      mark,
      dnsPort,
      snat ? null,
    }:
    ''
          ${reservedIpBlock}
            table inet ${table} {
                # The per-user cgroup mark rules are added here at runtime; `output` reaches it
                # by two paths, so they are written once. Defined first: a jump only resolves
                # to a chain nft has already read.
                chain app_mark {
                }
                chain output {
                    type route hook output priority mangle; policy accept;
                    # Replies to connections from outside leave the way they came, not through the TUN.
                    ct direction reply return
                    ct mark ${toString mark} meta mark set ${toString mark}
                    meta mark ${toString mark} return
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
      ${mkDnsRedirect { inherit mark dnsPort; }}
      ${mkMisroutedGuard mark [
        "lo"
        perAppTun.interface
      ] ""}
      ${lib.optionalString (snat != null) ''
        chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "${perAppTun.interface}" meta mark ${toString mark} meta nfproto ipv4 snat ip to ${snat.ipv4}
            ${lib.optionalString proxyCfg.ipv6 ''oifname "${perAppTun.interface}" meta mark ${toString mark} meta nfproto ipv6 snat ip6 to ${snat.ipv6}''}
        }
      ''}
            }
    '';

  perAppTunChainFile = pkgs.writeText "proxy-suite-routing" (mkPerAppTunChain {
    table = "proxy_suite_per_app_tun";
    mark = perAppTun.fwmark;
    dnsPort = constants.perAppTunDnsBasePort;
  });
  perAppPinTunChainFiles = lib.genList (
    slot:
    pkgs.writeText "proxy-suite-routing" (mkPerAppTunChain {
      table = "proxy_suite_per_app_via_tun_${toString slot}";
      mark = constants.perAppPinTunFwmarkBase + slot;
      dnsPort = constants.perAppTunDnsBasePort + 1 + slot;
      snat = constants.perAppPinTunSource slot;
    })
  ) (if perAppPinTun then perAppPinSlots else 0);

  ip = "${pkgs.iproute2}/bin/ip";
  nft = "${pkgs.nftables}/bin/nft";

in
{
  inherit
    reservedIpBlock
    nftablesRulesFile
    killSwitchRulesFile
    perAppTproxyRulesFile
    perAppPinTproxyRulesFiles
    perAppZapretRulesFile
    perAppTunChainFile
    perAppPinTunChainFiles
    ip
    nft
    ;
}
