{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  perAppRouting = {
    enable = true;
    createDefaultProfiles = true; # a profile named after each method below
    proxychains.enable = true;
    tun.enable = true;
  };
};
}
