# z2k-detect, the 16 KB cutoff probe's Go side, at the z2k rev flake.lock holds. It is
# built from its own checkout, not from the module's `z2k` input: a consumer that
# supplies its own z2k (lon, npins, `follows`) would otherwise change go.sum under the
# pinned vendorHash. It talks to the lists and Lua only through the TSV maps.
#
# The rev comes from flake.lock; scripts/update-pins.sh refreshes hash and vendorHash
# after a z2k bump. The rev in the name keeps a store that still holds the previous
# checkout from reusing it under a stale hash.
{ pkgs }:

let
  locked = (pkgs.lib.importJSON ../flake.lock).nodes.z2k.locked;
  shortRev = builtins.substring 0 7 locked.rev;
in
pkgs.buildGoModule (finalAttrs: {
  pname = "z2k-detect";
  version = "0-unstable-${shortRev}";

  src = pkgs.fetchFromGitHub {
    name = "z2k-detect-source-${shortRev}";
    inherit (locked) owner repo rev;
    sparseCheckout = [ "z2k-detect" ];
    hash = "sha256-eEsvNS3sZ12DWcGc/Q+KDbofE32VBXXedDZYWSth0Yk=";
  };
  sourceRoot = "${finalAttrs.src.name}/z2k-detect";
  vendorHash = "sha256-liRRQWyGv8qvL/wFmrWYtthkHFD1g+hpX7FAqtnBabU=";

  subPackages = [ "cmd/z2k-detect" ];
  # Its tests open raw sockets and dial out.
  doCheck = false;

  meta.mainProgram = "z2k-detect";
})
