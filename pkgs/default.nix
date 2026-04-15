{ pkgs }:
{
  tg-ws-proxy = import ./tg-ws-proxy.nix { inherit pkgs; };
  proxy-suite-tray = import ./proxy-suite-tray.nix { inherit pkgs; };
}
