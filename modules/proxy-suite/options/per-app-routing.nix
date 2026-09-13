{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  t = import ./types.nix { inherit lib; };
  int =
    default: description:
    mkOption {
      type = types.int;
      inherit default description;
    };
  localSubnets =
    description:
    mkOption {
      type = types.listOf types.str;
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
        Add a profile named after each enabled backend (proxychains, tun, tproxy, zapret) unless
        one with that name already exists.
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
      enable = mkEnableOption "the proxychains backend (TCP apps, through LD_PRELOAD)";

      quiet = mkOption {
        type = types.bool;
        default = true;
        description = "Silence proxychains (quiet_mode).";
      };

      proxyDns = mkOption {
        type = types.bool;
        default = true;
        description = "Resolve DNS through the proxy (proxy_dns).";
      };
    };

    tun = {
      enable = mkEnableOption "the per-app TUN backend";
      fwmark = int 16 "Mark that steers wrapped apps into routeTable.";
      routeTable = int 101 "Policy-routing table of the per-app TUN.";
      localSubnets = localSubnets "Subnets wrapped apps reach directly.";

      interface = mkOption {
        type = types.str;
        default = "psperapptun0";
        description = "Per-app TUN interface name.";
      };

      address = mkOption {
        type = types.str;
        default = "172.20.0.1/30";
        description = "Per-app TUN interface address (CIDR).";
      };

      mtu = int 1400 "Per-app TUN interface MTU.";
    };

    tproxy = {
      enable = mkEnableOption "the per-app TProxy backend";
      fwmark = int 17 "Mark that steers wrapped apps into routeTable.";
      routeTable = int 102 "Policy-routing table of the per-app TProxy.";
      localSubnets = localSubnets "Subnets that bypass interception (DNS excepted).";
    };

    zapret = {
      enable = mkEnableOption "the per-app zapret backend: a second zapret instance for wrapped apps only";
      filterMark = int 268435456 "Mark bit that selects wrapped app traffic.";
      qnum = int 201 "NFQUEUE number. Must differ from the global instance's.";
    };
  };
}
