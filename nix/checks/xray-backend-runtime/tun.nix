{
  pkgs,
  checkConstants,
  xrayTunConfig,
  xrayPerAppTunConfig,
  xrayStartBackendJqFilterFile,
  xrayTunBackendJqFilterFile,
  xrayPerAppTunBackendJqFilterFile,
  xrayStartScript,
  xrayTunStartScript,
  xrayTunUpScript,
  xrayPerAppTunStartScript,
  xrayPerAppTunUpScript,
  xrayPerAppTunCleanupScript,
  xrayBackendJqFilter,
}:

let
  backendFilterChecks = import ./tun/backend-filter.nix {
    inherit
      pkgs
      xrayStartBackendJqFilterFile
      xrayTunBackendJqFilterFile
      xrayPerAppTunBackendJqFilterFile
      xrayStartScript
      xrayBackendJqFilter
      ;
  };

  globalTunChecks = import ./tun/global.nix {
    inherit
      pkgs
      checkConstants
      xrayTunConfig
      xrayTunStartScript
      xrayTunUpScript
      ;
  };

  perAppTunChecks = import ./tun/per-app.nix {
    inherit
      pkgs
      checkConstants
      xrayPerAppTunConfig
      xrayPerAppTunStartScript
      xrayPerAppTunUpScript
      xrayPerAppTunCleanupScript
      ;
  };
in
{
  assertions =
    backendFilterChecks.assertions ++ globalTunChecks.assertions ++ perAppTunChecks.assertions;
}
