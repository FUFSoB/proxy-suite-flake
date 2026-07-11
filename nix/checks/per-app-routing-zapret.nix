{
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  mkPerAppUserRules,
  mkPerAppZapretNftRules,
  mkZapretBase,
  mkZapretBaseFor,
}:

let
  generated = import ./read-generated.nix;

  perAppRoutingZapretFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        zapret = {
          enable = true;
          perApp.enable = true;
        };
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
          proxychains.enable = true;
        };
      };
    }
  ];
  perAppRoutingZapret = mkProxyCtlDerived perAppRoutingZapretFixture;
  perAppRoutingZapretScript = perAppRoutingZapret.script;
  perAppRoutingZapretProfiles = perAppRoutingZapret.profiles;
  perAppRoutingZapretStartScript = mkPerAppZapretNftRules perAppRoutingZapretFixture;
  perAppRoutingZapretUserStartScript = generated.readDerivation (
    (mkPerAppUserRules perAppRoutingZapretFixture).perAppZapretUserRuleStart
  );
  perAppRoutingZapretService =
    perAppRoutingZapretFixture.config.systemd.services."proxy-suite-per-app-zapret";
  perAppRoutingZapretBase = mkZapretBase perAppRoutingZapretFixture;
  perAppRoutingPerAppZapretBase = mkZapretBaseFor perAppRoutingZapretFixture "proxy-suite-per-app-zapret";

  perAppRoutingZapretWithoutGlobalFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        zapret = {
          enable = false;
          perApp.enable = true;
        };
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
          proxychains.enable = true;
        };
      };
    }
  ];
  perAppRoutingZapretWithoutGlobal = mkProxyCtlDerived perAppRoutingZapretWithoutGlobalFixture;
  perAppRoutingZapretWithoutGlobalProfiles = perAppRoutingZapretWithoutGlobal.profiles;
  perAppRoutingZapretWithoutGlobalPerAppBase = mkZapretBaseFor perAppRoutingZapretWithoutGlobalFixture "proxy-suite-per-app-zapret";

  runtime = pkgs.runCommand "proxy-suite-per-app-zapret-runtime-check" { } ''
    global_config=${perAppRoutingZapretBase}/config
    per_app_config=${perAppRoutingPerAppZapretBase}/config
    per_app_only_config=${perAppRoutingZapretWithoutGlobalPerAppBase}/config
    custom_script=${perAppRoutingZapretBase}/init.d/sysv/custom.d/50-proxy-suite-custom.sh

    grep -F 'FILTER_MARK=' "$global_config"
    ! grep -F 'FILTER_MARK=0x10000000' "$global_config"

    grep -F 'FILTER_MARK=0x10000000' "$per_app_config"
    grep -F 'MODE_FILTER=none' "$per_app_config"
    grep -F 'QNUM=201' "$per_app_config"
    grep -F 'DESYNC_MARK=0x8000000' "$per_app_config"
    grep -F 'DESYNC_MARK_POSTNAT=0x4000000' "$per_app_config"
    grep -F 'ZAPRET_NFT_TABLE=proxy_suite_per_app_zapret' "$per_app_config"

    grep -F 'FILTER_MARK=0x10000000' "$per_app_only_config"
    grep -F 'QNUM=201' "$per_app_only_config"

    grep -F 'proxy-suite per-app-zapret bypass' "$custom_script"
    grep -F 'mark and 268435456 != 0 return' "$custom_script"

    touch "$out"
  '';
in
{
  assertions = [
    # -- perAppRouting: createDefaultProfiles injects curated zapret profile when backend is enabled --
    (
      assert builtins.length perAppRoutingZapretProfiles == 2;
      assert builtins.any (
        profile: profile.name == "zapret" && profile.route == "zapret"
      ) perAppRoutingZapretProfiles;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches zapret profiles through systemd slices --
    (
      assert pkgs.lib.hasInfix "PER_APP_ROUTING_ZAPRET_ENABLED" perAppRoutingZapretScript;
      assert pkgs.lib.hasInfix
        ''_wrap_slice "proxy-suite-per-app-zapret" "$profile" "$PER_APP_ROUTING_ZAPRET_ENABLED"''
        perAppRoutingZapretScript;
      assert pkgs.lib.hasInfix "$slice_base-\${profile}-$$" perAppRoutingZapretScript;
      true
    )

    # -- perAppRouting: app zapret service and helper units are created --
    (
      assert perAppRoutingZapretFixture.config.systemd.services ? "proxy-suite-per-app-zapret";
      assert perAppRoutingZapretFixture.config.systemd.services ? "proxy-suite-per-app-zapret-user@";
      assert
        perAppRoutingZapretFixture.config.systemd.user.services ? "proxy-suite-per-app-zapret-anchor";
      assert builtins.elem "network-online.target" perAppRoutingZapretService.after;
      assert builtins.elem "network-online.target" perAppRoutingZapretService.wants;
      true
    )

    # -- perAppRouting: app zapret can run without the global zapret service --
    (
      assert
        perAppRoutingZapretWithoutGlobalFixture.config.systemd.services ? "proxy-suite-per-app-zapret";
      assert
        perAppRoutingZapretWithoutGlobalFixture.config.systemd.services
        ? "proxy-suite-per-app-zapret-user@";
      assert
        perAppRoutingZapretWithoutGlobalFixture.config.systemd.user.services
        ? "proxy-suite-per-app-zapret-anchor";
      assert
        !(perAppRoutingZapretWithoutGlobalFixture.config.systemd.services ? "zapret-discord-youtube");
      assert builtins.length perAppRoutingZapretWithoutGlobalProfiles == 2;
      assert builtins.any (
        profile: profile.name == "zapret" && profile.route == "zapret"
      ) perAppRoutingZapretWithoutGlobalProfiles;
      assert pkgs.lib.hasInfix "proxy-suite-per-app-zapret" perAppRoutingZapretWithoutGlobalPerAppBase;
      assert !(pkgs.lib.hasInfix "proxy-suite-zapret" perAppRoutingZapretWithoutGlobalPerAppBase);
      true
    )

    # -- perAppRouting: app zapret helper installs socket cgroup bitwise mark rules --
    (
      assert pkgs.lib.hasInfix "socket cgroupv2" perAppRoutingZapretUserStartScript;
      assert pkgs.lib.hasInfix "meta mark set meta mark or 268435456" perAppRoutingZapretUserStartScript;
      assert pkgs.lib.hasInfix "ct mark set ct mark or 268435456" perAppRoutingZapretUserStartScript;
      true
    )

    # -- perAppRouting: app zapret startup installs nftables backend --
    (
      assert pkgs.lib.hasInfix "proxy_suite_per_app_zapret_mark" perAppRoutingZapretStartScript;
      true
    )

  ];

  inherit runtime;
}
