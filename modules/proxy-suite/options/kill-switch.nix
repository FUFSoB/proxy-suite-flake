{ lib, ... }:
{
  options.services.proxy-suite.killSwitch.enable = lib.mkEnableOption "the kill switch" // {
    description = ''
      Block outgoing traffic that bypasses the active global tunnel (TUN, TProxy or a global
      AmneziaWG profile), including while it restarts or after it fails. LAN, DHCP and NTP stay
      open; `proxy.tproxy.lanInterfaces` devices keep the LAN but lose the internet. Only turning
      the tunnel off, or `proxy-ctl killswitch off`, lifts it.
    '';
  };
}
