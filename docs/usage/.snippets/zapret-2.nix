{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  zapret = {
    enable = true;
    engine = "zapret2";
    zapret2.domains = [ "rutracker.org" ]; # always treated as blocked
  };
};
}
