{
  checkLib,
  pkgs,
  minimal,
  customSingBoxPackageBin,
  customSingBoxPackageStartScript,
  proxyDirectConfig,
  ruDefaultConfig,
  urlTestCustomStartScript,
  noProxyBackendDefaultFixture,
}:

let
  inherit (checkLib) ok;
in
{
  assertions = [
    # -- sing-box package override propagates into generated service scripts --
    (ok (pkgs.lib.hasInfix customSingBoxPackageBin customSingBoxPackageStartScript))

    # -- proxy defaults and urltest settings are applied --
    (ok (proxyDirectConfig.dns.final == "local"))
    (ok (ruDefaultConfig.dns.final == "remote"))
    (ok (ruDefaultConfig.route.default_domain_resolver == "local"))
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
      assert minimal.config.services.proxy-suite.proxy.urlTest.tolerance == 50;
      true
    )

    # -- proxy backend defaults and required inputs are enforced --
    (
      assert noProxyBackendDefaultFixture.config.services.proxy-suite.proxy.enable == false;
      assert !(noProxyBackendDefaultFixture.config.systemd.services ? "proxy-suite-socks");
      true
    )
  ];
}
