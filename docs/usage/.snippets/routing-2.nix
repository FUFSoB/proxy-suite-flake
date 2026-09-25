{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [
      { tag = "nl-vps"; urlFile = "/run/secrets/nl-vps-url"; }
      { tag = "us-vps"; urlFile = "/run/secrets/us-vps-url"; }
    ];
    routing = {
      rules = [ { geosites = [ "netflix" ]; outbound = "us-vps"; } ];
      direct.domains = [ "bank.example" ];
      block.geosites = [ "category-ads-all" ];
    };
  };
};
}
