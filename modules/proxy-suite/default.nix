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
  derived = import ./derived.nix { inherit lib cfg; };
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
        inherit (configs)
          tproxyFile
          tunFile
          perAppTunFile
          routeModeRulesFile
          proxyInboundsFile
          proxyInboundsSpecFile
          ;
        inherit (nftr)
          nftablesRulesFile
          perAppTproxyRulesFile
          perAppZapretRulesFile
          perAppTunChainFile
          ip
          nft
          ;
      })

      (lib.mkIf (cfg.zapret.enable || cfg.zapret.perApp.enable) (
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
          inherit
            lib
            pkgs
            packages
            cfg
            ;
        }
      ))

      # SingBox dials SSH natively, so it needs no OpenSSH unit. XRay has no SSH
      # outbound, and a standalone tunnel has no backend at all, so both keep it.
      (lib.mkIf derived.sshProxyUnitEnabled (
        import ./ssh-proxy.nix {
          inherit
            lib
            pkgs
            cfg
            ;
        }
      ))

      (lib.mkIf cfg.amneziaWg.enable (
        import ./amnezia-wg.nix {
          inherit
            config
            lib
            pkgs
            cfg
            ;
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
