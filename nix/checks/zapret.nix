{
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
    ;

  zapretHostlistRoutingChecks = import ./zapret-hostlist-routing.nix {
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
  ]
  ++ zapretHostlistRoutingChecks.assertions;
}
