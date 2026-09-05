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

  mkTunFixture =
    perAppZapret:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          proxy.tun = {
            enable = true;
            interface = "test-global0";
            perApp.enable = true;
            perApp.interface = "test-app0";
          };
          zapret.enable = true;
          zapret.perApp.enable = perAppZapret;
        };
      }
    ];
  tunFixture = mkTunFixture true;
  tunGlobalBase = mkZapretBase tunFixture;
  tunPerAppBase = mkZapretBaseFor tunFixture "proxy-suite-per-app-zapret";
  tunWithoutPerAppZapretBase = mkZapretBase (mkTunFixture false);

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

    # Execute the installed hooks: TUN exclusions must work with and without
    # per-app zapret, while preserving the global per-app mark exemption.
    nft() { printf '%s\n' "$*"; }
    ipt_add_del() { printf '4 %s\n' "$*"; }
    ipt6_add_del() { printf '6 %s\n' "$*"; }
    export ZAPRET_NFT_TABLE=test_zapret
    for base in ${tunGlobalBase} ${tunPerAppBase} ${tunWithoutPerAppZapretBase}; do
      source "$base/init.d/sysv/custom.d/50-proxy-suite-custom.sh"
      zapret_custom_firewall_nft > rules
      for interface in test-global0 test-app0; do
        for chain in postrouting postnat; do
          grep -Fx "insert rule inet test_zapret $chain oifname \"$interface\" return comment \"proxy-suite TUN bypass\"" rules
        done
        for chain in prerouting prenat; do
          grep -Fx "insert rule inet test_zapret $chain iifname \"$interface\" return comment \"proxy-suite TUN bypass\"" rules
        done
      done
      if [ "$base" = ${tunGlobalBase} ]; then
        test "$(wc -l < rules)" -eq 12
        test "$(grep -c 'mark and 268435456 != 0 return' rules)" -eq 4
      else
        test "$(wc -l < rules)" -eq 8
      fi

      # The upstream FWTYPE=iptables preset dispatches this hook instead of
      # zapret_custom_firewall_nft. Check both address families and cleanup.
      scope=global
      if [ "$base" = ${tunPerAppBase} ]; then scope=per-app; fi
      for action in 1 0; do
        zapret_custom_firewall "$action" > ipt-rules
        for family in 4 6; do
          for interface in test-global0 test-app0; do
            grep -Fx "$family $action POSTROUTING -t mangle -o $interface -m comment --comment proxy-suite $scope TUN bypass -j RETURN" ipt-rules
            for chain in INPUT FORWARD; do
              grep -Fx "$family $action $chain -t mangle -i $interface -m comment --comment proxy-suite $scope TUN bypass -j RETURN" ipt-rules
            done
          done
        done
        if [ "$base" = ${tunGlobalBase} ]; then
          test "$(wc -l < ipt-rules)" -eq 18
          test "$(grep -c -- '-m mark ! --mark 0/268435456' ipt-rules)" -eq 6
        else
          test "$(wc -l < ipt-rules)" -eq 12
        fi
      done
      DISABLE_IPV6=1 zapret_custom_firewall 1 > ipt-rules
      ! grep '^6 ' ipt-rules
      DISABLE_IPV4=1 zapret_custom_firewall 1 > ipt-rules
      ! grep '^4 ' ipt-rules
    done

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
