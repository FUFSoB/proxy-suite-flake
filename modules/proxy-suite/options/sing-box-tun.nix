{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;

  mkTunCommonFields =
    {
      interfaceDefault,
      interfaceDescription,
      addressDefault,
      addressDescription,
      mtuDefault,
      mtuDescription,
    }:
    {
      interface = mkOption {
        type = types.str;
        default = interfaceDefault;
        description = interfaceDescription;
        example = interfaceDefault;
      };

      address = mkOption {
        type = types.str;
        default = addressDefault;
        description = addressDescription;
        example = addressDefault;
      };

      mtu = mkOption {
        type = types.int;
        default = mtuDefault;
        description = mtuDescription;
        example = mtuDefault;
      };
    };
in
{
  options.services.proxy-suite.singBox.tun = {
    enable = mkEnableOption "global sing-box TUN mode service";

    autostart = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to start proxy-suite-tun automatically during boot by
        attaching it to multi-user.target.
        Cannot be enabled together with singBox.tproxy.autostart.
      '';
      example = true;
    };

    perApp = {
      enable = mkEnableOption "per-app-scoped sing-box TUN backend for perAppRouting profiles";

      fwmark = mkOption {
        type = types.int;
        default = 16;
        description = ''
          Packet mark used to steer wrapped app traffic into the per-app-scoped
          TUN policy-routing table.
        '';
        example = 16;
      };

      routeTable = mkOption {
        type = types.int;
        default = 101;
        description = ''
          Policy-routing table used by the per-app-scoped TUN backend.
        '';
        example = 101;
      };

      localSubnets = mkOption {
        type = types.listOf types.str;
        default = [ "192.168.0.0/16" ];
        description = ''
          Destination subnets that should bypass the per-app-scoped TUN mark,
          so wrapped apps can still reach local LAN resources directly.
        '';
        example = [
          "192.168.0.0/16"
          "10.0.0.0/8"
        ];
      };
    }
    // mkTunCommonFields {
      interfaceDefault = "psperapptun0";
      interfaceDescription = ''
        Name of the dedicated per-app-routing TUN interface used by
        proxy-suite-per-app-tun.
      '';
      addressDefault = "172.20.0.1/30";
      addressDescription = ''
        Address assigned to the dedicated per-app-routing TUN interface in CIDR
        notation.
      '';
      mtuDefault = 1400;
      mtuDescription = "MTU for the dedicated per-app-routing TUN interface.";
    };
  }
  // mkTunCommonFields {
    interfaceDefault = "singtun0";
    interfaceDescription = "Name of the TUN interface created by proxy-suite-tun.";
    addressDefault = "172.19.0.1/30";
    addressDescription = "Address assigned to the global TUN interface in CIDR notation.";
    mtuDefault = 1400;
    mtuDescription = "MTU for the global TUN interface created by proxy-suite-tun.";
  };
}
