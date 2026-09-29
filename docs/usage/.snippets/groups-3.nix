{ config, lib, pkgs, ... }:
{
  services.proxy-suite.proxy = {
  enable = true;
  selection = "failover";
  priority = { eu = 10; warp = 20; };
};
}
