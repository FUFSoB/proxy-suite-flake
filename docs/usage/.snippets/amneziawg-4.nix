{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  amneziaWg.enable = true; # no profiles needed
  userControl = {
    enable = true;
    scopes = [ "services" "amneziaWg" "outbounds" ]; # optional: no sudo for these
  };
};
}
