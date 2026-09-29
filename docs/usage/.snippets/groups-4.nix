{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  amneziaWg.enable = true;
  proxy.enable = true;
  warp = {
    enable = true;
    asOutbound = "interface";
    instances = 2; # warp-1 (keeps an existing registration) and warp-2
  };
};
}
