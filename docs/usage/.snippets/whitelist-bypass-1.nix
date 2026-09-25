{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  whitelistBypass = {
    enable = true;
    creators.laptop = {
      platform = "wbstream";
      cookiesFile = "/run/secrets/wbstream-cookies.json";
    };
  };
};
}
