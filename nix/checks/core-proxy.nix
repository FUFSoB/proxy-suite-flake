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
      ;
  };
in
{
  inherit ruDefaultConfig;

  assertions = routingDnsChecks.assertions ++ serviceDefaultChecks.assertions;
}
