{ config, lib, ... }:
let
  inherit (import ./lib.nix { inherit lib; }) addressOrCidrType;
  hostTimeSyncUsers = config.services.proxy-suite.host.timeSyncUsers;
in
{
  options.services.proxy-suite.killSwitch = {
    enable = lib.mkEnableOption "the kill switch" // {
      description = ''
        Block outgoing traffic that bypasses the active global tunnel (TUN, TProxy or a global
        AmneziaWG profile) from boot until the tunnel is up, while it restarts and after it
        fails. LAN, DHCP and the time daemons' NTP stay open. Forwarded traffic TProxy does not
        divert reaches the LAN only from `proxy.tproxy.lanInterfaces`. With TUN or a global
        AmneziaWG profile configured, containers' and VMs' traffic is held to the LAN too while
        neither that tunnel nor TProxy is up. Only turning the tunnel off with `proxy-ctl`, or
        `proxy-ctl killswitch off`, lifts it, until the next boot or tunnel start.
      '';
    };

    directFallbacks = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether, with the kill switch on, a subscription that cannot be fetched through the
        tunnel is fetched once more directly, and WARP registers directly when the local proxy
        cannot carry it. Either shows that server this host's own address. Off, both go through
        the tunnel or not at all: a cold start with nothing cached then has no outbounds from
        that subscription, and a WARP device that is itself the tunnel cannot register.
      '';
    };

    allowedSubnets = lib.mkOption {
      type = lib.types.listOf addressOrCidrType;
      default = config.services.proxy-suite.proxy.tproxy.localSubnets;
      defaultText = lib.literalExpression "config.services.proxy-suite.proxy.tproxy.localSubnets";
      description = ''
        Networks the kill switch leaves open besides the private and reserved ranges, such as
        a routed IPv6 prefix on a VM bridge, whichever global mode is on. The default keeps
        what TProxy leaves out reachable; set it to open a network without also taking it out
        of TProxy.
      '';
      example = [
        "192.168.0.0/16"
        "2001:db8:1::/64"
      ];
    };

    timeSyncUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        if hostTimeSyncUsers != null then
          hostTimeSyncUsers
        else
          [
            "systemd-timesync"
            "chrony"
            "_chrony"
            "ntp"
            "ntpsec"
          ];
      defaultText = lib.literalMD ''
        the users of the enabled timesyncd, chrony, ntp and openntpd on NixOS; elsewhere
        `[ "systemd-timesync" "chrony" "_chrony" "ntp" "ntpsec" ]`
      '';
      description = ''
        Users that may send NTP (UDP port 123) past the kill switch. Users that do not exist
        are skipped when it starts. A daemon sending from port 123 itself, as ntpd does, needs
        no entry.
      '';
      example = [ "chrony" ];
    };
  };
}
