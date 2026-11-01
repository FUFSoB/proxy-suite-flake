{ config, lib, pkgs, ... }:
{
  services.proxy-suite.inbounds.subscriptions = {
  enable = true;
  baseUrl = "https://vpn.example.com/sub";
};
services.nginx.virtualHosts."vpn.example.com".locations."/sub/" = {
  alias = "/run/proxy-suite-inbounds/subscriptions/";
  extraConfig = "access_log off;";   # the token is the URL's secret
};
}
