{ config, lib, pkgs, ... }:
{
  services.proxy-suite.zapret.zapret2.ports.extraUdp = [ "27015-27030" ];
}
