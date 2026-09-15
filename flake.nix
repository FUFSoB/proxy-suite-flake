{
  description = "NixOS proxy suite - SingBox, XRay, AmneziaWG 3.1, zapret, tg-ws-proxy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zapret = {
      url = "github:kartavkun/zapret-discord-youtube";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nfqws2-keenetic = {
      url = "github:nfqws/nfqws2-keenetic";
      flake = false;
    };
    z2k = {
      url = "github:necronicle/z2k/z2k-enhanced";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zapret,
      nfqws2-keenetic,
      z2k,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      proxySuiteModule = import ./modules/proxy-suite {
        inherit
          zapret
          nixpkgs
          nfqws2-keenetic
          z2k
          ;
      };
      mkOptionsDoc = import ./nix/options-doc.nix {
        inherit nixpkgs pkgsFor proxySuiteModule;
      };
      mkReadmeDoc = import ./nix/readme-doc.nix {
        inherit
          nixpkgs
          pkgsFor
          proxySuiteModule
          zapret
          ;
      };
    in
    {
      # Main module – bakes in the zapret flake so consumers don't need it as a separate input.
      nixosModules.default = proxySuiteModule;

      # Re-export zapret standalone for users who want just that.
      nixosModules.zapret = zapret.nixosModules.default;

      overlays.default = final: prev: {
        # From prev: these override the nixpkgs packages of the same name.
        inherit (import ./pkgs/default.nix { pkgs = prev; })
          amneziawg-tools
          amneziawg-go
          ;
        inherit (import ./pkgs/default.nix { pkgs = final; })
          mkProxyCtl
          mkTgWsProxy
          tg-ws-proxy
          zapret2
          ;
        # Replaced by Proxy Suite GUI, which mkProxyCtl builds as `.gui`.
        proxy-suite-tray = throw "proxy-suite-tray was replaced by Proxy Suite GUI: set services.proxy-suite.gui.enable";
        mkProxySuiteTray = throw "mkProxySuiteTray was replaced by Proxy Suite GUI: set services.proxy-suite.gui.enable";
      };

      packages = forAll (
        system:
        let
          pkgs = pkgsFor system;
          suitePkgs = import ./pkgs/default.nix { inherit pkgs; };
          updateDocs = pkgs.writeShellApplication {
            name = "update-docs";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.git
              pkgs.nix
            ];
            text = ''
              set -euo pipefail

              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

              if [[ -z "''${repo_root}" || ! -f "''${repo_root}/flake.nix" ]]; then
                echo "run this helper from inside the proxy-suite-flake repository" >&2
                exit 1
              fi

              options_output_path="$(nix build --no-link --print-out-paths "''${repo_root}#optionsDoc")"
              readme_output_path="$(nix build --no-link --print-out-paths "''${repo_root}#readmeDoc")"

              mkdir -p "''${repo_root}/docs"
              rm -rf "''${repo_root}/docs/options"
              cp -r --no-preserve=mode,ownership "''${options_output_path}" "''${repo_root}/docs/options"
              install -Dm644 "''${readme_output_path}" "''${repo_root}/README.md"

              echo "updated ''${repo_root}/docs/options/"
              echo "updated ''${repo_root}/README.md"
            '';
          };
        in
        {
          inherit (suitePkgs)
            amneziawg-tools
            amneziawg-go
            tg-ws-proxy
            zapret2
            ;
          xray = import ./pkgs/xray.nix { inherit pkgs; };
          optionsDoc = mkOptionsDoc system;
          readmeDoc = mkReadmeDoc system;
          update-docs = updateDocs;
          update-options-doc = pkgs.writeShellApplication {
            name = "update-options-doc";
            runtimeInputs = [ updateDocs ];
            text = ''
              exec ${updateDocs}/bin/update-docs "$@"
            '';
          };
        }
      );

      apps = forAll (system: {
        update-docs = {
          type = "app";
          program = "${self.packages.${system}.update-docs}/bin/update-docs";
          meta.description = "Update generated docs and README help from current NixOS module outputs";
        };
        update-options-doc = {
          type = "app";
          program = "${self.packages.${system}.update-options-doc}/bin/update-options-doc";
          meta.description = "Compatibility alias for update-docs";
        };
      });

      checks = forAll (
        system:
        import ./nix/checks.nix {
          inherit
            system
            nixpkgs
            proxySuiteModule
            zapret
            ;
          generatedOptionsDoc = mkOptionsDoc system;
          generatedReadmeDoc = mkReadmeDoc system;
        }
      );
    };
}
