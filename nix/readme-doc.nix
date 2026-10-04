{
  nixpkgs,
  pkgsFor,
  proxySuiteModule,
  zapret,
}:

system:

let
  fillTemplate = import ../modules/proxy-suite/lib/fill-template.nix;
  pkgs = pkgsFor system;
  packages = import ../pkgs/default.nix { inherit pkgs; };
  fixture = import ./readme-doc-fixture.nix;
  eval = import "${nixpkgs}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      proxySuiteModule
      fixture
    ];
  };
  cfg = eval.config.services.proxy-suite;
  inherit
    (import ../modules/proxy-suite/assembly.nix {
      lib = pkgs.lib;
      inherit
        pkgs
        packages
        cfg
        zapret
        ;
    })
    context
    ;
in
pkgs.runCommand "proxy-suite-README.md" { nativeBuildInputs = [ pkgs.python3 ]; } (
  fillTemplate ./readme-doc.template.sh {
    readme = ../README.md;
    proxyCtl = context.control.proxyCtl;
  }
)
