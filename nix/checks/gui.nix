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
  inherit (import ./read-generated.nix) readDerivation;
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
      # pkexec of this proxy-ctl, and only it, keeps the admin password for a while: an action
      # of its own, not a rule on org.freedesktop.policykit.exec, whose kept authorization
      # would cover any program the GUI ran through pkexec next.
      let
        cfg = guiFixture.config;
        actions = cfg.services.proxy-suite.internal.polkit.actions;
        policy = readDerivation actions."io.github.FUFSoB.ProxySuite.proxy-ctl.policy";
        proxyCtl = builtins.head (
          builtins.filter (p: builtins.match ".*/[^/]*-proxy-ctl$" p != null) (
            map (p: builtins.unsafeDiscardStringContext (toString p)) cfg.environment.systemPackages
          )
        );
        has = text: builtins.match ".*${text}.*" (builtins.unsafeDiscardStringContext policy) != null;
      in
      assert cfg.security.polkit.enable;
      # nixpkgs 26.11+: no setuid pkexec unless asked for, and without it pkexec refuses to run.
      assert cfg.security.wrappers ? pkexec && cfg.security.wrappers.pkexec.enable;
      assert
        builtins.match ".*(policykit\\.exec|AUTH_ADMIN_KEEP).*" cfg.security.polkit.extraConfig == null;
      # The path the GUI runs proxy-ctl by, which pkexec matches after realpath.
      assert has
        ''<annotate key="org\.freedesktop\.policykit\.exec\.path">${proxyCtl}/bin/proxy-ctl</annotate>'';
      # Never kept: a kept grant is the whole session's, and proxy-ctl as root runs commands.
      assert has "<allow_active>auth_admin</allow_active>";
      assert has "<allow_any>auth_admin</allow_any>";
      assert has "<allow_inactive>auth_admin</allow_inactive>";
      # Where NixOS's polkitd reads actions: the system profile's share/polkit-1/actions.
      assert packagePathMatches cfg.environment.systemPackages ".*-proxy-suite-polkit-actions$";
      assert tuiOffFixture.config.services.proxy-suite.internal.polkit.actions == { };
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
