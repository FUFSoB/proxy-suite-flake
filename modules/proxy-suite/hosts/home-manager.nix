# home-manager: the services run rootless in the user's systemd manager, rendered into
# home-manager's INI form by ./user-units.nix.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.proxy-suite;
  host = cfg.host;
  internal = cfg.internal;

  inherit
    (import ./user-units.nix {
      inherit lib pkgs;
      inherit (host) runtimeDir;
      stateDir = dirOf host.stateDir;
    })
    toService
    toTimer
    toPath
    ;

  enabled = lib.filterAttrs (_: unit: unit.enable);
in
{
  config = lib.mkMerge [
    {
      services.proxy-suite.host = {
        kind = "home-manager";
        privileged = false;
        serviceManager = "systemd-user";
        stateDir = lib.mkDefault "${config.xdg.stateHome}/proxy-suite";
        # A literal path the scripts and proxy-ctl can share: the user's runtime
        # directory is only known once the manager runs. Point it at /run/user/UID to
        # have it cleared on reboot.
        runtimeDir = lib.mkDefault "${config.xdg.cacheHome}/proxy-suite/run";
      };
    }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          systemd.user.services = lib.mapAttrs toService (
            enabled (internal.services // internal.userServices)
          );
          systemd.user.timers = lib.mapAttrs toTimer (enabled internal.timers);
          systemd.user.paths = lib.mapAttrs toPath (enabled internal.paths);

          home.packages = lib.mkMerge [
            (lib.mkBefore internal.earlyPackages)
            internal.packages
          ];
        }
        (lib.optionalAttrs (options.systemd.user ? tmpfiles) {
          systemd.user.tmpfiles.rules = internal.tmpfiles;
        })
      ]
    ))
  ];
}
