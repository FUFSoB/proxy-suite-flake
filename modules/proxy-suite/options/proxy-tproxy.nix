{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  inherit (import ./lib.nix { inherit lib; }) addressOrCidrType interfaceType;
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
      type = types.listOf addressOrCidrType;
      default = [ "192.168.0.0/16" ];
      description = "Subnets that skip the proxy, such as your LAN and VM bridges (DNS still goes through it). IPv6 works too.";
      example = [
        "192.168.0.0/16"
        "10.0.0.0/8"
        "fd00::/8"
      ];
    };

    lanInterfaces = mkOption {
      type = types.listOf interfaceType;
      default = [ ];
      description = ''
        LAN interfaces whose devices use this host as their gateway. Their TCP and UDP goes through the
        proxy; everything else is forwarded as usual. Turns on IP forwarding. Needs the nftables
        firewall on NixOS.
      '';
      example = [ "br0" ];
    };

    bridgeNetfilter = mkOption {
      type = types.enum [
        "keep"
        "off"
      ];
      default = "keep";
      description = ''
        Bridge netfilter (`br_netfilter`, which Docker loads), where `lanInterfaces` or
        `mitm.interfaces` are bridges: a LAN `br0`, Waydroid's `waydroid0`. With
        `net.bridge.bridge-nf-call-iptables` on, what their devices send meets the divert inside
        the bridge, before the IP stack, which then drops the socket the divert handed it to:
        they get no TCP or UDP through at all.
        - "keep": leave it as it is. The divert units and `proxy-ctl mitm` say so when it bites.
        - "off": with either list set, turn `bridge-nf-call-iptables` and
          `bridge-nf-call-ip6tables` off at boot, as the divert comes up and each time Docker
          starts, which turns them on. Docker then no longer filters traffic between containers
          on one of its bridges with iptables.
      '';
      example = "off";
    };
  };
}
