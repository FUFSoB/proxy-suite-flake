{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  inherit (import ./lib.nix { inherit lib; }) interfaceType ipv4CidrType;
in
{
  options.services.proxy-suite.proxy.tun = {
    enable = mkEnableOption "global TUN mode";

    only = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run the global TUN alone, with no local SOCKS5/HTTP listener: `proxy.socks.enable = false`.
        For a host whose apps need no system proxy. Requires `proxy.tun.enable`.
      '';
    };

    interface = mkOption {
      type = interfaceType;
      default = "singtun0";
      description = "TUN interface name.";
    };

    address = mkOption {
      type = ipv4CidrType;
      default = "172.19.0.1/30";
      description = "TUN interface IPv4 address (CIDR).";
    };

    mtu = mkOption {
      type = types.int;
      default = 1400;
      description = "TUN interface MTU.";
    };
  };
}
