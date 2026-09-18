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

  userUnits = (import ./common.nix { inherit lib; }).userUnitsFor {
    inherit
      lib
      pkgs
      host
      internal
      ;
  };
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
          systemd.user.services = userUnits.services;
          systemd.user.timers = userUnits.timers;
          systemd.user.paths = userUnits.paths;

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
