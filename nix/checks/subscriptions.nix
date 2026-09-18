{
  checkLib,
  pkgs,
  evalProxySuite,
  mkBadFixtureRaw,
  mkFailingAssertions,
  mkProxyCtlDerived,
  minimal,
}:

let
  runtimeChecks = import ./subscriptions-runtime.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      mkProxyCtlDerived
      minimal
      ;
  };
  validationChecks = import ./subscriptions-validation.nix {
    inherit checkLib;
    inherit
      evalProxySuite
      mkBadFixtureRaw
      mkFailingAssertions
      ;
  };
in
{
  assertions = runtimeChecks.assertions ++ validationChecks.assertions;
}
