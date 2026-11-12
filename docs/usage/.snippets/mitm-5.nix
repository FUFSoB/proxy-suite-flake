{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  mitm = {
    enable = true;
    ca = {
      certFile = "/run/secrets/mitm-ca.crt";
      keyFile = "/run/secrets/mitm-ca.key";
    };
  };
};
}
