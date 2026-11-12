{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  mitm = {
    enable = true;
    web.enable = true; # mitmweb; without it, a line per request in the log
  };
};
}
