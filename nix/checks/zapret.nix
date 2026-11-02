{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
  mkRoutingRules,
  mkZapretBase,
  mkBadFixture,
  mkFailingAssertions,
  hasDirectDomain,
  hasDirectIP,
}:

let
  fixtures = import ./zapret/fixtures.nix {
    inherit
      evalProxySuite
      baseModule
      mkRoutingRules
      mkZapretBase
      ;
  };
  inherit (fixtures)
    zapretSyncService
    zapretSyncRules
    zapretSyncBase
    zapretSpacedConfigAliasBase
    zapretUnspacedConfigAliasBase
    zapretSyncNoExtraListsBase
    zapretSyncNoExtraListsRules
    zapretSyncExtraListsBase
    zapretSyncExtraListsRules
    zapretSyncIpsRules
    zapretSyncUserIpsDisabledRules
    zapretSyncDisabledRules
    zapretSyncDomainsOnlyRules
    zapretExtrasRules
    zapretIpExtrasRules
    zapretExcludesRules
    zapretIpExcludesRules
    zapretVmExemptServices
    ;

  zapretHostlistRoutingChecks = import ./zapret-hostlist-routing.nix {
    inherit checkLib;
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
      zapretSyncBase
      zapretSyncExtraListsBase
      zapretSyncNoExtraListsBase
      zapretSpacedConfigAliasBase
      zapretUnspacedConfigAliasBase
      ;
  };
in
{
  inherit (zapretHostlistRoutingChecks) rules;
  syncService = zapretSyncService;

  assertions = [
    (
      assert hasDirectDomain zapretSyncRules "discord.com";
      assert hasDirectDomain zapretSyncRules "youtube.com";
      assert hasDirectDomain zapretSyncRules "cloudflare-ech.com";
      assert !(hasDirectDomain zapretSyncRules "twitter.com");
      assert !(hasDirectIP zapretSyncRules "1.1.1.0/24");
      true
    )
    (
      assert hasDirectDomain zapretSyncDomainsOnlyRules "cloudflare-ech.com";
      assert !(hasDirectIP zapretSyncDomainsOnlyRules "1.1.1.0/24");
      true
    )
    (
      assert hasDirectIP zapretSyncIpsRules "1.1.1.0/24";
      assert !(hasDirectIP zapretSyncUserIpsDisabledRules "203.0.113.0/24");
      true
    )
    (
      assert !(hasDirectDomain zapretSyncNoExtraListsRules "twitter.com");
      assert hasDirectDomain zapretSyncExtraListsRules "twitter.com";
      true
    )
    (
      assert !(hasDirectDomain zapretSyncDisabledRules "discord.com");
      assert !(hasDirectIP zapretSyncDisabledRules "1.1.1.0/24");
      true
    )
    (
      assert hasDirectDomain zapretExtrasRules "pixiv.net";
      assert hasDirectIP zapretIpExtrasRules "203.0.113.0/24";
      true
    )
    (
      assert !(hasDirectDomain zapretExcludesRules "discord.com");
      assert !(hasDirectIP zapretIpExcludesRules "1.1.1.0/24");
      true
    )
    # A firewall reload (a switch's) that flushed the ruleset took zapret's rules with it
    # (iptables-nft's tables): its reload follows the firewall's and adds back what is missing,
    # leaving the daemons be. The CIDR exemption goes back after it, above its rules.
    (
      let
        zapretUnit = zapretVmExemptServices.proxy-suite-zapret;
        exempt = zapretVmExemptServices.proxy-suite-zapret-vm-exempt;
      in
      assert pkgs.lib.hasSuffix "/init.d/sysv/zapret start_fw" zapretUnit.serviceConfig.ExecReload;
      assert builtins.elem "nftables.service" zapretUnit.after;
      assert zapretUnit.unitConfig.ReloadPropagatedFrom == [ "nftables.service" ];
      assert exempt.serviceConfig.ExecReload == exempt.serviceConfig.ExecStart;
      assert builtins.elem "proxy-suite-zapret.service" exempt.after;
      assert builtins.elem "proxy-suite-zapret.service" exempt.unitConfig.ReloadPropagatedFrom;
      assert builtins.elem "nftables.service" exempt.unitConfig.ReloadPropagatedFrom;
      true
    )
  ]
  ++ zapretHostlistRoutingChecks.assertions;
}
