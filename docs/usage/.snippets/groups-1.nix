{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [
      { tag = "de-vps"; urlFile = "/run/secrets/de-vps-url"; }
      { tag = "nl-vps"; urlFile = "/run/secrets/nl-vps-url"; }
    ];
    groups.eu.outbounds = [ "de-vps" "nl-vps" ]; # de-vps first, nl-vps when it fails
  };
};
}
