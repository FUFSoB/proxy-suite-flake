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
    ./warp.nix
    ./tg-ws-proxy.nix
    ./geodata.nix
    ./gui.nix
    ./tray.nix
    ./tui.nix
    ./user-control.nix
    ./host.nix
  ];

  options.services.proxy-suite.enable = lib.mkEnableOption "proxy-suite";
}
