{
  description = "NixOS proxy suite — sing-box, zapret, tg-ws-proxy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zapret = {
      url = "github:kartavkun/zapret-discord-youtube";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, zapret }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      proxySuiteModule = import ./modules/proxy-suite { inherit zapret; };
    in
    {
      # Main module — bakes in the zapret flake so consumers don't need it as a separate input.
      nixosModules.default = proxySuiteModule;

      # Re-export zapret standalone for users who want just that.
      nixosModules.zapret = zapret.nixosModules.default;

      overlays.default = final: prev: {
        tg-ws-proxy = import ./pkgs/tg-ws-proxy.nix { pkgs = final; };
      };

      packages = forAll (system: {
        tg-ws-proxy = import ./pkgs/tg-ws-proxy.nix { pkgs = pkgsFor system; };
      });

      checks = forAll (system: import ./nix/checks.nix {
        inherit
          system
          nixpkgs
          proxySuiteModule
          zapret
          ;
      });
    };
}
