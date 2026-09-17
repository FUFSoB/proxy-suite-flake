{
  system,
  nixpkgs,
  proxySuiteModule,
  proxySuiteModules,
  generatedOptionsDoc,
  generatedReadmeDoc,
  zapret,
}:

let
  nixpkgsPkgs = import nixpkgs { inherit system; };
  # lib.hasInfix matches ".*infix.*", which std::regex backtracks through recursively: on
  # the ~100 KB proxy-ctl script that overflows the evaluator's stack. Splitting on the
  # bare infix walks the text flat. Only the checks' own pkgs; the modules keep lib as is.
  pkgs = nixpkgsPkgs // {
    lib = nixpkgsPkgs.lib.extend (
      _: super: {
        hasInfix = infix: content: builtins.length (builtins.split (super.escapeRegex infix) content) > 1;
      }
    );
  };
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
  hostChecks = import ./checks/hosts.nix {
    inherit pkgs proxySuiteModules;
    inherit (checkLib) mkTProxyConfig mkInboundsConfig;
  };
  proxyInboundsRuntime = import ./checks/proxy-inbounds-runtime.nix {
    inherit pkgs proxySuiteModule;
  };
in
moduleSuiteChecks
// {
  proxy-suite-hosts = builtins.seq (builtins.deepSeq hostChecks.assertions true) (
    pkgs.writeText "proxy-suite-hosts-check" "ok"
  );
}
// pkgs.lib.optionalAttrs (system == "x86_64-linux") {
  amneziawg-runtime = amneziaWgRuntime;
  proxy-inbounds-runtime = proxyInboundsRuntime;
}
// parserChecks
// repoChecks
