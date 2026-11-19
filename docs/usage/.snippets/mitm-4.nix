{ config, lib, pkgs, ... }:
{
  services.proxy-suite.proxy.tproxy.bridgeNetfilter = "off";
}
