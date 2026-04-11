{ pkgs }:
{
  tg-ws-proxy = import ./tg-ws-proxy.nix { inherit pkgs; };
}
