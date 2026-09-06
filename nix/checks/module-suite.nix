{
  pkgs,
  checkLib,
}:

let
  inherit (checkLib)
    evalProxySuite
    mkRoutingRules
    mkRouteModeRules
    mkTProxyConfig
    mkTunConfig
    mkPerAppTunConfig
    mkTProxyNftRules
    mkPerAppZapretNftRules
    mkPerAppUserRules
    hasDirectDomain
    hasDirectIP
    hasRuleSet
    dnsHasRuleSet
    dnsServerByTag
    mkZapretBaseFor
    mkZapretBase
    packagePathMatches
    packageByPattern
    shellValueByPrefix
    baseModule
    mkBadFixture
    mkBadFixtureRaw
    mkBadProxySuiteFixture
    mkFailingAssertions
    mkProxyCtlDerived
    ;

  minimal = evalProxySuite [ baseModule ];
  checkConstants =
    (import ../../modules/proxy-suite/derived.nix {
      lib = pkgs.lib;
      cfg = minimal.config.services.proxy-suite;
    }).constants;
  _minimalProxyCtl = mkProxyCtlDerived minimal;
  minimalProxyCtlWrapper = _minimalProxyCtl.wrapper;
  minimalProxyCtlScript = _minimalProxyCtl.script;
  minimalSocksService = minimal.config.systemd.services."proxy-suite-socks";

  coreProxyChecks = import ./core-proxy.nix {
    inherit
      pkgs
      evalProxySuite
      baseModule
      minimal
      mkRoutingRules
      mkTProxyConfig
      hasRuleSet
      dnsHasRuleSet
      dnsServerByTag
      mkBadFixtureRaw
      mkFailingAssertions
      ;
  };
  inherit (coreProxyChecks) ruDefaultConfig;

  routeModeChecks = import ./route-mode.nix {
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkRouteModeRules
      shellValueByPrefix
      minimalProxyCtlWrapper
      minimalProxyCtlScript
      ;
  };

  subscriptionChecks = import ./subscriptions.nix {
    inherit
      pkgs
      evalProxySuite
      mkBadFixtureRaw
      mkFailingAssertions
      mkProxyCtlDerived
      minimal
      ;
  };

  trayChecks = import ./tray.nix {
    inherit
      evalProxySuite
      baseModule
      packagePathMatches
      ;
  };

  localProxyAuthChecks = import ./local-proxy-auth.nix {
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkProxyCtlDerived
      shellValueByPrefix
      mkBadFixture
      mkFailingAssertions
      ruDefaultConfig
      ;
  };

  perAppRoutingChecks = import ./per-app-routing.nix {
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkProxyCtlDerived
      mkPerAppUserRules
      mkPerAppZapretNftRules
      mkPerAppTunConfig
      dnsServerByTag
      mkZapretBase
      mkZapretBaseFor
      mkBadFixture
      mkFailingAssertions
      minimalProxyCtlScript
      ;
  };

  outboundValidationChecks = import ./outbound-validation.nix {
    inherit mkBadProxySuiteFixture mkFailingAssertions;
  };

  amneziaWgChecks = import ./amnezia-wg.nix {
    inherit
      pkgs
      evalProxySuite
      mkBadProxySuiteFixture
      mkFailingAssertions
      mkProxyCtlDerived
      ;
  };

  globalProxyModeChecks = import ./global-proxy-modes.nix {
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkBadFixture
      mkFailingAssertions
      mkTunConfig
      dnsServerByTag
      checkConstants
      ;
  };

  zapretChecks = import ./zapret.nix {
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkRoutingRules
      mkZapretBase
      mkBadFixture
      mkFailingAssertions
      hasDirectDomain
      hasDirectIP
      ;
  };

  tgWsProxyChecks = import ./tg-ws-proxy.nix {
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkRoutingRules
      mkTProxyNftRules
      mkBadFixture
      mkFailingAssertions
      hasDirectIP
      minimal
      minimalSocksService
      ;
    zapretSyncService = zapretChecks.syncService;
  };

  xrayBackendChecks = import ./xray-backends.nix {
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

  validated = builtins.all (x: x) (
    [
      (
        assert minimal.config.services.proxy-suite.proxy.listenAddress == "127.0.0.1";
        true
      )
    ]
    ++ coreProxyChecks.assertions
    ++ localProxyAuthChecks.assertions
    ++ tgWsProxyChecks.assertions
    ++ xrayBackendChecks.assertions
    ++ outboundValidationChecks.assertions
    ++ amneziaWgChecks.assertions
    ++ zapretChecks.assertions
    ++ globalProxyModeChecks.assertions
    ++ trayChecks.assertions
    ++ subscriptionChecks.assertions
    ++ routeModeChecks.assertions
    ++ perAppRoutingChecks.assertions
  );
in
{
  proxy-suite-module = builtins.seq validated (pkgs.writeText "proxy-suite-module-check" "ok");
  amneziawg-secret-manifest = amneziaWgChecks.manifest;
  xray-jq-filter-runtime = xrayBackendChecks.runtime;
  per-app-zapret-runtime = perAppRoutingChecks.runtime;
  zapret-hostlist-rules = zapretChecks.rules;
}
