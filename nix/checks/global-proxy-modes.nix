{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
  mkBadFixture,
  mkFailingAssertions,
  mkTunConfig,
  mkTProxyConfig,
  mkTProxyNftRules,
  mkNftRules,
  dnsServerByTag,
  checkConstants,
}:

let
  inherit (checkLib) ok;
  fixtures = import ./global-proxy-modes/fixtures.nix {
    inherit
      evalProxySuite
      baseModule
      mkBadFixture
      mkFailingAssertions
      mkTunConfig
      mkTProxyConfig
      mkTProxyNftRules
      mkNftRules
      ;
  };

  inherit (fixtures)
    invalidGlobalProxyModeAssertions
    tproxyAutostartFixture
    tproxyManualFixture
    tproxyManualStartScript
    tproxyManualStopScript
    tproxyManualConfig
    tproxyManualNftRules
    tproxyLanFixture
    tproxyLanNftRules
    tproxyLanStartScript
    killSwitchFixture
    killSwitchNftRules
    awgKillSwitchFixture
    awgKillSwitchNftRules
    awgKillSwitchPrepare
    tproxyIPv4OnlyStartScript
    tproxyIPv4OnlyConfig
    tproxyIPv4OnlyNftRules
    ipv4OnlyTunConfig
    ipv4OnlyPerAppTunUpScript
    xrayIPv4OnlyTunConfig
    xrayIPv4OnlyTunUpScript
    tproxyWithFirewall
    tunAutostartFixture
    tunCleanupScript
    tunDefaultConfig
    tunManualFixture
    tunServiceConfig
    ;
