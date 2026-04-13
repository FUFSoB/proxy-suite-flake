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
      mkOptionsDoc =
        system:
        let
          pkgs = pkgsFor system;
          lib = pkgs.lib;
          eval = import "${nixpkgs}/nixos/lib/eval-config.nix" {
            inherit system;
            modules = [
              proxySuiteModule
              {
                system.stateVersion = lib.trivial.release;
              }
            ];
          };
          defaultConfigText = lib.generators.toPretty { } eval.config.services.proxy-suite;
          repoRoot = toString ./.;
          repoUrl = "https://github.com/FUFSoB/proxy-suite-flake/blob/main";
          transformDeclaration =
            decl:
            let
              declStr = toString decl;
              subpath = lib.removePrefix "/" (lib.removePrefix repoRoot declStr);
            in
            if lib.hasPrefix repoRoot declStr then
              {
                url = "${repoUrl}/${subpath}";
                name = subpath;
              }
            else
              decl;
          optionDocs = pkgs.nixosOptionsDoc {
            options = {
              services = {
                "proxy-suite" = eval.options.services.proxy-suite;
              };
            };
            documentType = "none";
            variablelistId = "proxy-suite-options";
            optionIdPrefix = "proxy-suite-opt-";
            transformOptions = opt: opt // { declarations = map transformDeclaration opt.declarations; };
          };
        in
        pkgs.runCommand "proxy-suite-options.md" { } ''
          cat >"$out" <<'EOF'
# proxy-suite options

This file is generated from the `services.proxy-suite` option descriptions in [`modules/proxy-suite/options.nix`](modules/proxy-suite/options.nix).
Update module option docs there instead of editing this file by hand.

## Complete default config

```nix
services.proxy-suite = ${defaultConfigText};
```

EOF

          cat ${optionDocs.optionsCommonMark} >>"$out"
        '';
    in
    {
      # Main module – bakes in the zapret flake so consumers don't need it as a separate input.
      nixosModules.default = proxySuiteModule;

      # Re-export zapret standalone for users who want just that.
      nixosModules.zapret = zapret.nixosModules.default;

      overlays.default = final: prev: {
        tg-ws-proxy = import ./pkgs/tg-ws-proxy.nix { pkgs = final; };
        proxy-suite-tray = import ./pkgs/proxy-suite-tray.nix { pkgs = final; };
      };

      packages = forAll (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          tg-ws-proxy = import ./pkgs/tg-ws-proxy.nix { inherit pkgs; };
          proxy-suite-tray = import ./pkgs/proxy-suite-tray.nix { inherit pkgs; };
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
