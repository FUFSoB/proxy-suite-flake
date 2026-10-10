{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "nl"; urlFile = "/run/secrets/nl-url"; } ];
  };
  amneziaWg = {
    enable = true;
    profiles.home.configFile = "/run/secrets/home.conf";
  };
  perAppRouting = {
    enable = true;
    tun.enable = true;
    profiles = [
      { name = "game"; route = "tun"; outbound = "nl"; keepRunning = true; }
      { name = "home"; outbound = "awg:home"; keepRunning = true; }
    ];
  };
};
}
