{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  amneziaWg = {
    enable = true;
    profiles.home.configFile = "/run/secrets/home-awg.conf";
    profiles.work = {
      vpnFile = "/run/secrets/work-amnezia.vpn";
      autostart = true; # at most one profile
    };
  };
  killSwitch.enable = true; # optional: no leaks while the tunnel is down
};
}
