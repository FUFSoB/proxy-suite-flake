{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    tun.enable = true;
    autostart = "tun"; # or null, to start it by hand
  };
  killSwitch.enable = true;
};
}
