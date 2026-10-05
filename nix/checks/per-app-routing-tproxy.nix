{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  mkPerAppUserRules,
}:

let
  inherit (checkLib) ok;
  generated = import ./read-generated.nix;

  perAppRoutingTproxyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
          tproxy.enable = true;
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
  perAppRoutingTproxyStopScript = generated.readDerivation perAppRoutingTproxyServiceConfig.ExecStopPost;
  perAppRoutingTproxyUserStartScript = generated.readDerivation (
    (mkPerAppUserRules perAppRoutingTproxyFixture).perAppTproxyUserRuleStart
  );
  perAppRoutingTproxyNftRules =
    generated.readDerivation
      (import ../../modules/proxy-suite/nftables.nix {
        inherit (pkgs) lib;
        inherit pkgs;
        cfg = perAppRoutingTproxyFixture.config.services.proxy-suite;
      }).perAppTproxyRulesFile;
in
{
  assertions = [
    # -- perAppRouting: createDefaultProfiles injects curated tproxy profile when backend is enabled --
    (
      # proxychains is off, so no proxychains profile.
      assert builtins.length perAppRoutingTproxyProfiles == 1;
      assert builtins.any (
        profile: profile.name == "tproxy" && profile.route == "tproxy"
      ) perAppRoutingTproxyProfiles;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches tproxy profiles through systemd slices --
    (ok (pkgs.lib.hasInfix "PER_APP_ROUTING_TPROXY_ENABLED" perAppRoutingTproxyScript))

    # -- perAppRouting: app TProxy service and helper units are created --
    (
      assert perAppRoutingTproxyFixture.config.systemd.services ? "proxy-suite-per-app-tproxy";
      assert perAppRoutingTproxyFixture.config.systemd.services ? "proxy-suite-per-app-tproxy-user@";
      assert
        perAppRoutingTproxyFixture.config.systemd.user.services ? "proxy-suite-per-app-tproxy-anchor";
      assert
        perAppRoutingTproxyFixture.config.systemd.services.proxy-suite-per-app-tproxy.unitConfig.StopWhenUnneeded;
      assert
        perAppRoutingTproxyFixture.config.systemd.services."proxy-suite-per-app-tproxy-user@".requires == [
          "proxy-suite-per-app-tproxy.service"
        ];
      true
    )

    # -- perAppRouting: app TProxy helper installs socket cgroup mark rules --
    (
      assert pkgs.lib.hasInfix "socket cgroupv2" perAppRoutingTproxyUserStartScript;
      assert pkgs.lib.hasInfix "add rule inet proxy_suite_per_app_tproxy app_mark"
        perAppRoutingTproxyUserStartScript;
      assert pkgs.lib.hasInfix "meta mark set" perAppRoutingTproxyUserStartScript;
      assert pkgs.lib.hasInfix "ct mark set" perAppRoutingTproxyUserStartScript;
      true
    )

    # -- perAppRouting: forged UDP replies to app flows skip the mark, in both chains, before
    # the ct mark is copied; otherwise the tproxy listener takes them back --
    (
      let
        inherit (pkgs.lib) hasInfix splitString;
        guardedBeforeMark =
          chain:
          hasInfix "ct direction reply return" (
            builtins.head (splitString "ct mark 17 meta mark set 17" chain)
          );
        chains = splitString "chain output" perAppRoutingTproxyNftRules;
      in
      assert guardedBeforeMark (builtins.elemAt chains 0);
      assert guardedBeforeMark (builtins.elemAt chains 1);
      # This host's own addresses are not tproxied.
      assert hasInfix "fib daddr type local return" (builtins.elemAt chains 0);
      # Every lookup of a tproxied app, a LAN or loopback resolver's too, is marked, ahead
      # of the reserved ranges, and goes to the route's DNS forwarder; its own do not.
      assert hasInfix "th dport 53 goto app_mark" (
        builtins.head (splitString "daddr $RESERVED_IP return" (builtins.elemAt chains 1))
      );
      assert hasInfix
        "meta mark 17 meta l4proto { tcp, udp } th dport 53 ip daddr != 192.0.2.53 redirect to :19200"
        perAppRoutingTproxyNftRules;
      assert hasInfix "meta mark 17 ct mark set 17 return" perAppRoutingTproxyNftRules;
      true
    )

    # -- perAppRouting: app TProxy startup installs nftables and loopback policy route --
    (
      assert pkgs.lib.hasInfix "delete table inet proxy_suite_per_app_tproxy"
        perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "-6 route replace local default dev lo table 102"
        perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "-6 rule add fwmark 17 table 102" perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "-6 rule del fwmark 17 table 102" perAppRoutingTproxyStopScript;
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
