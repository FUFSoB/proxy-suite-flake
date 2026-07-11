{
  pkgs,
  evalProxySuite,
  baseModule,
  minimal,
  mkRoutingRules,
  mkTProxyConfig,
  mkBadFixtureRaw,
  mkFailingAssertions,
}:

let
  generated = import ../read-generated.nix;

  customSingBoxPackage = pkgs.writeShellScriptBin "sing-box" ''
    exit 0
  '';
  customSingBoxPackageFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.singBox.package = customSingBoxPackage;
    }
  ];
  customSingBoxPackageBin = "${builtins.unsafeDiscardStringContext (toString customSingBoxPackage)}/bin/sing-box";
  customSingBoxPackageStartScript = generated.readDerivation (
    customSingBoxPackageFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  routingOrFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
          routing.rules = [
            {
              outbound = "primary";
              domains = [ "example.com" ];
              geoips = [ "us" ];
            }
          ];
        };
      };
    }
  ];

  ruDefaultRules = mkRoutingRules minimal;
  ruDefaultConfig = mkTProxyConfig minimal;

  ruDisabledFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.routing.enableRuDirect = false;
    }
  ];
  ruDisabledRules = mkRoutingRules ruDisabledFixture;
  ruDisabledConfig = mkTProxyConfig ruDisabledFixture;

  ruExplicitConfig = mkTProxyConfig (evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.routing = {
        enableRuDirect = false;
        direct.geosites = [ "category-ru" ];
      };
    }
  ]);

  dnsLocalOverrideConfig = mkTProxyConfig (evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.dns.local = {
        type = "tcp";
        address = "9.9.9.9";
        port = 5353;
      };
    }
  ]);

  dnsRemoteOverrideConfig = mkTProxyConfig (evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.dns.remote = {
        type = "tls";
        address = "1.0.0.1";
        port = 853;
      };
    }
  ]);

  proxyDirectConfig = mkTProxyConfig (evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.proxyByDefault = false;
    }
  ]);

  urlTestCustomFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
          outbounds = [
            {
              tag = "test-proxy";
              url = "http://proxy.example.com:8080";
            }
          ];
          selection = "urltest";
          urlTest = {
            url = "https://telegram.org";
            interval = "1m";
          };
          singBox.urlTest.tolerance = 100;
        };
      };
    }
  ];
  urlTestCustomStartScript = generated.readDerivation (
    urlTestCustomFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  noProxyBackendDefaultFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite.enable = true;
    }
  ];

  invalidCoreProxyAssertions = mkFailingAssertions mkBadFixtureRaw [
    [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          proxy = {
            enable = true;
            singBox.enable = true;
          };
        };
      }
    ]
  ];

  blockGeoRules = mkRoutingRules (evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.routing.block = {
        geosites = [ "category-ads-all" ];
        geoips = [ "cn" ];
      };
    }
  ]);

  routingOrRules = mkRoutingRules routingOrFixture;

  routingOrDomainRules = builtins.filter (
    rule: (rule ? domain_suffix) && rule.domain_suffix == [ "example.com" ]
  ) routingOrRules;

  routingOrGeoIPRules = builtins.filter (
    rule: (rule ? rule_set) && rule.rule_set == [ "geoip-us" ]
  ) routingOrRules;
in
{
  inherit
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
    urlTestCustomFixture
    urlTestCustomStartScript
    noProxyBackendDefaultFixture
    invalidCoreProxyAssertions
    blockGeoRules
    routingOrDomainRules
    routingOrGeoIPRules
    ;
}
