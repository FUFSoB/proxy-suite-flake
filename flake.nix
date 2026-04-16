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
    in
    {
      # Main module – bakes in the zapret flake so consumers don't need it as a separate input.
      nixosModules.default = proxySuiteModule;

      # Re-export zapret standalone for users who want just that.
      nixosModules.zapret = zapret.nixosModules.default;

      overlays.default = final: prev: {
        inherit (import ./pkgs/default.nix { pkgs = final; })
          tg-ws-proxy
          proxy-suite-tray
          ;
      };

      packages = forAll (
        system:
        let
          pkgs = pkgsFor system;
          suitePkgs = import ./pkgs/default.nix { inherit pkgs; };
        in
        {
          inherit (suitePkgs)
            tg-ws-proxy
            proxy-suite-tray
            ;
          optionsDoc = mkOptionsDoc system;
          update-options-doc = pkgs.writeShellApplication {
            name = "update-options-doc";
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

              output_path="$(nix build --no-link --print-out-paths "''${repo_root}#optionsDoc")"
              target_path="''${repo_root}/docs/options.md"

              install -Dm644 "''${output_path}" "''${target_path}"
              echo "updated ''${target_path}"
            '';
          };
        }
      );

      apps = forAll (system: {
        update-options-doc = {
          type = "app";
          program = "${self.packages.${system}.update-options-doc}/bin/update-options-doc";
          meta.description = "Update docs/options.md from the current NixOS module option declarations";
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
        }
      );
    };
}
