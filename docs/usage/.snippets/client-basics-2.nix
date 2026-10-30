{ config, lib, pkgs, ... }:
{
  services.proxy-suite.proxy.outbounds = [
  {
    tag = "shadowtls";
    urlFile = "/run/secrets/ss-url"; # ss://2022-blake3-aes-128-gcm:<server key>:<user key>@vpn.example.com:8445
    shadowTls = {
      serverName = "www.microsoft.com";
      passwordFile = "/run/secrets/shadowtls-password";
    };
  }
];
}
