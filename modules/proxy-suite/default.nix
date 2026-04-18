# Factory function – receives the zapret flake, returns a NixOS module.
# This lets consumers add a single flake input and get everything transitively.
{ zapret }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.proxy-suite;
  packages = import ../../pkgs/default.nix { inherit pkgs; };
  nftr = import ./nftables.nix { inherit lib pkgs cfg; };
in
{
  imports = [
    ./options
  ];

  config = lib.mkIf cfg.enable (
    let
      rules = import ./rules.nix {
        inherit
          lib
          pkgs
          cfg
          zapret
          ;
      };
      configs = import ./config.nix {
        inherit
          lib
          pkgs
          cfg
          rules
          ;
      };
    in
    lib.mkMerge [
      (import ./service {
        inherit
          config
          lib
          pkgs
          packages
          cfg
          ;
        inherit (configs) tproxyFile tunFile perAppTunFile;
        inherit (nftr) nftablesRulesFile perAppTproxyRulesFile perAppZapretRulesFile perAppTunChainFile ip nft;
      })

      (lib.mkIf cfg.zapret.enable (
        import ./zapret.nix {
          inherit
            lib
            pkgs
            cfg
            zapret
            ;
          inherit (nftr) perAppZapretRulesFile nft;
        }
      ))

      (lib.mkIf cfg.tgWsProxy.enable (
        import ./tg-ws-proxy.nix {
          inherit lib pkgs packages cfg;
        }
      ))

      (lib.mkIf cfg.tray.enable (
        import ./tray.nix {
          inherit
            config
            lib
            pkgs
            packages
            cfg
            ;
        }
      ))
    ]
  );
}
