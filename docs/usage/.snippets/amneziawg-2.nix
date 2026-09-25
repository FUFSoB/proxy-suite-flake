{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy.enable = true;
  amneziaWg = {
    enable = true;
    profiles.de = {
      configFile = "/run/secrets/de-awg.conf";
      asOutbound = "interface";
    };
  };
};
}
