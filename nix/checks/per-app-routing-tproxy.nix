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

  keepRunningFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy.tun.enable = true;
        perAppRouting = {
          enable = true;
          tun = {
            enable = true;
            keepRunning = true;
          };
          tproxy = {
            enable = true;
            keepRunning = true;
          };
        };
      };
    }
  ];
  keepRunningServices = keepRunningFixture.config.systemd.services;
  keepRunningStandby = keepRunningServices.proxy-suite-per-app-standby;
  keepRunningStandbyScript = generated.readDerivation keepRunningStandby.serviceConfig.ExecStart;

  # Profiles through an outbound, kept: a pin slot, and a global AmneziaWG profile's copy for apps.
  keepViaFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        amneziaWg = {
          enable = true;
          kernelModulePackage = null;
          profiles.home.configFile = "/run/secrets/awg.conf";
        };
        perAppRouting = {
          enable = true;
          tun.enable = true;
          profiles = [
            {
              name = "game";
              route = "tun";
              outbound = "primary";
              keepRunning = true;
            }
            {
              name = "home-app";
              outbound = "home";
              keepRunning = true;
            }
          ];
        };
      };
    }
  ];
  keepViaServices = keepViaFixture.config.systemd.services;
  keepViaStandbyScript = generated.readDerivation keepViaServices.proxy-suite-per-app-standby.serviceConfig.ExecStart;
  keepViaPerApp = mkPerAppUserRules keepViaFixture;
  keepViaRetireScript = generated.readDerivation keepViaPerApp.viaRetire;
  keepViaPinUpScript = generated.readDerivation keepViaPerApp.pinUp.tun;
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
      # Started with the first app, so nothing to keep running.
      assert !(perAppRoutingTproxyFixture.config.systemd.services ? proxy-suite-per-app-standby);
      true
    )

    # -- perAppRouting: keepRunning keeps the backends up from boot, back after a global mode --
    (
      assert !keepRunningServices.proxy-suite-per-app-tun.unitConfig.StopWhenUnneeded;
      assert !keepRunningServices.proxy-suite-per-app-tproxy.unitConfig.StopWhenUnneeded;
      assert keepRunningStandby.wantedBy == [ "multi-user.target" ];
      assert !keepRunningStandby.serviceConfig.RemainAfterExit;
      # Ordered after the global modes, so it sees one that starts at boot or is stopping.
      assert builtins.elem "proxy-suite-tun.service" keepRunningStandby.after;
      assert builtins.elem "proxy-suite-tproxy.service" keepRunningStandby.after;
      # The per-app TUN runs under a global mode; the per-app TProxy steps aside for one.
      assert pkgs.lib.hasInfix "\n$systemctl start --no-block proxy-suite-per-app-tun.service\n"
        keepRunningStandbyScript;
      assert pkgs.lib.hasInfix
        "\nunder_global proxy-suite-tproxy.service proxy-suite-tun.service || $systemctl start --no-block proxy-suite-per-app-tproxy.service\n"
        keepRunningStandbyScript;
      # A global mode's stop brings it back, after its own cleanup.
      assert builtins.length keepRunningServices.proxy-suite-tun.serviceConfig.ExecStopPost == 2;
      assert pkgs.lib.hasSuffix "start --no-block proxy-suite-per-app-standby.service" (
        pkgs.lib.last keepRunningServices.proxy-suite-tun.serviceConfig.ExecStopPost
      );
      true
    )

    # -- perAppRouting: a kept profile keeps its outbound's units, which nothing takes down --
    (
      let
        inherit (pkgs.lib) hasInfix;
        # "primary" and "home" in hex, as proxy-ctl names their units.
        kept = "tun-7072696d617279 | app-686f6d65)";
      in
      assert hasInfix
        "under_global proxy-suite-tproxy.service proxy-suite-tun.service || $systemctl start --no-block proxy-suite-per-app-via-tun@7072696d617279.service"
        keepViaStandbyScript;
      # The copy for apps first; the via unit again if it was down, for its slot.
      assert hasInfix
        "under_global proxy-suite-awg-home.service proxy-suite-awg@home.service || if $systemctl is-active --quiet proxy-suite-awg-app@home.service; then"
        keepViaStandbyScript;
      assert hasInfix
        "$systemctl start proxy-suite-awg-app@home.service && $systemctl restart --no-block proxy-suite-per-app-via@app-686f6d65.service"
        keepViaStandbyScript;
      # Not by the last app's exit, nor taken back by another pin.
      assert hasInfix "${kept} exit 0 ;;" keepViaRetireScript;
      assert hasInfix "${kept} continue ;;" keepViaPinUpScript;
      # The global profile's stop brings its copy back.
      assert pkgs.lib.hasSuffix "start --no-block proxy-suite-per-app-standby.service" (
        pkgs.lib.last keepViaServices.proxy-suite-awg-home.serviceConfig.ExecStopPost
      );
      # The pin holds the backend up through Requires=.
      assert keepViaServices.proxy-suite-per-app-tun.unitConfig.StopWhenUnneeded;
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
