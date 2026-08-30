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
  suitePkgs = import ../pkgs/default.nix { inherit pkgs; };
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
    trayModuleSource = builtins.readFile ../modules/proxy-suite/tray.nix;
    tgWsProxyModuleSource = builtins.readFile ../modules/proxy-suite/tg-ws-proxy.nix;
    controlModuleSource = builtins.readFile ../modules/proxy-suite/service/control.nix;
  };
  moduleSuiteChecks = import ./checks/module-suite.nix { inherit pkgs checkLib; };
  amneziaWgRuntime = import ./checks/amnezia-wg-runtime.nix {
    inherit pkgs nixpkgs proxySuiteModule;
  };
in
moduleSuiteChecks
// {
  proxy-suite-tray-build = suitePkgs.proxy-suite-tray;
}
// pkgs.lib.optionalAttrs (system == "x86_64-linux") {
  amneziawg-runtime = amneziaWgRuntime;
}
// parserChecks
// repoChecks
