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
  zapretSyncService = zapretSyncFixture.config.systemd.services."proxy-suite-zapret";
  zapretSyncRules = mkRoutingRules zapretSyncFixture;
  zapretSyncBase = mkZapretBase zapretSyncFixture;

  zapretSpacedConfigAliasBase = mkZapretBase (evalZapret {
    zapret-discord-youtube.configName = "general(ALT12)";
  });

  zapretUnspacedConfigAliasBase = mkZapretBase (evalZapret {
    zapret-discord-youtube.configName = "general (ALT)";
  });

  zapretSyncNoExtraListsFixture = evalZapret {
    zapret-discord-youtube.includeExtraUpstreamLists = false;
  };
  zapretSyncNoExtraListsBase = mkZapretBase zapretSyncNoExtraListsFixture;
  zapretSyncNoExtraListsRules = mkRoutingRules zapretSyncNoExtraListsFixture;

  zapretSyncExtraListsFixture = evalZapret {
    zapret-discord-youtube.includeExtraUpstreamLists = true;
  };
  zapretSyncExtraListsBase = mkZapretBase zapretSyncExtraListsFixture;
  zapretSyncExtraListsRules = mkRoutingRules zapretSyncExtraListsFixture;

  zapretSyncIpsRules = mkRoutingRules (evalZapret {
    directSync.upstreamIps = true;
  });

  zapretSyncUserIpsDisabledRules = mkRoutingRules (evalZapret {
    directSync.userIps = false;
    zapret-discord-youtube.ips = [ "203.0.113.0/24" ];
  });

  zapretSyncDisabledRules = mkRoutingRules (evalZapret {
    directSync.enable = false;
  });

  zapretSyncDomainsOnlyRules = mkRoutingRules (evalZapret {
    directSync = {
      enable = true;
      upstreamIps = false;
    };
  });

  zapretExtrasRules = mkRoutingRules (evalZapret {
    zapret-discord-youtube.domains = [ "pixiv.net" ];
  });

  zapretIpExtrasRules = mkRoutingRules (evalZapret {
    zapret-discord-youtube.ips = [ "203.0.113.0/24" ];
  });

  zapretExcludesRules = mkRoutingRules (evalZapret {
    zapret-discord-youtube.excludeDomains = [ "discord.com" ];
  });

  zapretIpExcludesRules = mkRoutingRules (evalZapret {
    zapret-discord-youtube.excludeIps = [ "1.1.1.0/24" ];
    zapret-discord-youtube.ips = [ "1.1.1.0/24" ];
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
