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
