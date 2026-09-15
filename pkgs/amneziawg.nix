# nixpkgs' AmneziaWG 3.1 packages plus this suite's patches.
{ pkgs }:

{
  tools = pkgs.amneziawg-tools.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./patches/amneziawg-tools-force-userspace.patch ];
  });
  userspace = pkgs.amneziawg-go.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./patches/amneziawg-go-random-trailers-transport.patch ];
  });
  kernelModule = kernelPackages: kernelPackages.amneziawg;
}
