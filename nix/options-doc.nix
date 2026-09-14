{
  nixpkgs,
  pkgsFor,
  proxySuiteModule,
}:

system:

let
  pkgs = pkgsFor system;
  lib = pkgs.lib;
  eval = import "${nixpkgs}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      proxySuiteModule
      { system.stateVersion = lib.trivial.release; }
    ];
  };

  # Visible options only (renamed aliases are hidden, and so are groups left
  # with nothing but aliases), packages shown by name.
  visibleConfig =
    opts: cfg:
    lib.filterAttrs (name: value: lib.isOption opts.${name} || value != { }) (
      lib.mapAttrs (
        name: opt:
        if !lib.isOption opt then
          visibleConfig opt cfg.${name}
        else if lib.isDerivation cfg.${name} then
          {
            __pretty = _: "pkgs.${lib.getName cfg.${name}}";
            val = null;
          }
        else
          cfg.${name}
      ) (lib.filterAttrs (name: opt: name != "_module" && (opt.visible or true) != false) opts)
    );

  optionDocs = pkgs.nixosOptionsDoc {
    options.services.proxy-suite = eval.options.services.proxy-suite;
    documentType = "none";
    variablelistId = "proxy-suite-options";
    optionIdPrefix = "proxy-suite-opt-";
    transformOptions = opt: opt // { declarations = [ ]; };
  };
in
import ./options-doc/render-options-markdown.nix {
  inherit pkgs optionDocs;
  defaultConfigText = lib.generators.toPretty { allowPrettyValues = true; } (
    visibleConfig eval.options.services.proxy-suite eval.config.services.proxy-suite
  );
}
