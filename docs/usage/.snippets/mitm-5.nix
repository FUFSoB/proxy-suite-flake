{ config, lib, pkgs, ... }:
{
  networking.nftables.enable = true;
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  mitm = {
    enable = true;
    interfaces = [ "waydroid0" ];
    udp.enable = true;
  };
};
}
