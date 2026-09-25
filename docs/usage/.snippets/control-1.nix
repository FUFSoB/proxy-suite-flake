{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  gui.enable = true;
  userControl = {
    enable = true;
    scopes = [ "services" "routing" "outbounds" "perApp" ];
  };
};
users.users.alice.extraGroups = [ "proxy-suite" ];
}
