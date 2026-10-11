{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  debug.connectionLog = {
    enable = true;
    hosts = [ "x.com" "twimg.com" ]; # leave empty for every site
    inbounds = [ "tproxy" ]; # global and per-app TProxy only
  };
};
}
