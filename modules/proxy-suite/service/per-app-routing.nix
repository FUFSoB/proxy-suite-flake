# App routing backend infrastructure (TUN, TProxy, zapret).
{
  lib,
  pkgs,
  cfg,
  singBoxCfg,
  proxyCfg,
  pureXrayEnabled,
  perAppRoutingCfg,
  perAppRoutingTun,
  perAppRoutingTproxy,
  constants,
  perAppZapretCfg,
  perAppTunChainFile,
  perAppTproxyRulesFile,
  perAppZapretRulesFile,
  ip,
  nft,
  awk,
  grepBin,
  findBin,
  headBin,
  seqBin,
  sleepBin,
}:

let
  builders = import ./builders.nix { inherit lib pkgs; };
  inherit (builders) mkAnchorService;

  perAppTunSliceName = "proxy-suite-per-app-tun.slice";
  perAppTproxySliceName = "proxy-suite-per-app-tproxy.slice";
  perAppZapretSliceName = "proxy-suite-per-app-zapret.slice";

  profiles = import ./per-app-routing/profiles.nix {
    inherit
      lib
      pkgs
      proxyCfg
      perAppRoutingCfg
      perAppRoutingTun
      perAppRoutingTproxy
      perAppZapretCfg
      ;
  };
  inherit (profiles)
    effectivePerAppRoutingProfiles
    effectivePerAppRoutingProfileNames
    perAppRoutingProfilesFile
    proxychainsConfigFile
    proxychainsQuietArg
    hasProxychainsProfiles
    hasTunProfiles
    hasTproxyProfiles
    hasZapretProfiles
    ;

  backendScripts = import ./per-app-routing/backend-scripts.nix {
    inherit
      lib
      pkgs
      builders
      pureXrayEnabled
      perAppRoutingTun
      perAppRoutingTproxy
      constants
      perAppTunChainFile
      perAppTproxyRulesFile
      ip
      nft
      awk
      seqBin
      sleepBin
      ;
  };
  inherit (backendScripts)
    perAppTunUpScript
    perAppTunDownScript
    perAppTproxyUpScript
    perAppTproxyDownScript
    ;

  userRules = import ./per-app-routing/user-rules.nix {
    inherit
      lib
      pkgs
      perAppRoutingTun
      perAppRoutingTproxy
      perAppZapretCfg
      perAppTunSliceName
      perAppTproxySliceName
      perAppZapretSliceName
      nft
      awk
      grepBin
      findBin
      headBin
      ;
  };
  inherit (userRules)
    perAppTunUserRuleStart
    perAppTunUserRuleStop
    perAppTproxyUserRuleStart
    perAppTproxyUserRuleStop
    perAppZapretUserRuleStart
    perAppZapretUserRuleStop
    ;

in
{
  inherit
    perAppTunSliceName
    perAppTproxySliceName
    perAppZapretSliceName
    perAppTunUpScript
    perAppTunDownScript
    perAppTproxyUpScript
    perAppTproxyDownScript
    perAppTunUserRuleStart
    perAppTunUserRuleStop
    perAppTproxyUserRuleStart
    perAppTproxyUserRuleStop
    perAppZapretUserRuleStart
    perAppZapretUserRuleStop
    mkAnchorService
    effectivePerAppRoutingProfiles
    effectivePerAppRoutingProfileNames
    perAppRoutingProfilesFile
    proxychainsConfigFile
    proxychainsQuietArg
    hasProxychainsProfiles
    hasTunProfiles
    hasTproxyProfiles
    hasZapretProfiles
    ;
}
