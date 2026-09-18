{
  checkLib,
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
  xrayChecks = import ./xray-backend.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      mkTProxyConfig
      mkTunConfig
      mkPerAppTunConfig
      shellValueByPrefix
      mkBadProxySuiteFixture
      mkFailingAssertions
      dnsServerByTag
      checkConstants
      ;
  };
  hybridChecks = import ./hybrid-backend.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      mkTProxyConfig
      mkTunConfig
      shellValueByPrefix
      checkConstants
      ;
  };
in
{
  runtime = xrayChecks.runtime;
  assertions = hybridChecks.assertions ++ xrayChecks.assertions;
}
