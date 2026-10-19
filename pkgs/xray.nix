# Xray-core ahead of nixpkgs, which still ships 26.3.27. From 26.9.8 its go.mod
# asks for Go 1.27, so the builder is swapped along with the source. Steps
# aside once nixpkgs has caught up; the patch stays.
#
# The patch marks an outbound's sockets by the level of the inbound user they dial for
# (inbounds.manager's speed limits); passthru.userLevelMark says it is in.
{ pkgs }:

let
  inherit (pkgs) lib;
  version = "26.10.17";
  base =
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
              hash = "sha256-MUeF3LwZ8bN7gEQCDdzgZKg+agYIokxfQ81VWIkXUgY=";
            };
            vendorHash = "sha256-8Cfbzi3kF3kRtARD2dYaWU4KrcFg65tkjSPO3cWrtps=";
          }
        );
in
base.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./patches/xray-user-level-mark.patch ];
  passthru = (old.passthru or { }) // {
    userLevelMark = true;
  };
})