in
{
  assertions = [
    (ok (tproxyWithFirewall.config.networking.firewall.enable))
    (
      assert tproxyManualFixture.config.services.proxy-suite.proxy.autostart == null;
      assert tproxyManualFixture.config.systemd.services."proxy-suite-tproxy".wantedBy == [ ];
      true
    )
    (
      assert
        tproxyAutostartFixture.config.systemd.services."proxy-suite-tproxy".wantedBy
        == [ "multi-user.target" ];
      true
    )
    (
      assert pkgs.lib.hasInfix "set -euo pipefail" tproxyManualStartScript;
      assert pkgs.lib.hasInfix "rule del fwmark 1 table 100" tproxyManualStartScript;
      assert pkgs.lib.hasInfix "route replace local default dev lo table 100" tproxyManualStartScript;
      assert pkgs.lib.hasInfix "set +e" tproxyManualStopScript;
      true
    )
    # Gateway clients: diverted past the LAN destinations, let through the host firewall by
    # mark only, with forwarding for the rest.
    (
      let
        cfg = tproxyLanFixture.config;
        rules = tproxyLanNftRules;
        at =
          needle:
          pkgs.lib.lists.findFirstIndex (pkgs.lib.hasInfix needle) null (pkgs.lib.splitString "\n" rules);
      in
      assert pkgs.lib.hasInfix
        ''iifname { "br0" } meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:1085 meta mark set 1''
        rules;
      assert pkgs.lib.hasInfix ''iifname { "br0" } meta l4proto { tcp, udp } tproxy ip6'' rules;
      assert at "ip daddr 192.168.0.0/16 tcp dport != 53 return" < at ''iifname { "br0" }'';
      assert at ''iifname { "br0" }'' < at "ip saddr $RESERVED_IP return";
      assert pkgs.lib.hasInfix ''iifname "br0" meta mark 1 accept''
        cfg.networking.firewall.extraInputRules;
      assert pkgs.lib.hasInfix ''iifname "br0" meta mark 1 accept''
        cfg.networking.firewall.extraReversePathFilterRules;
      assert !builtins.elem "br0" cfg.networking.firewall.trustedInterfaces;
      assert cfg.boot.kernel.sysctl."net.ipv4.ip_forward" == 1;
      assert pkgs.lib.hasInfix "sysctl -q -w net.ipv4.ip_forward=1" tproxyLanStartScript;
      assert !(pkgs.lib.hasInfix "iifname {" tproxyManualNftRules);
      assert !(pkgs.lib.hasInfix "sysctl" tproxyManualStartScript);
      true
    )
    # The kill switch: pulled in by both modes, but not stopped with them; it lets the proxy's
    # own traffic and its DNS hand-off past, and cuts gateway clients off from the internet.
    (
      let
        units = killSwitchFixture.config.systemd.services;
        ks = units."proxy-suite-killswitch";
        rules = killSwitchNftRules;
        before =
          a: b:
          pkgs.lib.lists.findFirstIndex (pkgs.lib.hasInfix a) null (pkgs.lib.splitString "\n" rules)
          < pkgs.lib.lists.findFirstIndex (pkgs.lib.hasInfix b) null (pkgs.lib.splitString "\n" rules);
      in
      assert builtins.elem "proxy-suite-killswitch.service" units."proxy-suite-tun".wants;
      assert builtins.elem "proxy-suite-killswitch.service" units."proxy-suite-tproxy".wants;
      assert !(units."proxy-suite-tun" ? bindsTo) || units."proxy-suite-tun".bindsTo == [ ];
      assert !(ks ? partOf) || ks.partOf == [ ];
      assert builtins.elem "proxy-suite-tun.service" ks.after;
      assert ks.wantedBy == [ ];
      assert pkgs.lib.hasInfix ''meta skuid "proxy-suite-daemon" accept'' rules;
      assert pkgs.lib.hasInfix "meta mark { 1, 2 } accept" rules;
      assert pkgs.lib.hasInfix ''oifname "singtun0" accept'' rules;
      assert before "ip daddr 172.19.0.1/30 accept" "th dport 53 reject";
      assert before "th dport 53 reject" "ip daddr $RESERVED_IP accept";
      assert pkgs.lib.hasInfix ''iifname { "br0" } reject'' rules;
      assert !(tproxyManualFixture.config.systemd.services ? "proxy-suite-killswitch");
      true
    )
    # A global AmneziaWG profile under the kill switch: a mark the rules know, its interface,
    # and a group for awg-quick's own lookups. Stopping the profile no longer lifts it.
    (
      let
        cfg = awgKillSwitchFixture.config;
        units = cfg.systemd.services;
        home = units.proxy-suite-awg-home;
        rules = awgKillSwitchNftRules;
      in
      assert builtins.elem "proxy-suite-killswitch.service" home.wants;
      assert builtins.elem "proxy-suite-awg-home.service" units.proxy-suite-killswitch.after;
      assert !builtins.elem "proxy-suite-killswitch.service" (home.conflicts or [ ]);
      assert (units.proxy-suite-killswitch.conflicts or [ ]) == [ ];
      assert home.serviceConfig.Group == "proxy-suite-awg";
      assert cfg.users.groups ? proxy-suite-awg;
      assert pkgs.lib.hasInfix "--fwmark 51820" awgKillSwitchPrepare;
      assert pkgs.lib.hasInfix ''meta skgid "proxy-suite-awg" accept'' rules;
      assert pkgs.lib.hasInfix
        ''oifname { "${cfg.services.proxy-suite.amneziaWg.profiles.home.interfaceName}" } accept''
        rules;
      assert pkgs.lib.hasInfix "meta mark { 1, 2, 51820 } accept" rules;
      assert !(pkgs.lib.hasInfix "skgid" killSwitchNftRules);
      assert !(units.proxy-suite-awg-home-watchdog.serviceConfig ? Group);
      true
    )
    # IPv6 goes through the same port on ::1; without it IPv6 is left alone.
    (
      let
        tproxyTags =
          config:
          map (inbound: inbound.tag) (builtins.filter (inbound: inbound.type == "tproxy") config.inbounds);
      in
      assert pkgs.lib.hasInfix "delete table inet singbox" tproxyManualStartScript;
      assert pkgs.lib.hasInfix "-6 route replace local default dev lo table 100" tproxyManualStartScript;
      assert pkgs.lib.hasInfix "-6 rule add fwmark 1 table 100" tproxyManualStartScript;
      assert pkgs.lib.hasInfix "-6 rule del fwmark 1 table 100" tproxyManualStopScript;
      assert pkgs.lib.hasInfix "table inet singbox" tproxyManualNftRules;
      assert pkgs.lib.hasInfix "meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:1085 meta mark set 1"
        tproxyManualNftRules;
      assert pkgs.lib.hasInfix "meta l4proto { tcp, udp } tproxy ip6 to [::1]:1085 meta mark set 1"
        tproxyManualNftRules;
      assert
        tproxyTags tproxyManualConfig == [
          "tproxy-in"
          "tproxy-in6"
        ];
      assert !(pkgs.lib.hasInfix "-6 rule add" tproxyIPv4OnlyStartScript);
      assert pkgs.lib.hasInfix "-6 rule del fwmark 1 table 100" tproxyIPv4OnlyStartScript;
      assert !(pkgs.lib.hasInfix "tproxy ip6" tproxyIPv4OnlyNftRules);
      assert pkgs.lib.hasInfix "meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set 1"
        tproxyIPv4OnlyNftRules;
      assert tproxyTags tproxyIPv4OnlyConfig == [ "tproxy-in" ];
      true
    )
    # proxy.ipv6 gives the TUNs an IPv6 address: sing-box's strict_route then rejects neither
    # family. Off, they stay IPv4-only and wrapped apps' IPv6 is unreachable.
    (
      let
        tunAddress =
          config:
          (builtins.head (builtins.filter (inbound: inbound.type or "" == "tun") config.inbounds)).address;
        xrayGateway =
          config:
          (builtins.head (builtins.filter (inbound: inbound.protocol or "" == "tun") config.inbounds))
          .settings.gateway;
      in
      assert
        tunAddress tunDefaultConfig == [
          "172.19.0.1/30"
          checkConstants.globalTunIPv6Address
        ];
      assert tunAddress ipv4OnlyTunConfig == [ "172.19.0.1/30" ];
      assert pkgs.lib.hasInfix "-6 route replace unreachable default table 101" ipv4OnlyPerAppTunUpScript;
      assert !(pkgs.lib.hasInfix "-6 addr replace" ipv4OnlyPerAppTunUpScript);
      assert xrayGateway xrayIPv4OnlyTunConfig == [ "172.19.0.1/30" ];
      assert !(pkgs.lib.hasInfix "-6 addr replace" xrayIPv4OnlyTunUpScript);
      assert !(pkgs.lib.hasInfix "-6 route replace" xrayIPv4OnlyTunUpScript);
      assert pkgs.lib.hasInfix "rule del fwmark 1 table 100" tproxyManualStopScript;
      true
    )
    (
      assert tunManualFixture.config.services.proxy-suite.proxy.autostart == null;
      assert tunManualFixture.config.systemd.services."proxy-suite-tun".wantedBy == [ ];
      true
    )
    (
      let
        inbound = builtins.head (builtins.filter (item: item.tag == "tun-in") tunDefaultConfig.inbounds);
      in
      assert inbound.iproute2_table_index == checkConstants.tunAutoRouteTableIndex;
      assert inbound.iproute2_rule_index == checkConstants.tunAutoRouteRulePriority;
      assert tunDefaultConfig.route.auto_detect_interface == true;
      true
    )
    (ok (tunManualFixture.config.networking.nftables.enable))
    (
      assert tunServiceConfig.ExecStartPre == tunServiceConfig.ExecStopPost;
      assert pkgs.lib.hasInfix "delete table inet sing-box" tunCleanupScript;
      assert pkgs.lib.hasInfix "rule del table ${toString checkConstants.tunAutoRouteTableIndex}"
        tunCleanupScript;
      assert pkgs.lib.hasInfix "rule del pref ${toString checkConstants.xrayTunPerAppTunRulePriority}"
        tunCleanupScript;
      assert pkgs.lib.hasInfix "route flush table ${toString checkConstants.tunAutoRouteTableIndex}"
        tunCleanupScript;
      assert pkgs.lib.hasInfix "link del dev" tunCleanupScript;
      assert pkgs.lib.hasInfix "singtun0" tunCleanupScript;
      true
    )
    (
      assert
        tunAutostartFixture.config.systemd.services."proxy-suite-tun".wantedBy == [ "multi-user.target" ];
      true
    )
    (
      let
        localDns = dnsServerByTag tunDefaultConfig "local";
      in
      assert !(localDns ? detour);
      true
    )
    (ok (tunDefaultConfig.route.default_domain_resolver == "local"))
    (
      assert builtins.elem "network-online.target"
        tunManualFixture.config.systemd.services."proxy-suite-tun".after;
      assert builtins.elem "network-online.target"
        tunManualFixture.config.systemd.services."proxy-suite-tun".wants;
      true
    )
  ]
  ++ invalidGlobalProxyModeAssertions;
}
