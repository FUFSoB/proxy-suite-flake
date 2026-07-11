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
      {
        system.stateVersion = lib.trivial.release;
      }
    ];
  };
  filterGeneratedOptions = lib.filterAttrs (name: _: name != "_module");
  singBoxPackagePlaceholder = "__proxy_suite_doc_pkg_sing_box__";
  xrayPackagePlaceholder = "__proxy_suite_doc_pkg_xray__";
  sanitizeConfigForDocs =
    config:
    builtins.removeAttrs config [ "singBox" ]
    // {
      proxy = (config.proxy or { }) // {
        singBox =
          ((config.proxy or { }).singBox or { })
          // lib.optionalAttrs (((config.proxy or { }).singBox or { }) ? package) {
            package = singBoxPackagePlaceholder;
          };
        xray =
          ((config.proxy or { }).xray or { })
          // lib.optionalAttrs (((config.proxy or { }).xray or { }) ? package) {
            package = xrayPackagePlaceholder;
          };
      };
    };
  renderConfigText =
    config:
    lib.replaceStrings
      [
        "\"${singBoxPackagePlaceholder}\""
        "\"${xrayPackagePlaceholder}\""
      ]
      [
        "pkgs.sing-box"
        "pkgs.xray"
      ]
      (lib.generators.toPretty { } (sanitizeConfigForDocs config));
  mkGeneratedExampleValue =
    option:
    if (option ? _type) && option._type == "option" then
      if option ? example then
        option.example
      else if (option ? type) && ((option.type.name or null) == "submodule") then
        lib.mapAttrs (_: mkGeneratedExampleValue) (filterGeneratedOptions (option.type.getSubOptions [ ]))
      else if option ? default then
        option.default
      else
        throw "Cannot generate example value for option ${lib.showOption option.loc}"
    else
      lib.mapAttrs (_: mkGeneratedExampleValue) (filterGeneratedOptions option);
  defaultConfigText = renderConfigText eval.config.services.proxy-suite;
  generatedExampleConfig = lib.mapAttrs (_: mkGeneratedExampleValue) (
    filterGeneratedOptions eval.options.services.proxy-suite
  );
  exampleConfigText = renderConfigText (builtins.removeAttrs generatedExampleConfig [ "singBox" ]);
  repoRoot = toString ../.;
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
import ./options-doc/render-options-markdown.nix {
  inherit
    pkgs
    optionDocs
    defaultConfigText
    exampleConfigText
    ;
}
