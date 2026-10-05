{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  t = import ./types.nix { inherit lib; };
  inherit (import ./lib.nix { inherit lib; })
    int
    addressOrCidrType
    interfaceType
    ipv4CidrType
    ;
  localSubnets =
    description:
    mkOption {
      type = types.listOf addressOrCidrType;
      default = [ "192.168.0.0/16" ];
      inherit description;
      example = [
        "192.168.0.0/16"
        "10.0.0.0/8"
      ];
    };
in
{
  options.services.proxy-suite.perAppRouting = {
    enable = mkEnableOption "per-app routing (`proxy-ctl apps run`)";

    createDefaultProfiles = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add a profile for each enabled method (proxychains, tun, tproxy, zapret), named after it,
        unless one already exists.
      '';
    };

    profiles = mkOption {
      type = types.listOf t.perAppRoutingProfileType;
      default = [ ];
      description = "Profiles for `proxy-ctl apps run <name> -- <command>`.";
      example = [
        {
          name = "steam-browser";
          route = "proxychains";
        }
      ];
    };

    proxychains = {
      enable = mkEnableOption "proxychains (TCP only, does not work with static binaries)";

      quiet = mkOption {
        type = types.bool;
        default = true;
        description = "Hide proxychains output.";
      };

      proxyDns = mkOption {
        type = types.bool;
        default = true;
        description = "Resolve DNS through the proxy.";
      };
    };

    tun = {
      enable = mkEnableOption "per-app TUN";
      fwmark = int 16 "Firewall mark for wrapped apps' traffic.";
      routeTable = int 101 "Routing table for the per-app TUN.";
      localSubnets = localSubnets "Subnets that skip the proxy (DNS still goes through it).";

      interface = mkOption {
        type = interfaceType;
        default = "psperapptun0";
        description = "Interface name.";
      };

      address = mkOption {
        type = ipv4CidrType;
        default = "172.20.0.1/30";
        description = "Interface IPv4 address (CIDR).";
      };

      mtu = int 1400 "Interface MTU.";
    };

    tproxy = {
      enable = mkEnableOption "per-app TProxy";
      fwmark = int 17 "Firewall mark for wrapped apps' traffic.";
      routeTable = int 102 "Routing table for the per-app TProxy.";
      localSubnets = localSubnets "Subnets that skip the proxy (DNS still goes through it).";
    };

    via = {
      pinSlots = int 8 ''
        How many outbounds `apps run --via` can send apps through at once, for per-app TProxy
        and again for per-app TUN; at most 16. Apps via the same outbound share one. An
        "interface" AmneziaWG outbound takes none: apps enter it directly.
      '';

      localSubnets = localSubnets ''
        Subnets an app run `--via` an AmneziaWG interface (an "interface" outbound or a global
        profile) still reaches directly; DNS still goes through the tunnel. Every other
        address goes through it, private ones included, as the server may serve them.
      '';
    };

    zapret = {
      enable = mkEnableOption "per-app zapret, a separate zapret for wrapped apps only";
      filterMark = int 268435456 "Firewall mark bit for wrapped apps' traffic.";
      qnum = int 201 "NFQUEUE number. Must differ from the global zapret's.";
    };
  };
}
