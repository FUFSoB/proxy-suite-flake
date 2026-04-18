{ pkgs }:
let
  mkTgWsProxy = _args: import ./tg-ws-proxy.nix { inherit pkgs; };
  mkProxySuiteTray = args: import ./proxy-suite-tray.nix ({ inherit pkgs; } // args);
  mkProxyCtl = import ./proxy-ctl.nix {
    lib = pkgs.lib;
    inherit pkgs;
  };
in
{
  inherit
    mkTgWsProxy
    mkProxySuiteTray
    mkProxyCtl
    ;
  tg-ws-proxy = mkTgWsProxy { };
  proxy-suite-tray = mkProxySuiteTray { };
}
