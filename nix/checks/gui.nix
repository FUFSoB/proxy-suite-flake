{
  evalProxySuite,
  baseModule,
  packagePathMatches,
}:

let
  guiFixture = evalProxySuite [
    baseModule
    { services.proxy-suite.gui.enable = true; }
  ];

  guiManualFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.gui = {
        enable = true;
        autostart = false;
      };
    }
  ];

  # The old tray options still work, as renames of the GUI's.
  deprecatedTrayFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.tray = {
        enable = true;
        pollInterval = 7;
      };
    }
  ];

  tuiOffFixture = evalProxySuite [
    baseModule
    { services.proxy-suite.tui.enable = false; }
  ];

  guiPackage = ".*/[^/]*proxy-suite-gui(-[0-9.]+)?$";
in
{
  assertions = [
    (
      assert packagePathMatches guiManualFixture.config.environment.systemPackages ".*/[^/]*proxy-tui$";
      assert !(packagePathMatches tuiOffFixture.config.environment.systemPackages ".*/[^/]*proxy-tui$");
      assert !(packagePathMatches tuiOffFixture.config.environment.systemPackages guiPackage);
      true
    )
    (
      assert packagePathMatches guiFixture.config.environment.systemPackages guiPackage;
      assert packagePathMatches guiManualFixture.config.environment.systemPackages guiPackage;
      true
    )
    (
      let
        unit = guiFixture.config.systemd.user.services.proxy-suite-gui;
      in
      assert unit.wantedBy == [ "graphical-session.target" ];
      assert builtins.elem "graphical-session.target" unit.partOf;
      assert builtins.match ".*/bin/proxy-suite-gui --hidden$" unit.serviceConfig.ExecStart != null;
      true
    )
    (
      # pkexec of this proxy-ctl, and only it, keeps the admin password for a while.
      let
        rules = guiFixture.config.security.polkit.extraConfig;
      in
      assert guiFixture.config.security.polkit.enable;
      assert
        builtins.match ''.*action\.lookup\("program"\) === "/nix/store/[^"]*proxy-ctl/bin/proxy-ctl".*AUTH_ADMIN_KEEP.*'' rules
        != null;
      assert builtins.match ".*AUTH_ADMIN_KEEP.*" tuiOffFixture.config.security.polkit.extraConfig == null;
      true
    )
    (
      assert !(guiManualFixture.config.systemd.user.services ? proxy-suite-gui);
      assert !(tuiOffFixture.config.systemd.user.services ? proxy-suite-gui);
      true
    )
    (
      let
        cfg = deprecatedTrayFixture.config;
      in
      assert cfg.services.proxy-suite.gui.enable;
      assert cfg.services.proxy-suite.gui.refreshInterval == 7;
      assert packagePathMatches cfg.environment.systemPackages guiPackage;
      assert builtins.any (
        w: builtins.match ".*services\\.proxy-suite\\.gui\\.enable.*" w != null
      ) cfg.warnings;
      true
    )
  ];
}
