{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  mitm = {
    enable = true;
    requestLog.enable = true;
  };
};
}
