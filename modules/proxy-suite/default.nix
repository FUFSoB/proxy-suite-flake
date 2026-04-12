# Factory function — receives the zapret flake, returns a NixOS module.
# This lets consumers add a single flake input and get everything transitively.
{ zapret }:

{ config, lib, pkgs, ... }:

let
  cfg = config.services.proxy-suite;
in
{
  imports = [
    ./options.nix
    # Always import the zapret module so its options are available,
    # but we only activate services when cfg.zapret.enable = true.
    zapret.nixosModules.default
  ];

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf cfg.singBox.enable (
      let
        rules = import ./rules.nix { inherit lib pkgs cfg zapret; };
        configs = import ./config.nix { inherit lib pkgs cfg rules; };
        nftr = import ./nftables.nix { inherit lib pkgs cfg; };
      in
      import ./service.nix {
        inherit config lib pkgs cfg;
        inherit (configs) tproxyFile tunFile;
        inherit (nftr) nftablesRulesFile ip nft;
      }
    ))

    (lib.mkIf cfg.zapret.enable (
      import ./zapret.nix { inherit lib pkgs cfg; }
    ))

    (lib.mkIf cfg.tgWsProxy.enable (
      import ./tg-ws-proxy.nix { inherit lib pkgs cfg; }
    ))

    (lib.mkIf cfg.tray.enable (
      import ./tray.nix { inherit config lib pkgs cfg; }
    ))
  ]);
}
