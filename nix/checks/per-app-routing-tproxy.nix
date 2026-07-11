{
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  mkPerAppUserRules,
}:

let
  generated = import ./read-generated.nix;

  perAppRoutingTproxyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy.tproxy.perApp.enable = true;
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      };
    }
  ];
  perAppRoutingTproxy = mkProxyCtlDerived perAppRoutingTproxyFixture;
  perAppRoutingTproxyScript = perAppRoutingTproxy.script;
  perAppRoutingTproxyProfiles = perAppRoutingTproxy.profiles;
  perAppRoutingTproxyServiceConfig =
    perAppRoutingTproxyFixture.config.systemd.services."proxy-suite-per-app-tproxy".serviceConfig;
  perAppRoutingTproxyStartScript = generated.readDerivation perAppRoutingTproxyServiceConfig.ExecStart;
  perAppRoutingTproxyStopScript = generated.readDerivation perAppRoutingTproxyServiceConfig.ExecStop;
  perAppRoutingTproxyUserStartScript = generated.readDerivation (
    (mkPerAppUserRules perAppRoutingTproxyFixture).perAppTproxyUserRuleStart
  );
in
{
  assertions = [
    # -- perAppRouting: createDefaultProfiles injects curated tproxy profile when backend is enabled --
    (
      assert builtins.length perAppRoutingTproxyProfiles == 2;
      assert builtins.any (
        profile: profile.name == "tproxy" && profile.route == "tproxy"
      ) perAppRoutingTproxyProfiles;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches tproxy profiles through systemd slices --
    (
      assert pkgs.lib.hasInfix "PER_APP_ROUTING_TPROXY_ENABLED" perAppRoutingTproxyScript;
      assert pkgs.lib.hasInfix
        ''_wrap_slice "proxy-suite-per-app-tproxy" "$profile" "$PER_APP_ROUTING_TPROXY_ENABLED"''
        perAppRoutingTproxyScript;
      assert pkgs.lib.hasInfix "$slice_base-\${profile}-$$" perAppRoutingTproxyScript;
      true
    )

    # -- perAppRouting: app TProxy service and helper units are created --
    (
      assert perAppRoutingTproxyFixture.config.systemd.services ? "proxy-suite-per-app-tproxy";
      assert perAppRoutingTproxyFixture.config.systemd.services ? "proxy-suite-per-app-tproxy-user@";
      assert
        perAppRoutingTproxyFixture.config.systemd.user.services ? "proxy-suite-per-app-tproxy-anchor";
      true
    )

    # -- perAppRouting: app TProxy helper installs socket cgroup mark rules --
    (
      assert pkgs.lib.hasInfix "socket cgroupv2" perAppRoutingTproxyUserStartScript;
      assert pkgs.lib.hasInfix "meta mark set" perAppRoutingTproxyUserStartScript;
      assert pkgs.lib.hasInfix "ct mark set" perAppRoutingTproxyUserStartScript;
      true
    )

    # -- perAppRouting: app TProxy startup installs nftables and loopback policy route --
    (
      assert pkgs.lib.hasInfix "proxy_suite_per_app_tproxy" perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "rule del fwmark 17 table 102" perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "route replace local default dev lo table 102"
        perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "rule add fwmark 17 table 102" perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "set +e" perAppRoutingTproxyStopScript;
      assert pkgs.lib.hasInfix "rule del fwmark 17 table 102" perAppRoutingTproxyStopScript;
      true
    )
  ];
}
