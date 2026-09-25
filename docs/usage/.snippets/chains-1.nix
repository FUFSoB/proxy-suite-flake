{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [
      { tag = "hop"; urlFile = "/run/secrets/hop-url"; }
      { tag = "de-vps"; urlFile = "/run/secrets/de-vps-url"; detour = "hop"; }
    ];
    selectionExclude = [ "hop" ]; # never picked as the exit on its own
  };
};
}
