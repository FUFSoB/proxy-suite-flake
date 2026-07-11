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
  zapretSyncBase,
  zapretSyncExtraListsBase,
  zapretSyncNoExtraListsBase,
  zapretSpacedConfigAliasBase,
  zapretUnspacedConfigAliasBase,
}:

let
  fixtures = import ./zapret-hostlist-routing/fixtures.nix {
    inherit
      evalProxySuite
      baseModule
      mkRoutingRules
      mkZapretBase
      mkBadFixture
      mkFailingAssertions
      ;
  };
  inherit (fixtures)
    zapretHostlistRules
    zapretHostlistBase
    invalidHostlistAssertions
    ;

  zapretHostlistChecks = import ./zapret-hostlist.nix {
    inherit
      pkgs
      zapretSyncBase
      zapretSyncExtraListsBase
      zapretSyncNoExtraListsBase
      zapretSpacedConfigAliasBase
      zapretUnspacedConfigAliasBase
      zapretHostlistBase
      ;
  };
in
{
  inherit (zapretHostlistChecks) rules;

  assertions = [
    (
      assert hasDirectDomain zapretHostlistRules "googlevideo.com";
      assert hasDirectDomain zapretHostlistRules "example.com";
      assert !(hasDirectDomain zapretHostlistRules "x.example");
      true
    )
    (
      assert hasDirectDomain zapretHostlistRules "youtube.com";
      assert hasDirectDomain zapretHostlistRules "discord.com";
      assert hasDirectDomain zapretHostlistRules "cloudflare-ech.com";
      true
    )
    (
      assert hasDirectIP zapretHostlistRules "203.0.113.0/24";
      assert !(hasDirectIP zapretHostlistRules "1.1.1.0/24");
      true
    )
  ]
  ++ invalidHostlistAssertions;
}
