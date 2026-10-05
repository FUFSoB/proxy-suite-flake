# Moves autoProxy's state dir from the old group-writable layout to root's alone, with the
# spool beside it. Run by the socks start script and the autoProxy units, whichever is first.
{ pkgs }:

let
  fillTemplate = import ./lib/fill-template.nix;
in
pkgs.writeShellScript "proxy-suite-autoproxy-migrate" (
  fillTemplate ./autoproxy-migrate.template.sh {
    path = pkgs.lib.makeBinPath [
      pkgs.coreutils
      pkgs.findutils
    ];
  }
)
