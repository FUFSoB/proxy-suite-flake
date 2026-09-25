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
    enable = mkEnableOption "AmneziaWG client profiles";

    toolsPackage = mkOption {
      type = types.package;
      default = awgPackages.tools;
      description = "AWG 3.1 package with `awg` and `awg-quick`.";
    };

    userspacePackage = mkOption {
      type = types.package;
      default = awgPackages.userspace;
      description = "AWG 3.1 userspace implementation, used when the kernel module is unavailable.";
    };

    wireproxyPackage = mkOption {
      type = types.package;
      default = awgPackages.wireproxy;
      description = "wireproxy build with AWG 3.1, used by profiles with `asOutbound = \"userspace\"`.";
    };

    kernelModulePackage = mkOption {
      type = types.nullOr types.package;
      default =
        let
          kernelPackages = config.services.proxy-suite.host.kernelPackages;
        in
        if kernelPackages == null then null else awgPackages.kernelModule kernelPackages;
      description = "AWG 3.1 kernel module package. `null`: userspace only.";
    };

    profiles = mkOption {
      type = types.attrsOf t.profileType;
      default = { };
      description = ''
        AmneziaWG client profiles, by name. Each sets exactly one of `configFile`, `vpnFile`, `vpn`
        or `settings`. Only one global profile can run at a time.

        When handshakes go unanswered, a profile switches to a new source port on its own.
        Setting `settings.listenPort` pins the port and turns this off.
      '';
    };
  };
}
