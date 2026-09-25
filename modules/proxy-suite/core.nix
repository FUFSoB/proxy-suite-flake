# The host-neutral part of proxy-suite: options, generated configs and scripts, and
# the services to run, declared under services.proxy-suite.internal for a host adapter
# (./hosts) to install.
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
  assembly = import ./assembly.nix {
    inherit
      lib
      pkgs
      cfg
      packages
      zapret
      ;
  };
  inherit (assembly) nftr derived;
in
{
  imports = [
    ./options
  ];

  config = lib.mkMerge [
    {
      services.proxy-suite.internal.helpers =
        let
          inherit (cfg.proxy.listener) address port auth;
          perAppRouting = assembly.context.perAppRouting;
          perAppOn = cfg.enable && cfg.perAppRouting.enable;
        in
        import ./helpers.nix {
          inherit
            lib
            pkgs
            address
            port
            ;
          inherit (auth) username password;
          envUnavailable =
            if !(cfg.enable && cfg.proxy.enable) then
              "the proxy variables need services.proxy-suite.proxy.enable"
            else if auth.passwordFile != null then
              "the proxy variables cannot carry proxy.listener.auth.passwordFile; use wrapProxychains"
            else
              null;
          proxychains =
            if perAppOn && cfg.perAppRouting.proxychains.enable then
              { args = "${perAppRouting.proxychainsQuietArg}-f ${toString perAppRouting.proxychainsConfigFile}"; }
            else
              "wrapProxychains needs perAppRouting.proxychains.enable";
          perApp =
            if perAppOn then
              {
                inherit (assembly.context.control) proxyCtl;
                profiles = perAppRouting.effectivePerAppRoutingProfileNames;
              }
            else
              "wrapPerApp needs perAppRouting.enable";
        };
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
          whitelist-bypass = import ../../pkgs/whitelist-bypass.nix { pkgs = upstream; };
          inherit (upstream) sing-box;
        };
    }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        (import ./service {
          inherit lib pkgs cfg;
          inherit (assembly) context;
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
          (import ./tg-ws-proxy.nix {
            inherit
              lib
              pkgs
              packages
              cfg
              derived
              ;
          }).config
        ))

        # SingBox dials SSH natively, so it needs no OpenSSH unit. XRay has no SSH
        # outbound, and a standalone tunnel has no backend at all, so both keep it.
        (lib.mkIf derived.sshProxyUnitEnabled (
          import ./ssh-proxy.nix {
            inherit
              lib
              pkgs
              cfg
              derived
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

        (lib.mkIf cfg.tor.enable (
          import ./tor.nix {
            inherit
              lib
              pkgs
              cfg
              derived
              ;
          }
        ))

        (lib.mkIf cfg.whitelistBypass.enable (
          import ./whitelist-bypass.nix {
            inherit
              lib
              pkgs
              cfg
              derived
              ;
          }
        ))

        (lib.mkIf derived.ruleSetsEnabled (
          import ./rulesets.nix {
            inherit
              lib
              pkgs
              cfg
              derived
              ;
          }
        ))

        (lib.mkIf (derived.proxyInboundsEnabled && derived.proxyInboundsAwg != [ ]) (
          import ./amnezia-wg-inbounds.nix {
            inherit
              lib
              pkgs
              cfg
              derived
              ;
            inherit (assembly.configs) proxyInboundsSpecFile;
            inherit (nftr) reservedIpBlock ip nft;
          }
        ))

        (lib.mkIf cfg.amneziaWg.enable (
          import ./amnezia-wg.nix {
            inherit
              lib
              pkgs
              cfg
              derived
              ;
          }
        ))
      ]
    ))
  ];
}
