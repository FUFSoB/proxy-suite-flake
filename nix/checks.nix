{
  system,
  nixpkgs,
  proxySuiteModule,
  generatedOptionsDoc,
  generatedReadmeDoc,
  zapret,
}:

let
  pkgs = import nixpkgs { inherit system; };
  parserChecks = import ./checks/parsers.nix { inherit pkgs; };
  checkLib = import ./checks/lib.nix {
    inherit
      pkgs
      system
      nixpkgs
      proxySuiteModule
      zapret
      ;
  };
  repoChecks = import ./checks/repo.nix {
    inherit
      pkgs
      generatedOptionsDoc
      generatedReadmeDoc
      ;
    inherit (checkLib) rg;
    readmeDocSource = builtins.readFile ../nix/readme-doc.nix;
    tgWsProxyModuleSource = builtins.readFile ../modules/proxy-suite/tg-ws-proxy.nix;
    controlModuleSource = builtins.readFile ../modules/proxy-suite/service/control.nix;
  };
  moduleSuiteChecks = import ./checks/module-suite.nix { inherit pkgs checkLib; };
  amneziaWgRuntime = import ./checks/amnezia-wg-runtime.nix {
    inherit pkgs nixpkgs proxySuiteModule;
  };
  proxyInboundsRuntime = import ./checks/proxy-inbounds-runtime.nix {
    inherit pkgs proxySuiteModule;
  };
in
moduleSuiteChecks
// pkgs.lib.optionalAttrs (system == "x86_64-linux") {
  amneziawg-runtime = amneziaWgRuntime;
  proxy-inbounds-runtime = proxyInboundsRuntime;
}
// parserChecks
// repoChecks
