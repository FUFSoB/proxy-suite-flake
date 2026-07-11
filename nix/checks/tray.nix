{
  evalProxySuite,
  baseModule,
  packagePathMatches,
}:

let
  trayAutostartFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.tray.enable = true;
    }
  ];

  trayManualFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.tray = {
        enable = true;
        autostart = false;
      };
    }
  ];
in
{
  assertions = [
    (
      assert packagePathMatches trayAutostartFixture.config.environment.systemPackages
        ".*/[^/]*proxy-suite-tray(-[0-9.]+)?$";
      true
    )
    (
      assert packagePathMatches trayAutostartFixture.config.environment.systemPackages
        ".*/[^/]*proxy-suite-tray\\.desktop$";
      true
    )
    (
      assert
        builtins.match ".*/share/xdg/autostart/proxy-suite-tray\\.desktop$" (
          builtins.unsafeDiscardStringContext
            trayAutostartFixture.config.environment.etc."xdg/autostart/proxy-suite-tray.desktop".source
        ) != null;
      true
    )
    (
      assert !(trayManualFixture.config.environment.etc ? "xdg/autostart/proxy-suite-tray.desktop");
      true
    )
    (
      assert packagePathMatches trayManualFixture.config.environment.systemPackages
        ".*/[^/]*proxy-suite-tray\\.desktop$";
      true
    )
  ];
}
