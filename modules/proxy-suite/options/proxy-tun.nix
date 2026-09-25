{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.proxy-suite.proxy.tun = {
    enable = mkEnableOption "global TUN mode";

    interface = mkOption {
      type = types.str;
      default = "singtun0";
      description = "TUN interface name.";
    };

    address = mkOption {
      type = types.str;
      default = "172.19.0.1/30";
      description = "TUN interface address (CIDR).";
    };

    mtu = mkOption {
      type = types.int;
      default = 1400;
      description = "TUN interface MTU.";
    };
  };
}
