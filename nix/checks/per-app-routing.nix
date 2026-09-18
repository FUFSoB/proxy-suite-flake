{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  mkPerAppUserRules,
  mkPerAppZapretNftRules,
  mkPerAppTunConfig,
  dnsServerByTag,
  mkZapretBase,
  mkZapretBaseFor,
  mkBadFixture,
  mkFailingAssertions,
  rejects,
  minimalProxyCtlScript,
}:

let
  tunChecks = import ./per-app-routing-tun.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkProxyCtlDerived
      mkPerAppUserRules
      mkPerAppTunConfig
      dnsServerByTag
      ;
  };
  tproxyChecks = import ./per-app-routing-tproxy.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkProxyCtlDerived
      mkPerAppUserRules
      ;
  };
  zapretChecks = import ./per-app-routing-zapret.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkProxyCtlDerived
      mkPerAppUserRules
      mkPerAppZapretNftRules
      mkZapretBase
      mkZapretBaseFor
      ;
  };
  validationChecks = import ./per-app-routing-validation.nix {
    inherit checkLib;
    inherit mkBadFixture mkFailingAssertions rejects;
  };
  userControlChecks = import ./user-control.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      baseModule
      ;
  };
  proxychainsChecks = import ./per-app-routing-proxychains.nix {
    inherit checkLib;
    inherit
      pkgs
      evalProxySuite
      baseModule
      mkProxyCtlDerived
      minimalProxyCtlScript
      ;
  };
in
{
  assertions =
    tunChecks.assertions
    ++ tproxyChecks.assertions
    ++ zapretChecks.assertions
    ++ proxychainsChecks.assertions
    ++ userControlChecks.assertions
    ++ validationChecks.assertions;

  runtime = zapretChecks.runtime;
}
