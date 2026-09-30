{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  userControl = {
    enable = true;
    scopes = [ "routing" ];
    groups = {
      proxy-admins.scopes = [ ];
      proxy-users.scopes = [ "perApp" "outbounds" ];
    };
  };
};
users.users.alice.extraGroups = [ "proxy-admins" ];
users.users.bob.extraGroups = [ "proxy-users" ];
}
