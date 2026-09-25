{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    routing = {
      default = "direct";
      proxy.domains = [ "youtube.com" "googlevideo.com" ];
      proxy.geosites = [ "instagram" ];
    };
    # Find blocked sites on its own, and route each one through an exit that reaches it.
    autoProxy.enable = true;
  };
};
}
