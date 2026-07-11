{
  pkgs,
  evalProxySuite,
  mkTProxyConfig,
  mkTunConfig,
  mkPerAppTunConfig,
  shellValueByPrefix,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
  dnsServerByTag,
  checkConstants,
}:

let
  runtimeChecks = import ./xray-backend-runtime.nix {
    inherit
      pkgs
      evalProxySuite
      mkTProxyConfig
      mkTunConfig
      mkPerAppTunConfig
      shellValueByPrefix
      checkConstants
      ;
  };
  featureChecks = import ./xray-backend-features.nix {
    inherit
      pkgs
      evalProxySuite
      mkTProxyConfig
      mkBadProxySuiteFixture
      mkFailingAssertions
      dnsServerByTag
      ;
  };
in
{
  runtime = runtimeChecks.runtime;
  assertions = runtimeChecks.assertions ++ featureChecks.assertions;
}
