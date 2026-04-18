{
  description = "NixOS proxy suite – sing-box, zapret, tg-ws-proxy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zapret = {
      url = "github:kartavkun/zapret-discord-youtube";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zapret,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      proxySuiteModule = import ./modules/proxy-suite { inherit zapret; };
      mkOptionsDoc = import ./nix/options-doc.nix {
        inherit nixpkgs pkgsFor proxySuiteModule;
      };
      mkReadmeDoc = import ./nix/readme-doc.nix {
        inherit nixpkgs pkgsFor proxySuiteModule zapret;
      };
    in
    {
      # Main module – bakes in the zapret flake so consumers don't need it as a separate input.
      nixosModules.default = proxySuiteModule;

      # Re-export zapret standalone for users who want just that.
      nixosModules.zapret = zapret.nixosModules.default;

      overlays.default = final: prev: {
        inherit (import ./pkgs/default.nix { pkgs = final; })
          mkProxyCtl
          mkProxySuiteTray
          mkTgWsProxy
          tg-ws-proxy
          proxy-suite-tray
          ;
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

              install -Dm644 "''${options_output_path}" "''${repo_root}/docs/options.md"
              install -Dm644 "''${readme_output_path}" "''${repo_root}/README.md"

              echo "updated ''${repo_root}/docs/options.md"
              echo "updated ''${repo_root}/README.md"
            '';
          };
        in
        {
          inherit (suitePkgs)
            tg-ws-proxy
            proxy-suite-tray
            ;
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
