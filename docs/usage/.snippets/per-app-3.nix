{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "nl"; urlFile = "/run/secrets/nl-url"; } ];
  };
  perAppRouting = {
    enable = true;
    tun.enable = true;
    profiles = [ { name = "game"; route = "tun"; outbound = "nl"; } ];
  };
};
}
