{ pkgs }:
let
  amneziaWg = import ./amneziawg.nix { inherit pkgs; };
  mkTgWsProxy = _args: import ./tg-ws-proxy.nix { inherit pkgs; };
  mkProxySuiteTray = args: import ./proxy-suite-tray.nix ({ inherit pkgs; } // args);
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
    ;
  tg-ws-proxy = mkTgWsProxy { };
  proxy-suite-tray = mkProxySuiteTray { };
}
