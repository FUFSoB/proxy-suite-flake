{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    subscriptions = [ { tag = "provider"; urlFile = "/run/secrets/provider-sub-url"; } ];
    selection = "urltest";
  };
};
}
