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
  nftr = import ./nftables.nix { inherit lib pkgs cfg; };
in
{
  imports = [
    ./options.nix
  ];

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cfg.singBox.enable (
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
        import ./service {
          inherit
            config
            lib
            pkgs
            cfg
            ;
          inherit (configs) tproxyFile tunFile appTunFile;
          inherit (nftr) nftablesRulesFile appTproxyRulesFile appZapretRulesFile appTunChainFile ip nft;
        }
      ))

      (lib.mkIf cfg.zapret.enable (
        import ./zapret.nix {
          inherit
            lib
            pkgs
            cfg
            zapret
            ;
          inherit (nftr) appZapretRulesFile nft;
        }
      ))

      (lib.mkIf cfg.tgWsProxy.enable (import ./tg-ws-proxy.nix { inherit lib pkgs cfg; }))

      (lib.mkIf cfg.tray.enable (
        import ./tray.nix {
          inherit
            config
            lib
            pkgs
            cfg
            ;
        }
      ))
    ]
  );
}
