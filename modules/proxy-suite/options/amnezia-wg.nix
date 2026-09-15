{
  config,
  lib,
  proxySuiteUpstream,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;
  t = import ./types.nix { inherit lib; };
  awgPackages = proxySuiteUpstream.amneziaWg;
in
{
  options.services.proxy-suite.amneziaWg = {
    enable = mkEnableOption "native AmneziaWG client profiles";

    toolsPackage = mkOption {
      type = types.package;
      default = awgPackages.tools;
      description = "AWG 3.1 package providing awg and awg-quick.";
    };

    userspacePackage = mkOption {
      type = types.package;
      default = awgPackages.userspace;
      description = "AWG 3.1 userspace implementation used when the kernel interface is unavailable.";
    };

    kernelModulePackage = mkOption {
      type = types.nullOr types.package;
      default = awgPackages.kernelModule config.boot.kernelPackages;
      description = "AWG 3.1 kernel module package. Set null to use userspace-only fallback.";
    };

    profiles = mkOption {
      type = types.attrsOf t.profileType;
      default = { };
      description = "Named AmneziaWG client profiles. Only one global profile can be active.";
    };
  };
}
