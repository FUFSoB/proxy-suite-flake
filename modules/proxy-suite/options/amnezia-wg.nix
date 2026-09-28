{
  config,
  lib,
  proxySuiteUpstream,
  ...
}:

let
  inherit (lib)
    literalMD
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
      defaultText = literalMD "proxy-suite's patched `amneziawg-tools` (`pkgs/amneziawg.nix`)";
      description = "AWG 3.1 package with `awg` and `awg-quick`.";
    };

    userspacePackage = mkOption {
      type = types.package;
      default = awgPackages.userspace;
      defaultText = literalMD "proxy-suite's patched `amneziawg-go` (`pkgs/amneziawg.nix`)";
      description = "AWG 3.1 userspace implementation, used when the kernel module is unavailable.";
    };

    wireproxyPackage = mkOption {
      type = types.package;
      default = awgPackages.wireproxy;
      defaultText = literalMD "proxy-suite's `wireproxy-awg` (`pkgs/wireproxy-awg.nix`)";
      description = "wireproxy build with AWG 3.1, used by profiles with `asOutbound = \"userspace\"`.";
    };

    kernelModulePackage = mkOption {
      type = types.nullOr types.package;
      default =
        let
          kernelPackages = config.services.proxy-suite.host.kernelPackages;
        in
        if kernelPackages == null then null else awgPackages.kernelModule kernelPackages;
      defaultText = literalMD "`amneziawg` from `boot.kernelPackages` on NixOS, `null` elsewhere";
      description = "AWG 3.1 kernel module package. `null`: userspace only.";
    };

    serverUdpPorts = mkOption {
      type = types.listOf (types.either types.port (types.strMatching "[0-9]+-[0-9]+"));
      default = [ ];
      description = ''
        UDP ports of services on this host that others reach, whose packets a global profile
        leaves on the host's own routes. A reply from a socket bound to every address would
        otherwise leave through the tunnel, from the tunnel's address. The UDP inbound listeners
        and, on NixOS, the ports the firewall opens are included already.
      '';
      example = [
        3478
        "49152-65535"
      ];
    };

    runtime = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Let `proxy-ctl` add configs and `vpn://` links without a rebuild: `proxy-ctl awg add`
          for a global profile (root hosts only), and `proxy-ctl proxy outbounds add` for an
          outbound, which runs in wireproxy (needs `proxy.enable`). wg-quick hooks such as
          `PostUp` are always refused in them. With this on, `profiles` may be empty.
        '';
      };

      interfaceName = mkOption {
        type = types.strMatching "^[A-Za-z0-9_.-]{1,15}$";
        default = "awg-rt";
        description = "Interface of the global profiles added at runtime. Only one of them runs at a time, so they share it.";
      };
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
