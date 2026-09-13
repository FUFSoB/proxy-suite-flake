{ lib, ... }:
{
  imports = [
    ./removed.nix
    ./proxy.nix
    ./proxy-outbounds.nix
    ./proxy-dns.nix
    ./proxy-routing.nix
    ./proxy-tun.nix
    ./proxy-tproxy.nix
    ./inbounds.nix
    ./per-app-routing.nix
    ./zapret.nix
    ./zapret2.nix
    ./amnezia-wg.nix
    ./ssh-proxy.nix
    ./tg-ws-proxy.nix
    ./geodata.nix
    ./tray.nix
    ./user-control.nix
  ];

  options.services.proxy-suite.enable = lib.mkEnableOption "proxy-suite";
}
