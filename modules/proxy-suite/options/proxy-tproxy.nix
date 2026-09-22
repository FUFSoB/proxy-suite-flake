{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.proxy-suite.proxy.tproxy = {
    enable = mkEnableOption "global TProxy mode (proxy-suite-tproxy)";

    port = mkOption {
      type = types.port;
      default = 1085;
      description = "Port of the TProxy inbound.";
    };

    fwmark = mkOption {
      type = types.int;
      default = 1;
      description = "Mark of intercepted packets, routed through routeTable.";
    };

    proxyMark = mkOption {
      type = types.int;
      default = 2;
      description = "Mark of the backend's own traffic, so it is not intercepted again.";
    };

    routeTable = mkOption {
      type = types.int;
      default = 100;
      description = "Policy-routing table for intercepted traffic.";
    };

    localSubnets = mkOption {
      type = types.listOf types.str;
      default = [ "192.168.0.0/16" ];
      description = "Subnets that bypass interception (DNS excepted): your LAN, VM bridges. IPv6 CIDRs work too.";
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
        Interfaces whose forwarded TCP and UDP is taken through the proxy too: devices on them
        that use this host as their gateway. Turns on IP forwarding for the rest (ping, the LAN
        itself), which is routed as it is. Needs the nftables firewall on NixOS.
      '';
      example = [ "br0" ];
    };
  };
}
