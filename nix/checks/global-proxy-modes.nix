{
  pkgs,
  evalProxySuite,
  baseModule,
  mkBadFixture,
  mkFailingAssertions,
  mkTunConfig,
  dnsServerByTag,
  checkConstants,
}:

let
  fixtures = import ./global-proxy-modes/fixtures.nix {
    inherit
      evalProxySuite
      baseModule
      mkBadFixture
      mkFailingAssertions
      mkTunConfig
      ;
  };

  inherit (fixtures)
    invalidGlobalProxyModeAssertions
    tproxyAutostartFixture
    tproxyManualFixture
    tproxyManualStartScript
    tproxyManualStopScript
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
    (
      assert tproxyWithFirewall.config.networking.firewall.enable;
      true
    )
    (
      assert tproxyManualFixture.config.services.proxy-suite.proxy.tproxy.autostart == false;
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
      assert pkgs.lib.hasInfix "rule del fwmark 1 table 100" tproxyManualStopScript;
      true
    )
    (
      assert tunManualFixture.config.services.proxy-suite.proxy.tun.autostart == false;
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
    (
      assert tunManualFixture.config.networking.nftables.enable;
      true
    )
    (
      assert tunServiceConfig.ExecStartPre == tunServiceConfig.ExecStopPost;
      assert pkgs.lib.hasInfix "delete table inet sing-box" tunCleanupScript;
      assert pkgs.lib.hasInfix "rule del table ${toString checkConstants.tunAutoRouteTableIndex}"
        tunCleanupScript;
      assert pkgs.lib.hasInfix "rule del pref ${toString checkConstants.xrayTunPerAppTproxyRulePriority}"
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
    (
      assert tunDefaultConfig.route.default_domain_resolver == "local";
      true
    )
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
