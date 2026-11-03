{ config, lib, pkgs, ... }:
{
  services.proxy-suite.proxy.routing = {
  proxy.asns = [ 62041 ];          # Telegram's data centres
  direct.asns = [ "AS24940" ];     # your own servers at Hetzner
};
}
