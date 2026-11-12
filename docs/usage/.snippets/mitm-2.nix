{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  mitm = {
    enable = true;
    web.enable = true;
    listener = {
      address = "0.0.0.0";
      openFirewall = true;
      auth = {
        username = "phone";
        passwordFile = "/run/secrets/mitm-listener";
      };
    };
  };
};
}
