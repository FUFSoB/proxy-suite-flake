{ pkgs }:
let
  amneziaWg = import ./amneziawg.nix { inherit pkgs; };
  mkTgWsProxy = _args: import ./tg-ws-proxy.nix { inherit pkgs; };
  zapret2 = import ./zapret2.nix { inherit pkgs; };
  mkProxySuiteSupervisor = import ./proxy-suite-supervisor.nix {
    lib = pkgs.lib;
    inherit pkgs;
  };
  mkProxyCtl = import ./proxy-ctl.nix {
    lib = pkgs.lib;
    inherit pkgs;
  };
in
{
  inherit amneziaWg;
  amneziawg-tools = amneziaWg.tools;
  amneziawg-go = amneziaWg.userspace;
  wireproxy-awg = amneziaWg.wireproxy;
  inherit
    mkTgWsProxy
    mkProxyCtl
    mkProxySuiteSupervisor
    zapret2
    ;
  tg-ws-proxy = mkTgWsProxy { };
}
