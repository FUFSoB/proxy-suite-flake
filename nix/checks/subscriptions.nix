{
  pkgs,
  evalProxySuite,
  mkBadFixtureRaw,
  mkFailingAssertions,
  mkProxyCtlDerived,
  minimal,
}:

let
  runtimeChecks = import ./subscriptions-runtime.nix {
    inherit
      pkgs
      evalProxySuite
      mkProxyCtlDerived
      minimal
      ;
  };
  validationChecks = import ./subscriptions-validation.nix {
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
