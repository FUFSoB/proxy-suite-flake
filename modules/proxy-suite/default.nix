# Factory function – receives the zapret flake and this flake's own nixpkgs,
# returns a NixOS module. This lets consumers add a single flake input and get
# everything transitively.
{
  zapret,
  nixpkgs,
  nfqws2-keenetic,
  z2k,
}:

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

  # Scripts share one store name per block, and journald names a unit's output
  # after its ExecStart basename; tag each unit with its own name instead.
  unitsWithOwnSyslogIdentifier = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config.serviceConfig.SyslogIdentifier = lib.mkIf (lib.hasPrefix "proxy-suite-" name) (
            lib.mkDefault (lib.removeSuffix "@" name)
          );
        }
      )
    );
  };
in
{
  imports = [
    ./options
  ];

  options.systemd.services = unitsWithOwnSyslogIdentifier;
  options.systemd.user.services = unitsWithOwnSyslogIdentifier;

  config = lib.mkMerge [
    {
      # xray and sing-box default to this flake's own nixpkgs (redirect it
      # with inputs.nixpkgs.follows), not the system's: a stable release lags
      # both by months, and current xray needs a newer Go than stable ships.
      _module.args.proxySuiteUpstream =
        let
          upstream = nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
        in
        {
          xray = import ../../pkgs/xray.nix { pkgs = upstream; };
          # AWG 3.1 userspace; its kernel module has to match the system's kernel instead.
          amneziaWg = import ../../pkgs/amneziawg.nix { pkgs = upstream; };
          inherit (upstream) sing-box;
        };
    }

    (lib.mkIf cfg.enable (
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

        (lib.mkIf
          (
            cfg.zapret.engine == "zapret-discord-youtube"
            && (cfg.zapret.enable || cfg.perAppRouting.zapret.enable)
          )
          (
            import ./zapret.nix {
              inherit
                lib
                pkgs
                cfg
                zapret
                ;
              inherit (nftr) perAppZapretRulesFile nft;
            }
          )
        )

        (lib.mkIf (cfg.zapret.engine == "zapret2" && (cfg.zapret.enable || cfg.perAppRouting.zapret.enable))
          (
            import ./zapret2.nix {
              inherit
                lib
                pkgs
                cfg
                packages
                ;
              inherit (nftr) perAppZapretRulesFile nft;
              zapret2Sources = { inherit nfqws2-keenetic z2k; };
            }
          )
        )

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

        (lib.mkIf cfg.warp.enable (
          import ./warp.nix {
            inherit
              lib
              pkgs
              cfg
              derived
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
      ]
    ))
  ];
}
