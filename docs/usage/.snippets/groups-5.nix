{ config, lib, pkgs, ... }:
{
  services.proxy-suite.warp = {
  enable = true;
  asOutbound = "interface";
  devices = {
    warp-a = { };
    warp-b.endpoint = "162.159.193.10:500";
  };
  group.strategy = "failover";
};
}
