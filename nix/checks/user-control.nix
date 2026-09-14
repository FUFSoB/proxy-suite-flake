{
  pkgs,
  evalProxySuite,
  baseModule,
}:

let
  userControlDefaultFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
          tun.enable = true;
        };
      };
    }
  ];
  userControlDefaultPolkitConfig = userControlDefaultFixture.config.security.polkit.extraConfig;

  userControlGlobalOnlyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.userControl.allow = [ "global" ];
    }
  ];
  userControlGlobalOnlyPolkitConfig = userControlGlobalOnlyFixture.config.security.polkit.extraConfig;

  userControlPerAppOnlyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
          tun.enable = true;
        };
        userControl.allow = [ "perApp" ];
      };
    }
  ];
  userControlPerAppOnlyPolkitConfig = userControlPerAppOnlyFixture.config.security.polkit.extraConfig;

  userControlDisabledFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.userControl.allow = [ ];
    }
  ];

  # Every unit declaring the autoProxy state directory must carry the group, or
  # the next start chowns it back and `proxy auto list|queue` loses its read.
  mkAutoProxyFixture =
    extra:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          proxy.autoProxy.enable = true;
        }
        // extra;
      }
    ];
  autoProxyGroups =
    fixture:
    map (unit: fixture.config.systemd.services.${unit}.serviceConfig.Group or null) [
      "proxy-suite-autoproxy"
      "proxy-suite-autoproxy-learn"
      "proxy-suite-autoproxy-sample"
    ];
in
{
  assertions = [
    # -- userControl: default polkit rule covers both per-app and global proxy-ctl managed units --
    (
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-per-app-\") === 0"
        userControlDefaultPolkitConfig;
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-\") === 0" userControlDefaultPolkitConfig;
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-per-app-\") !== 0"
        userControlDefaultPolkitConfig;
      true
    )

    # -- userControl: global-only rule excludes per-app units --
    (
      assert userControlGlobalOnlyFixture.config.users.groups ? "proxy-suite";
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-\") === 0" userControlGlobalOnlyPolkitConfig;
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-per-app-\") !== 0"
        userControlGlobalOnlyPolkitConfig;
      assert
        builtins.match ".*unit\\.indexOf\\(\"proxy-suite-per-app-\"\\) === 0.*" userControlGlobalOnlyPolkitConfig
        == null;
      true
    )

    # -- userControl: per-app-only rule covers per-app-scoped helpers only --
    (
      assert userControlPerAppOnlyFixture.config.users.groups ? "proxy-suite";
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-per-app-\") === 0"
        userControlPerAppOnlyPolkitConfig;
      assert
        builtins.match ".*unit\\.indexOf\\(\"proxy-suite-per-app-\"\\) !== 0.*" userControlPerAppOnlyPolkitConfig
        == null;
      assert
        builtins.match ".*unit\\.indexOf\\(\"proxy-suite-\"\\) === 0.*" userControlPerAppOnlyPolkitConfig
        == null;
      true
    )

    # -- userControl: the autoProxy state directory is group-owned, and only then --
    (
      assert
        autoProxyGroups (mkAutoProxyFixture { }) == [
          "proxy-suite"
          "proxy-suite"
          "proxy-suite"
        ];
      assert
        autoProxyGroups (mkAutoProxyFixture {
          userControl.group = "vpnops";
        }) == [
          "vpnops"
          "vpnops"
          "vpnops"
        ];
      assert
        autoProxyGroups (mkAutoProxyFixture {
          userControl.allow = [ ];
        }) == [
          null
          null
          null
        ];
      true
    )

    # -- userControl: disabling both scopes removes group and polkit wiring --
    (
      assert !(userControlDisabledFixture.config.users.groups ? "proxy-suite");
      assert !userControlDisabledFixture.config.security.polkit.enable;
      assert
        builtins.match ".*subject\\.isInGroup\\(\"proxy-suite\"\\).*" userControlDisabledFixture.config.security.polkit.extraConfig
        == null;
      assert
        builtins.match ".*org\\.freedesktop\\.systemd1\\.manage-units.*" userControlDisabledFixture.config.security.polkit.extraConfig
        == null;
      true
    )
  ];
}
