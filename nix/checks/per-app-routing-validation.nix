{
  checkLib,
  mkBadFixture,
  mkFailingAssertions,
  rejects,
}:

let
  profileChecks = import ./per-app-routing-validation-profiles.nix {
    inherit mkBadFixture mkFailingAssertions;
  };
  resourceChecks = import ./per-app-routing-validation-resources.nix { inherit rejects; };
in
{
  assertions = profileChecks.assertions ++ resourceChecks.assertions;
}
