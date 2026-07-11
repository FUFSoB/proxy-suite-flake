{
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  mkPerAppUserRules,
  mkPerAppTunConfig,
  dnsServerByTag,
}:

let
  generated = import ./read-generated.nix;

  perAppRoutingTunFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy.tun.perApp.enable = true;
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      };
    }
  ];
  perAppRoutingTun = mkProxyCtlDerived perAppRoutingTunFixture;
  perAppRoutingTunScript = perAppRoutingTun.script;
  perAppRoutingTunProfiles = perAppRoutingTun.profiles;
  perAppRoutingTunServiceConfig =
    perAppRoutingTunFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig;
  perAppRoutingTunStartScript = generated.readDerivation perAppRoutingTunServiceConfig.ExecStart;
  perAppRoutingTunUpScript = generated.readDerivation perAppRoutingTunServiceConfig.ExecStartPost;
  perAppRoutingTunCleanupScript = generated.readDerivation perAppRoutingTunServiceConfig.ExecStopPost;
  perAppRoutingTunConfig = mkPerAppTunConfig perAppRoutingTunFixture;
  perAppRoutingTunDirectOutbound = builtins.head (
    builtins.filter (item: item.tag == "direct") perAppRoutingTunConfig.outbounds
  );
  perAppRoutingTunUserStartScript = generated.readDerivation (
    (mkPerAppUserRules perAppRoutingTunFixture).perAppTunUserRuleStart
  );

  perAppRoutingTunWithTproxyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy = {
          tproxy.enable = true;
          tun.perApp.enable = true;
        };
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      };
    }
  ];
  perAppRoutingTunWithTproxyStartScript =
    generated.readDerivation
      perAppRoutingTunWithTproxyFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig.ExecStart;
  perAppRoutingTunWithTproxyConfig = mkPerAppTunConfig perAppRoutingTunWithTproxyFixture;
  perAppRoutingTunWithTproxyDirectOutbound = builtins.head (
    builtins.filter (item: item.tag == "direct") perAppRoutingTunWithTproxyConfig.outbounds
  );
in
{
  assertions = [
    # -- perAppRouting: createDefaultProfiles injects curated tun profile when backend is enabled --
    (
      assert builtins.length perAppRoutingTunProfiles == 2;
      assert builtins.any (
        profile: profile.name == "tun" && profile.route == "tun"
      ) perAppRoutingTunProfiles;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches tun profiles through systemd slices --
    (
      assert pkgs.lib.hasInfix "PER_APP_ROUTING_TUN_ENABLED" perAppRoutingTunScript;
      assert pkgs.lib.hasInfix "systemd-run --user --scope --quiet --collect --same-dir"
        perAppRoutingTunScript;
      assert pkgs.lib.hasInfix "_check_no_global_proxy tun" perAppRoutingTunScript;
      assert pkgs.lib.hasInfix
        ''_wrap_slice "proxy-suite-per-app-tun" "$profile" "$PER_APP_ROUTING_TUN_ENABLED"''
        perAppRoutingTunScript;
      assert pkgs.lib.hasInfix "$slice_base-user@$uid.service" perAppRoutingTunScript;
      assert pkgs.lib.hasInfix "cleanup_slice()" perAppRoutingTunScript;
      assert pkgs.lib.hasInfix "trap cleanup_slice EXIT" perAppRoutingTunScript;
      true
    )

    # -- perAppRouting: user mark script installs fwmark + conntrack mark rules --
    (
      assert pkgs.lib.hasInfix "meta mark set" perAppRoutingTunUserStartScript;
      assert pkgs.lib.hasInfix "ct mark set" perAppRoutingTunUserStartScript;
      true
    )

    # -- perAppRouting: app TUN config is separate and does not auto-route globally --
    (
      let
        inbound = builtins.head (
          builtins.filter (item: item.tag == "tun-in") perAppRoutingTunConfig.inbounds
        );
      in
      assert inbound.interface_name == "psperapptun0";
      assert inbound.address == [ "172.20.0.1/30" ];
      assert inbound.auto_route == false;
      assert inbound.auto_redirect == false;
      assert inbound.strict_route == false;
      assert !(inbound ? iproute2_table_index);
      assert !(inbound ? iproute2_rule_index);
      true
    )

    # -- perAppRouting: app TUN local DNS keeps direct path without explicit detour --
    (
      let
        localDns = dnsServerByTag perAppRoutingTunConfig "local";
      in
      assert !(localDns ? detour);
      true
    )

    # -- perAppRouting: app TUN uses local domain resolver and avoids global auto-routing --
    (
      assert perAppRoutingTunConfig.route.default_domain_resolver == "local";
      true
    )

    # -- perAppRouting: app TUN does not set outbound routing marks when TProxy is disabled --
    (
      assert builtins.match ".*--routing-mark.*" perAppRoutingTunStartScript == null;
      assert !(perAppRoutingTunDirectOutbound ? routing_mark);
      true
    )

    # -- perAppRouting: app TUN applies outbound routing marks when TProxy is enabled --
    (
      let
        expectedMark = perAppRoutingTunWithTproxyFixture.config.services.proxy-suite.proxy.tproxy.proxyMark;
      in
      assert builtins.match ".*--routing-mark.*" perAppRoutingTunWithTproxyStartScript != null;
      assert perAppRoutingTunWithTproxyDirectOutbound.routing_mark == expectedMark;
      true
    )

    # -- perAppRouting: app TUN service and helper units are created --
    (
      assert perAppRoutingTunFixture.config.systemd.services ? "proxy-suite-per-app-tun";
      assert perAppRoutingTunFixture.config.systemd.services ? "proxy-suite-per-app-tun-user@";
      assert perAppRoutingTunFixture.config.systemd.user.services ? "proxy-suite-per-app-tun-anchor";
      assert perAppRoutingTunServiceConfig.ExecStartPre == perAppRoutingTunServiceConfig.ExecStopPost;
      assert !(pkgs.lib.hasInfix "-6 addr replace" perAppRoutingTunUpScript);
      assert !(pkgs.lib.hasInfix "-6 route replace" perAppRoutingTunUpScript);
      assert !(pkgs.lib.hasInfix "-6 rule add" perAppRoutingTunUpScript);
      assert pkgs.lib.hasInfix "link del dev" perAppRoutingTunCleanupScript;
      assert pkgs.lib.hasInfix "psperapptun0" perAppRoutingTunCleanupScript;
      assert pkgs.lib.hasInfix "rule del fwmark 16 table 101" perAppRoutingTunCleanupScript;
      true
    )

    # -- perAppRouting: app TUN enables nftables and user control group --
    (
      assert perAppRoutingTunFixture.config.networking.nftables.enable;
      assert perAppRoutingTunFixture.config.users.groups ? "proxy-suite";
      true
    )
  ];
}
