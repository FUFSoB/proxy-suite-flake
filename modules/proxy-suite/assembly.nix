# Routing rules → generated configs → nftables rule files → service context: the wiring the
# host-neutral module does at evaluation time, in one place so the docs generator and the
# checks assemble it exactly as the running system does.
{
  lib,
  pkgs,
  cfg,
  packages,
  zapret,
}:
let
  rules = import ./rules.nix {
    inherit
      lib
      pkgs
      cfg
      zapret
      ;
  };
  configs = import ./config.nix {
    inherit
      lib
      pkgs
      cfg
      rules
      ;
  };
  nftr = import ./nftables.nix { inherit lib pkgs cfg; };
  context = import ./service/context.nix {
    inherit
      lib
      pkgs
      packages
      cfg
      ;
    inherit (configs)
      tproxyFile
      tunFile
      perAppTunFile
      routeModeRulesFile
      proxyInboundsFile
      proxyInboundsSpecFile
      ;
    inherit (nftr)
      perAppTunChainFile
      perAppTproxyRulesFile
      perAppZapretRulesFile
      nftablesRulesFile
      killSwitchRulesFile
      ip
      nft
      ;
  };
in
{
  inherit
    rules
    configs
    nftr
    context
    ;
  inherit (context) derived;
}
