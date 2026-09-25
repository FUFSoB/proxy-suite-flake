{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.proxy-suite.proxy.tproxy = {
    enable = mkEnableOption "global TProxy mode";

    port = mkOption {
      type = types.port;
      default = 1085;
      description = "Local port that intercepted traffic is redirected to.";
    };

    fwmark = mkOption {
      type = types.int;
      default = 1;
      description = "Firewall mark for intercepted packets.";
    };

    proxyMark = mkOption {
      type = types.int;
      default = 2;
      description = "Firewall mark for the proxy's own traffic, so it is not intercepted again.";
    };

    routeTable = mkOption {
      type = types.int;
      default = 100;
      description = "Routing table for intercepted traffic.";
    };

    localSubnets = mkOption {
      type = types.listOf types.str;
      default = [ "192.168.0.0/16" ];
      description = "Subnets that skip the proxy, such as your LAN and VM bridges (DNS still goes through it). IPv6 works too.";
      example = [
        "192.168.0.0/16"
        "10.0.0.0/8"
        "fd00::/8"
      ];
    };

    lanInterfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        LAN interfaces whose devices use this host as their gateway. Their TCP and UDP goes through the
        proxy; everything else is forwarded as usual. Turns on IP forwarding. Needs the nftables
        firewall on NixOS.
      '';
      example = [ "br0" ];
    };
  };
}
