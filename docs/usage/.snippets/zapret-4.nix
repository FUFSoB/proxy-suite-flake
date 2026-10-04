{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  zapret = {
    enable = true;
    global.enable = false; # no system-wide zapret
  };
  perAppRouting = {
    enable = true;
    createDefaultProfiles = true; # adds a profile named "zapret"
    zapret.enable = true;
  };
};
}
