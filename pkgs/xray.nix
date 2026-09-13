# Xray-core ahead of nixpkgs, which still ships 26.3.27. From 26.9.8 its go.mod
# asks for Go 1.27, so the builder is swapped along with the source. Steps
# aside once nixpkgs has caught up.
{ pkgs }:

let
  inherit (pkgs) lib;
  version = "26.9.9";
in
if lib.versionAtLeast pkgs.xray.version version then
  pkgs.xray
else
  (pkgs.xray.override (
    args: lib.optionalAttrs (args ? buildGo126Module) { buildGo126Module = pkgs.buildGo127Module; }
  )).overrideAttrs
    (
      finalAttrs: _: {
        inherit version;
        src = pkgs.fetchFromGitHub {
          owner = "XTLS";
          repo = "Xray-core";
          rev = "v${finalAttrs.version}";
          hash = "sha256-GqPEAgWM9Wx19uxMj0LGeOyHreLbU0IMSmalwLe/SIc=";
        };
        vendorHash = "sha256-6Qa05hFdvfLlH8WQd426IU7MScmeevIgrgP5037pNek=";
      }
    )
