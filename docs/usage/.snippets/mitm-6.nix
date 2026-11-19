{ config, pkgs, ... }:
{
  services.proxy-suite = {
    enable = true;
    mitm.enable = true;
  };
  environment.systemPackages = [
    (config.lib.proxy-suite.mitm.wrap { } pkgs.httpie)
  ];
}