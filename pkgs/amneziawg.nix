{ pkgs }:

let
  # Tools and the kernel module currently publish 3.1.20260812, while the
  # userspace implementation has follow-up 3.1 fixes through 20260828.
  # nixpkgs itself still tracks AWG 3.0.
  version = "3.1.20260812";
  userspaceVersion = "3.1.20260828";
  tools = pkgs.amneziawg-tools.overrideAttrs (old: {
    inherit version;
    src = pkgs.fetchFromGitHub {
      owner = "amnezia-vpn";
      repo = "amneziawg-tools";
      tag = "v${version}";
      hash = "sha256-6GEb41ERhR0Hg3RbSyIHdXPSKaxugoFCmFS5S0UiZso=";
    };
    patches = (old.patches or [ ]) ++ [ ./patches/amneziawg-tools-force-userspace.patch ];
  });
  userspace = pkgs.amneziawg-go.overrideAttrs (_: {
    version = userspaceVersion;
    src = pkgs.fetchFromGitHub {
      owner = "amnezia-vpn";
      repo = "amneziawg-go";
      tag = "v${userspaceVersion}";
      hash = "sha256-vZb72SA+6v8FXZX247K05yiVEBWpLqAAIyw6bEE4eUQ=";
    };
    patches = [ ./patches/amneziawg-go-random-trailers-transport.patch ];
    # The 3.1 releases keep the dependency set used by nixpkgs' 3.0 package.
    vendorHash = "sha256-Y2dCwlKMVLrkzDcNKyCPxFJwMbCA2mQKkakvzwbamCY=";
  });

  kernelModule = kernelPackages: kernelPackages.amneziawg.overrideAttrs (_: {
    inherit version;
    src = pkgs.fetchFromGitHub {
      owner = "amnezia-vpn";
      repo = "amneziawg-linux-kernel-module";
      tag = "v${version}";
      hash = "sha256-dJ7Au4J8iPlphSzTa3Gol/LMlroroSc2IUmXZfjA0k8=";
    };
  });
in
{
  inherit
    version
    userspaceVersion
    tools
    userspace
    kernelModule
    ;
}
