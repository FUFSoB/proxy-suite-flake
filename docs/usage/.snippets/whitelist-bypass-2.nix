{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy.enable = true;
  whitelistBypass = {
    enable = true;
    joiners.wl.platform = "wbstream";
  };
};
}
