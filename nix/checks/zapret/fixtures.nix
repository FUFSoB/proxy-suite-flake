{
  evalProxySuite,
  baseModule,
  mkRoutingRules,
  mkZapretBase,
}:

let
  evalZapret =
    zapretConfig:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite.zapret = {
          enable = true;
        }
        // zapretConfig;
      }
    ];

  zapretSyncFixture = evalZapret { };
  zapretSyncService = zapretSyncFixture.config.systemd.services."zapret-discord-youtube";
  zapretSyncRules = mkRoutingRules zapretSyncFixture;
  zapretSyncBase = mkZapretBase zapretSyncFixture;

  zapretSpacedConfigAliasBase = mkZapretBase (evalZapret {
    configName = "general(ALT12)";
  });

  zapretUnspacedConfigAliasBase = mkZapretBase (evalZapret {
    configName = "general (ALT)";
  });

  zapretSyncNoExtraListsFixture = evalZapret {
    includeExtraUpstreamLists = false;
  };
  zapretSyncNoExtraListsBase = mkZapretBase zapretSyncNoExtraListsFixture;
  zapretSyncNoExtraListsRules = mkRoutingRules zapretSyncNoExtraListsFixture;

  zapretSyncExtraListsFixture = evalZapret {
    includeExtraUpstreamLists = true;
  };
  zapretSyncExtraListsBase = mkZapretBase zapretSyncExtraListsFixture;
  zapretSyncExtraListsRules = mkRoutingRules zapretSyncExtraListsFixture;

  zapretSyncIpsRules = mkRoutingRules (evalZapret {
    syncDirectRoutingUpstreamIps = true;
  });

  zapretSyncUserIpsDisabledRules = mkRoutingRules (evalZapret {
    syncDirectRoutingUserIps = false;
    ipsetAll = [ "203.0.113.0/24" ];
  });

  zapretSyncDisabledRules = mkRoutingRules (evalZapret {
    syncDirectRouting = false;
  });

  zapretSyncDomainsOnlyRules = mkRoutingRules (evalZapret {
    syncDirectRouting = true;
    syncDirectRoutingUpstreamIps = false;
  });

  zapretExtrasRules = mkRoutingRules (evalZapret {
    listGeneral = [ "pixiv.net" ];
  });

  zapretIpExtrasRules = mkRoutingRules (evalZapret {
    ipsetAll = [ "203.0.113.0/24" ];
  });

  zapretExcludesRules = mkRoutingRules (evalZapret {
    listExclude = [ "discord.com" ];
  });

  zapretIpExcludesRules = mkRoutingRules (evalZapret {
    ipsetExclude = [ "1.1.1.0/24" ];
    ipsetAll = [ "1.1.1.0/24" ];
  });
in
{
  inherit
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
}
