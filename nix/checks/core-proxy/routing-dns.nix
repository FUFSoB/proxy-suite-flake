{
  hasRuleSet,
  dnsHasRuleSet,
  dnsServerByTag,
  ruDefaultRules,
  ruDefaultConfig,
  ruDisabledRules,
  ruDisabledConfig,
  ruExplicitConfig,
  dnsLocalOverrideConfig,
  dnsRemoteOverrideConfig,
  blockGeoRules,
  routingOrDomainRules,
  routingOrGeoIPRules,
}:

{
  assertions = [
    # -- routing rule entries with domains and geoips preserve both matchers --
    (
      assert builtins.length routingOrDomainRules == 1;
      true
    )
    (
      assert builtins.length routingOrGeoIPRules == 1;
      true
    )
    (
      assert (builtins.head routingOrDomainRules).outbound == "proxy";
      true
    )
    (
      assert (builtins.head routingOrGeoIPRules).outbound == "proxy";
      true
    )

    # -- default RU direct route and DNS rules are generated --
    (
      let
        localDns = dnsServerByTag ruDefaultConfig "local";
        remoteDns = dnsServerByTag ruDefaultConfig "remote";
      in
      assert localDns.type == "udp";
      assert localDns.server == "1.1.1.1";
      assert localDns.server_port == 53;
      assert !(localDns ? detour);
      assert remoteDns.type == "udp";
      assert remoteDns.server == "1.1.1.1";
      assert remoteDns.server_port == 53;
      assert remoteDns.detour == "proxy";
      true
    )
    (
      assert hasRuleSet ruDefaultRules "direct" "geosite-category-ru";
      true
    )
    (
      assert hasRuleSet ruDefaultRules "direct" "geoip-ru";
      true
    )
    (
      assert dnsHasRuleSet ruDefaultConfig.dns.rules "geosite-category-ru";
      true
    )
    (
      assert !(hasRuleSet ruDisabledRules "direct" "geosite-category-ru");
      true
    )
    (
      assert !(hasRuleSet ruDisabledRules "direct" "geoip-ru");
      true
    )
    (
      assert !(dnsHasRuleSet ruDisabledConfig.dns.rules "geosite-category-ru");
      true
    )
    (
      assert dnsHasRuleSet ruExplicitConfig.dns.rules "geosite-category-ru";
      true
    )

    # -- DNS overrides map to sing-box server entries --
    (
      let
        localDns = dnsServerByTag dnsLocalOverrideConfig "local";
      in
      assert localDns.type == "tcp";
      assert localDns.server == "9.9.9.9";
      assert localDns.server_port == 5353;
      assert !(localDns ? detour);
      true
    )
    (
      let
        remoteDns = dnsServerByTag dnsRemoteOverrideConfig "remote";
      in
      assert remoteDns.type == "tls";
      assert remoteDns.server == "1.0.0.1";
      assert remoteDns.server_port == 853;
      assert remoteDns.detour == "proxy";
      true
    )

    # -- block route geosite and geoip sets are emitted --
    (
      assert hasRuleSet blockGeoRules "block" "geosite-category-ads-all";
      true
    )
    (
      assert hasRuleSet blockGeoRules "block" "geoip-cn";
      true
    )
  ];
}
