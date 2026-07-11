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
        proxy.tun.perApp.enable = true;
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      };
    }
  ];
  userControlDefaultPolkitConfig = userControlDefaultFixture.config.security.polkit.extraConfig;

  userControlGlobalOnlyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.userControl = {
        global.enable = true;
        perApp.enable = false;
      };
    }
  ];
  userControlGlobalOnlyPolkitConfig = userControlGlobalOnlyFixture.config.security.polkit.extraConfig;

  userControlPerAppOnlyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy.tun.perApp.enable = true;
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
        userControl = {
          global.enable = false;
          perApp.enable = true;
        };
      };
    }
  ];
  userControlPerAppOnlyPolkitConfig = userControlPerAppOnlyFixture.config.security.polkit.extraConfig;

  userControlDisabledFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.userControl = {
        global.enable = false;
        perApp.enable = false;
      };
    }
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
      assert pkgs.lib.hasInfix "unit === \"zapret-discord-youtube.service\""
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
      assert pkgs.lib.hasInfix "unit === \"zapret-discord-youtube.service\""
        userControlGlobalOnlyPolkitConfig;
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
        builtins.match ".*unit === \"zapret-discord-youtube\\.service\".*" userControlPerAppOnlyPolkitConfig
        == null;
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
