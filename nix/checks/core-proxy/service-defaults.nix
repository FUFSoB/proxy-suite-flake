{
  pkgs,
  minimal,
  customSingBoxPackageBin,
  customSingBoxPackageStartScript,
  proxyDirectConfig,
  ruDefaultConfig,
  urlTestCustomStartScript,
  noProxyBackendDefaultFixture,
  invalidCoreProxyAssertions,
}:

{
  assertions = [
    # -- sing-box package override propagates into generated service scripts --
    (
      assert pkgs.lib.hasInfix customSingBoxPackageBin customSingBoxPackageStartScript;
      true
    )

    # -- proxy defaults and urltest settings are applied --
    (
      assert proxyDirectConfig.dns.final == "local";
      true
    )
    (
      assert ruDefaultConfig.dns.final == "remote";
      true
    )
    (
      assert ruDefaultConfig.route.default_domain_resolver == "local";
      true
    )
    (
      assert builtins.match ".*telegram\\.org.*" urlTestCustomStartScript != null;
      assert builtins.match ".*1m.*" urlTestCustomStartScript != null;
      assert builtins.match ".*100.*" urlTestCustomStartScript != null;
      true
    )
    (
      let
        cfg = minimal.config.services.proxy-suite.proxy.urlTest;
      in
      assert cfg.url == "https://www.gstatic.com/generate_204";
      assert cfg.interval == "3m";
      assert minimal.config.services.proxy-suite.proxy.singBox.urlTest.tolerance == 50;
      true
    )

    # -- proxy backend defaults and required inputs are enforced --
    (
      assert noProxyBackendDefaultFixture.config.services.proxy-suite.proxy.enable == false;
      assert !(noProxyBackendDefaultFixture.config.systemd.services ? "proxy-suite-socks");
      true
    )
  ]
  ++ invalidCoreProxyAssertions;
}
