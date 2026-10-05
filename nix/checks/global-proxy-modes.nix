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
    killSwitchTproxyNftRules
    killSwitchUpScript
    killSwitchSubscriptionUpdate
    tunSubscriptionUpdate
    tproxyKillSwitchNftRules
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
        ''iifname { "br0" } meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set 1 tproxy ip to 127.0.0.1:1085''
        rules;
      assert pkgs.lib.hasInfix
        ''iifname { "br0" } meta nfproto ipv6 meta l4proto { tcp, udp } meta mark set 1 tproxy ip6''
        rules;
      assert at "ip daddr 192.168.0.0/16 tcp dport != 53 return" < at ''iifname { "br0" }'';
      assert !(pkgs.lib.hasInfix "ip saddr" rules);
      # Into the backend's transparent socket alone, not any listener while it restarts.
      assert pkgs.lib.hasInfix ''iifname "br0" meta mark 1 socket transparent 1 accept''
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
    # The kill switch: up from boot ahead of the network, pulled in again by both modes, and
    # not stopped with them; it lets the proxy's own traffic and its DNS hand-off past, and
    # cuts gateway clients and containers off from the internet.
    (
      let
        units = killSwitchFixture.config.systemd.services;
        ks = units."proxy-suite-killswitch";
        rules = killSwitchNftRules;
        lines = pkgs.lib.splitString "\n" rules;
        at = needle: pkgs.lib.lists.findFirstIndex (pkgs.lib.hasInfix needle) null lines;
        before = a: b: at a < at b;
      in
      assert builtins.elem "proxy-suite-killswitch.service" units."proxy-suite-tun".wants;
      assert builtins.elem "proxy-suite-killswitch.service" units."proxy-suite-tproxy".wants;
      assert !(units."proxy-suite-tun" ? bindsTo) || units."proxy-suite-tun".bindsTo == [ ];
      assert !(ks ? partOf) || ks.partOf == [ ];
      assert ks.wantedBy == [ "multi-user.target" ];
      assert builtins.elem "network-pre.target" ks.before;
      assert builtins.elem "network-pre.target" ks.wants;
      assert ks.unitConfig.DefaultDependencies == false;
      assert builtins.elem "nftables.service" ks.after;
      # Nothing that waits for the network: that would be an ordering cycle.
      assert !builtins.elem "proxy-suite-tun.service" ks.after;
      assert !builtins.elem "proxy-suite-socks.service" ks.after;
      assert pkgs.lib.hasInfix ''meta skuid { "proxy-suite-daemon" } accept'' rules;
      assert pkgs.lib.hasInfix "meta mark { 1, 2 } accept" rules;
      assert pkgs.lib.hasInfix ''oifname "singtun0" accept'' rules;
      assert before "ip daddr 172.19.0.1/30 accept" "th dport 53 reject";
      assert before "th dport 53 reject" "ip daddr $RESERVED_IP accept";
      # DHCP and NTP only from privileged ports or the time daemons: no STUN past it.
      assert !(pkgs.lib.hasInfix "udp dport { 67, 68, 123 }" rules);
      assert pkgs.lib.hasInfix "meta nfproto ipv4 udp sport 68 udp dport 67 accept" rules;
      assert pkgs.lib.hasInfix "meta nfproto ipv6 udp sport 546 udp dport 547 accept" rules;
      assert pkgs.lib.hasInfix "meta skuid @time_sync_uids udp dport 123 accept" rules;
      assert
        killSwitchFixture.config.services.proxy-suite.killSwitch.timeSyncUsers == [ "systemd-timesync" ];
      assert pkgs.lib.hasInfix "for user in systemd-timesync; do" killSwitchUpScript;
      assert pkgs.lib.hasInfix "time_sync_uids {" killSwitchUpScript;
      # Forwarded traffic leaves by the TUN or not at all, gateway clients' included.
      assert before "chain forward" ''oifname { "singtun0" } accept'';
      assert builtins.any (line: pkgs.lib.trim line == "reject with icmpx admin-prohibited") (
        pkgs.lib.drop (at "chain forward") lines
      );
      assert !(pkgs.lib.hasInfix ''iifname { "br0" } reject'' rules);
      # Containers' traffic passes while TProxy, which tags it, is up instead of the TUN.
      assert before "chain forward" "meta mark and 16777216 != 0 accept";
      assert pkgs.lib.hasInfix ''iifname != { "br0" } meta mark set meta mark or 16777216''
        killSwitchTproxyNftRules;
      # TProxy alone: only the gateway clients are held.
      assert pkgs.lib.hasInfix ''iifname { "br0" } reject'' tproxyKillSwitchNftRules;
      assert !(pkgs.lib.hasInfix "oifname {" tproxyKillSwitchNftRules);
      # Subscriptions are fetched as proxy-suite-fetch, through whatever tunnel is up; only
      # when that fails under the kill switch with no cache, as the service user. Without
      # the kill switch, never.
      assert pkgs.lib.hasInfix ''_proxy_suite_run_fetcher tunnel "$tag"'' killSwitchSubscriptionUpdate;
      assert pkgs.lib.hasInfix ''{ true && ! _proxy_suite_valid_subscription_cache "$cache" &&''
        killSwitchSubscriptionUpdate;
      assert pkgs.lib.hasInfix "fetching it directly, past the kill switch" killSwitchSubscriptionUpdate;
      assert pkgs.lib.hasInfix "as=(" killSwitchSubscriptionUpdate;
      assert pkgs.lib.hasInfix "setpriv --reuid=proxy-suite-daemon" killSwitchSubscriptionUpdate;
      assert pkgs.lib.hasInfix "unshare --mount" killSwitchSubscriptionUpdate;
      assert pkgs.lib.hasInfix "--links-fd 3" killSwitchSubscriptionUpdate;
      assert pkgs.lib.hasInfix "{ false &&" tunSubscriptionUpdate;
      assert !(pkgs.lib.hasInfix "unshare --mount" tunSubscriptionUpdate);
      assert !(pkgs.lib.hasInfix "setpriv --reuid=proxy-suite-daemon" tunSubscriptionUpdate);
      assert pkgs.lib.hasInfix "setpriv --reuid=proxy-suite-fetch" tunSubscriptionUpdate;
      # A switch reloads it: the new rules replace the old in one transaction, never a stop
      # that lifts it first.
      assert ks.reloadIfChanged;
      assert ks.serviceConfig.ExecReload == ks.serviceConfig.ExecStart;
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
      assert !builtins.elem "proxy-suite-awg-home.service" units.proxy-suite-killswitch.after;
      assert units.proxy-suite-killswitch.wantedBy == [ "multi-user.target" ];
      assert !builtins.elem "proxy-suite-killswitch.service" (home.conflicts or [ ]);
      assert (units.proxy-suite-killswitch.conflicts or [ ]) == [ ];
      assert home.serviceConfig.Group == "proxy-suite-awg";
      assert cfg.users.groups ? proxy-suite-awg;
      assert pkgs.lib.hasInfix "--fwmark 51820" awgKillSwitchPrepare;
      assert pkgs.lib.hasInfix ''meta skgid "proxy-suite-awg" accept'' rules;
      # And the one the profiles added at runtime share.
      assert pkgs.lib.hasInfix
        ''oifname { "${cfg.services.proxy-suite.amneziaWg.profiles.home.interfaceName}", "awg-rt" } accept''
        rules;
      # Forwarded traffic too, through either.
      assert pkgs.lib.hasInfix "chain forward" rules;
      assert
        builtins.length (
          pkgs.lib.splitString ''oifname { "${cfg.services.proxy-suite.amneziaWg.profiles.home.interfaceName}", "awg-rt" } accept'' rules
        ) == 3;
      assert pkgs.lib.hasInfix "meta mark { 1, 2, 51820 } accept" rules;
      # killSwitch.allowedSubnets in place of TProxy's localSubnets, out and forwarded.
      assert builtins.length (pkgs.lib.splitString "ip6 daddr 2001:db8:1::/64 accept" rules) == 3;
      assert !(pkgs.lib.hasInfix "ip daddr 192.168.0.0/16 accept" rules);
      assert pkgs.lib.hasInfix "ip daddr 192.168.0.0/16 accept" killSwitchNftRules;
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
      # Only what the output chain marked, this host's own traffic: a neighbour routing
      # through this host is not handed the proxy.
      assert pkgs.lib.hasInfix
        "meta mark 1 meta nfproto ipv4 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:1085"
        tproxyManualNftRules;
      assert pkgs.lib.hasInfix
        "meta mark 1 meta nfproto ipv6 meta l4proto { tcp, udp } tproxy ip6 to [::1]:1085"
        tproxyManualNftRules;
      # Marked traffic that leaves anywhere but lo lost its ip rule: dropped, not sent direct.
      assert pkgs.lib.hasInfix ''meta mark 1 oifname != { "lo" } drop'' tproxyManualNftRules;
      assert
        tproxyTags tproxyManualConfig == [
          "tproxy-in"
          "tproxy-in6"
        ];
      # IPv4 only: IPv6 is not taken by the proxy, but marked into an unreachable route rather
      # than left to go out directly.
      assert !(pkgs.lib.hasInfix "-6 route replace local default" tproxyIPv4OnlyStartScript);
      assert pkgs.lib.hasInfix "-6 route replace unreachable default table 100" tproxyIPv4OnlyStartScript;
      assert pkgs.lib.hasInfix "-6 rule add fwmark 1 table 100" tproxyIPv4OnlyStartScript;
      assert pkgs.lib.hasInfix "-6 rule del fwmark 1 table 100" tproxyIPv4OnlyStartScript;
      assert !(pkgs.lib.hasInfix "tproxy ip6" tproxyIPv4OnlyNftRules);
      assert pkgs.lib.hasInfix "meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set 1"
        tproxyIPv4OnlyNftRules;
      assert pkgs.lib.hasInfix "meta nfproto ipv6 meta mark set 1" tproxyIPv4OnlyNftRules;
      # On-link IPv6 leaves marked by the main table: not dropped as misrouted.
      assert pkgs.lib.hasInfix ''meta nfproto ipv4 meta mark 1 oifname != { "lo" } drop''
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
      # IPv6 only into an unreachable route, as the sing-box and per-app TUNs have it.
      assert !(pkgs.lib.hasInfix "-6 route replace default dev" xrayIPv4OnlyTunUpScript);
      assert pkgs.lib.hasInfix "-6 route replace unreachable default table" xrayIPv4OnlyTunUpScript;
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
      # Per-app units it carries for go first (they never take it down), then the clean-up.
      assert builtins.elemAt tunServiceConfig.ExecStartPre 1 == tunServiceConfig.ExecStopPost;
      assert pkgs.lib.hasInfix "proxy-suite-per-app-tproxy.service" (
        builtins.head tunServiceConfig.ExecStartPre
      );
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
