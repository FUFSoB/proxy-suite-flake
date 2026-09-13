{ pkgs }:
let
  amneziaWg = import ./amneziawg.nix { inherit pkgs; };
  mkTgWsProxy = _args: import ./tg-ws-proxy.nix { inherit pkgs; };
  mkProxySuiteTray = args: import ./proxy-suite-tray.nix ({ inherit pkgs; } // args);
  zapret2 = import ./zapret2.nix { inherit pkgs; };
  mkProxyCtl = import ./proxy-ctl.nix {
    lib = pkgs.lib;
    inherit pkgs;
  };
in
{
  inherit amneziaWg;
  amneziawg-tools = amneziaWg.tools;
  amneziawg-go = amneziaWg.userspace;
  inherit
    mkTgWsProxy
    mkProxySuiteTray
    mkProxyCtl
    zapret2
    ;
  tg-ws-proxy = mkTgWsProxy { };
  proxy-suite-tray = mkProxySuiteTray { };
}
