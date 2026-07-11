{
  mkBadFixture,
  mkFailingAssertions,
}:

let
  profileChecks = import ./per-app-routing-validation-profiles.nix {
    inherit mkBadFixture mkFailingAssertions;
  };
  resourceChecks = import ./per-app-routing-validation-resources.nix {
    inherit mkBadFixture mkFailingAssertions;
  };
in
{
  assertions = profileChecks.assertions ++ resourceChecks.assertions;
}
