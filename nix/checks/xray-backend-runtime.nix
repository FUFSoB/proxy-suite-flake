{
  checkLib,
  pkgs,
  evalProxySuite,
  mkTProxyConfig,
  mkTunConfig,
  mkPerAppTunConfig,
  shellValueByPrefix,
  checkConstants,
}:

let
  fillTemplate = import ../../modules/proxy-suite/lib/fill-template.nix;
  fixtures = import ./xray-backend-runtime/fixtures.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      mkTProxyConfig
      mkTunConfig
      mkPerAppTunConfig
      shellValueByPrefix
      ;
  };

  inherit (fixtures)
    xrayBackendJqFilter
    xrayBackendJqFilterFile
    xrayFixture
    xrayPerAppTunBackendJqFilterFile
    xrayPerAppTunCleanupScript
    xrayPerAppTunConfig
    xrayPerAppTunConfigJson
    xrayPerAppTunStartScript
    xrayPerAppTunUpScript
    xrayStartBackendJqFilterFile
    xrayStartScript
    xrayTproxyConfig
    xrayTunBackendJqFilterFile
    xrayTunConfig
    xrayTunConfigJson
    xrayTunStartScript
    xrayTunUpScript
    ;
  xrayJqFilterRuntimeCheck =
    pkgs.runCommand "proxy-suite-xray-jq-filter-runtime-check" { nativeBuildInputs = [ pkgs.jq ]; }
      (
        fillTemplate ./xray-backend-runtime/jq-filter-runtime.template.sh {
          jqFilter = pkgs.lib.escapeShellArg xrayBackendJqFilterFile;
          tunConfig = pkgs.lib.escapeShellArg xrayTunConfigJson;
          perAppTunConfig = pkgs.lib.escapeShellArg xrayPerAppTunConfigJson;
        }
      );

  serviceShapeChecks = import ./xray-backend-runtime/service-shape.nix {
    inherit
      pkgs
      xrayFixture
      xrayTproxyConfig
      xrayStartScript
      ;
  };
  tunChecks = import ./xray-backend-runtime/tun.nix {
    inherit checkLib;
    inherit
      pkgs
      checkConstants
      xrayTunConfig
      xrayPerAppTunConfig
      xrayStartBackendJqFilterFile
      xrayTunBackendJqFilterFile
      xrayPerAppTunBackendJqFilterFile
      xrayStartScript
      xrayTunStartScript
      xrayTunUpScript
      xrayPerAppTunStartScript
      xrayPerAppTunUpScript
      xrayPerAppTunCleanupScript
      xrayBackendJqFilter
      ;
  };
in
{
  runtime = xrayJqFilterRuntimeCheck;

  assertions = serviceShapeChecks.assertions ++ tunChecks.assertions;
}
