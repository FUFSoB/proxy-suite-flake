# App routing backend infrastructure (TUN, TProxy, zapret).
{ ctx }:

let
  inherit (ctx)
    builders
    nft
    awk
    grepBin
    findBin
    headBin
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    ;

  slices = {
    perAppTunSliceName = "proxy-suite-per-app-tun.slice";
    perAppTproxySliceName = "proxy-suite-per-app-tproxy.slice";
    perAppZapretSliceName = "proxy-suite-per-app-zapret.slice";
  };

  # user-rules.nix is also imported by the checks, so it keeps an explicit argument list.
  userRules = import ./per-app-routing/user-rules.nix (
    {
      inherit (ctx) lib pkgs;
      inherit
        perAppRoutingTun
        perAppRoutingTproxy
        perAppZapretCfg
        nft
        awk
        grepBin
        findBin
        headBin
        ;
    }
    // slices
  );
in
slices
// import ./per-app-routing/profiles.nix { inherit ctx; }
// import ./per-app-routing/backend-scripts.nix { inherit ctx; }
// userRules
// {
  inherit (builders) mkAnchorService;
}
