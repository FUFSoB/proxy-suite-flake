{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    routing = {
      default = "direct";
      ruleSets.blocked.url = "https://example.com/blocked.srs";
      proxy.ruleSets = [ "blocked" ];
    };
  };
};
}
