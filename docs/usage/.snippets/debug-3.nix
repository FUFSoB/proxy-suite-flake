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
    tproxy.enable = true;
  };
  debug.perAppDns = true;
};
}
