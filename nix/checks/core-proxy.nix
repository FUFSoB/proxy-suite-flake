{
  pkgs,
  evalProxySuite,
  baseModule,
  minimal,
  mkRoutingRules,
  mkTProxyConfig,
  hasRuleSet,
  dnsHasRuleSet,
  dnsServerByTag,
  mkBadFixtureRaw,
  mkFailingAssertions,
}:

let
  fixtures = import ./core-proxy/fixtures.nix {
    inherit
      pkgs
      evalProxySuite
      baseModule
      minimal
      mkRoutingRules
      mkTProxyConfig
      mkBadFixtureRaw
      mkFailingAssertions
      ;
  };
  inherit (fixtures)
    customSingBoxPackageBin
    customSingBoxPackageStartScript
    ruDefaultRules
    ruDefaultConfig
    ruDisabledRules
    ruDisabledConfig
    ruExplicitConfig
    dnsLocalOverrideConfig
    dnsRemoteOverrideConfig
    proxyDirectConfig
    urlTestCustomStartScript
    noProxyBackendDefaultFixture
    invalidCoreProxyAssertions
    blockGeoRules
    routingOrDomainRules
    routingOrGeoIPRules
    ;

  routingDnsChecks = import ./core-proxy/routing-dns.nix {
    inherit
      hasRuleSet
      dnsHasRuleSet
      dnsServerByTag
      ruDefaultRules
      ruDefaultConfig
      ruDisabledRules
      ruDisabledConfig
      ruExplicitConfig
      dnsLocalOverrideConfig
      dnsRemoteOverrideConfig
      blockGeoRules
      routingOrDomainRules
      routingOrGeoIPRules
      ;
  };
  serviceDefaultChecks = import ./core-proxy/service-defaults.nix {
    inherit
      pkgs
      minimal
      customSingBoxPackageBin
      customSingBoxPackageStartScript
      proxyDirectConfig
      ruDefaultConfig
      urlTestCustomStartScript
      noProxyBackendDefaultFixture
      invalidCoreProxyAssertions
      ;
  };
in
{
  inherit ruDefaultConfig;

  assertions = routingDnsChecks.assertions ++ serviceDefaultChecks.assertions;
}
