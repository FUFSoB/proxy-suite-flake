{
  system,
  nixpkgs,
  proxySuiteModule,
  generatedOptionsDoc,
  zapret,
}:

let
  pkgs = import nixpkgs { inherit system; };
  evalProxySuite =
    modules:
    import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [ proxySuiteModule ] ++ modules;
    };
  forceEval = value: builtins.tryEval (builtins.deepSeq value true);
  rg = "${pkgs.ripgrep}/bin/rg";
  mkRouting =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
    in
    import ../modules/proxy-suite/rules.nix {
      lib = pkgs.lib;
      inherit pkgs cfg zapret;
    };
  mkRoutingRules = fixture: (mkRouting fixture).routingRules;
  mkTProxyConfig =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
      rules = mkRouting fixture;
      configs = import ../modules/proxy-suite/config.nix {
        lib = pkgs.lib;
        inherit pkgs cfg rules;
      };
    in
    builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile configs.tproxyFile));
  mkTunConfig =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
      rules = mkRouting fixture;
      configs = import ../modules/proxy-suite/config.nix {
        lib = pkgs.lib;
        inherit pkgs cfg rules;
      };
    in
    builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile configs.tunFile));
  hasDirectDomain =
    rules: domain:
    builtins.any (
      rule: (rule ? domain_suffix) && rule.outbound == "direct" && builtins.elem domain rule.domain_suffix
    ) rules;
  hasDirectIP =
    rules: cidr:
    builtins.any (
      rule: (rule ? ip_cidr) && rule.outbound == "direct" && builtins.elem cidr rule.ip_cidr
    ) rules;
  hasRuleSet =
    rules: outbound: ruleSet:
    builtins.any (
      rule: (rule ? rule_set) && rule.outbound == outbound && builtins.elem ruleSet rule.rule_set
    ) rules;
  dnsHasRuleSet =
    dnsRules: ruleSet:
    builtins.any (rule: (rule ? rule_set) && builtins.elem ruleSet rule.rule_set) dnsRules;
  dnsServerByTag =
    dnsConfig: tag:
    builtins.head (builtins.filter (server: server.tag == tag) dnsConfig.dns.servers);
  mkZapretBase =
    fixture:
    let
      env = fixture.config.systemd.services.zapret-discord-youtube.serviceConfig.Environment;
      zapretBaseEnv = builtins.head (
        builtins.filter (value: pkgs.lib.hasPrefix "ZAPRET_BASE=" value) env
      );
    in
    pkgs.lib.removePrefix "ZAPRET_BASE=" zapretBaseEnv;
  packagePathMatches =
    packages: pattern:
    builtins.any (
      pkg: builtins.match pattern (builtins.unsafeDiscardStringContext (toString pkg)) != null
    ) packages;

  baseModule = {
    system.stateVersion = "26.05";
    services.proxy-suite = {
      enable = true;
      singBox.outbounds = [
        {
          tag = "primary";
          url = "http://proxy.example.com:8080";
        }
      ];
    };
  };

  minimal = evalProxySuite [ baseModule ];

  tgSecretFile = evalProxySuite [
    baseModule
    {
      services.proxy-suite.tgWsProxy = {
        enable = true;
        host = "127.0.0.1";
        secretFile = "/run/secrets/tg-ws-proxy";
      };
    }
  ];

  duplicateTags = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          singBox.outbounds = [
            {
              tag = "dup";
              url = "http://one.example.com:8080";
            }
            {
              tag = "dup";
              url = "http://two.example.com:8080";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  reservedTag = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          singBox.outbounds = [
            {
              tag = "proxy";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  unknownRoutingTarget = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          singBox = {
            outbounds = [
              {
                tag = "primary";
                url = "http://proxy.example.com:8080";
              }
            ];
            routing.rules = [
              {
                outbound = "missing";
                domains = [ "example.com" ];
              }
            ];
          };
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  tproxyWithFirewall = evalProxySuite [
    {
      system.stateVersion = "26.05";
      networking.firewall.enable = true;
      services.proxy-suite = {
        enable = true;
        singBox = {
          tproxy.enable = true;
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      };
    }
  ];

  tproxyManualFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.tproxy.enable = true;
    }
  ];

  tproxyAutostartFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.tproxy = {
        enable = true;
        autostart = true;
      };
    }
  ];

  tunManualFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.tun.enable = true;
    }
  ];

  tunAutostartFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.tun = {
        enable = true;
        autostart = true;
      };
    }
  ];

  conflictingAutostartModes = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.singBox = {
          tproxy = {
            enable = true;
            autostart = true;
          };
          tun = {
            enable = true;
            autostart = true;
          };
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  routingOrFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        singBox = {
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
      services.proxy-suite.singBox.routing.enableRuDirect = false;
    }
  ];
  ruDisabledRules = mkRoutingRules ruDisabledFixture;
  ruDisabledConfig = mkTProxyConfig ruDisabledFixture;

  ruExplicitFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.routing = {
        enableRuDirect = false;
        direct.geosites = [ "category-ru" ];
      };
    }
  ];
  ruExplicitConfig = mkTProxyConfig ruExplicitFixture;

  dnsLocalOverrideFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.dns.local = {
        type = "tcp";
        address = "9.9.9.9";
        port = 5353;
      };
    }
  ];
  dnsLocalOverrideConfig = mkTProxyConfig dnsLocalOverrideFixture;

  dnsRemoteOverrideFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.dns.remote = {
        type = "tls";
        address = "1.0.0.1";
        port = 853;
      };
    }
  ];
  dnsRemoteOverrideConfig = mkTProxyConfig dnsRemoteOverrideFixture;
  tunDefaultConfig = mkTunConfig tunManualFixture;

  zapretSyncFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret.enable = true;
    }
  ];
  zapretSyncRules = mkRoutingRules zapretSyncFixture;
  zapretSyncBase = mkZapretBase zapretSyncFixture;

  zapretSyncNoExtraListsFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        includeExtraUpstreamLists = false;
      };
    }
  ];
  zapretSyncNoExtraListsBase = mkZapretBase zapretSyncNoExtraListsFixture;
  zapretSyncNoExtraListsRules = mkRoutingRules zapretSyncNoExtraListsFixture;

  zapretSyncExtraListsFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        includeExtraUpstreamLists = true;
      };
    }
  ];
  zapretSyncExtraListsBase = mkZapretBase zapretSyncExtraListsFixture;
  zapretSyncExtraListsRules = mkRoutingRules zapretSyncExtraListsFixture;

  zapretSyncIpsFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        syncDirectRoutingUpstreamIps = true;
      };
    }
  ];
  zapretSyncIpsRules = mkRoutingRules zapretSyncIpsFixture;

  zapretSyncUserIpsDisabledFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        syncDirectRoutingUserIps = false;
        ipsetAll = [ "203.0.113.0/24" ];
      };
    }
  ];
  zapretSyncUserIpsDisabledRules = mkRoutingRules zapretSyncUserIpsDisabledFixture;

  zapretSyncDisabledFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        syncDirectRouting = false;
      };
    }
  ];
  zapretSyncDisabledRules = mkRoutingRules zapretSyncDisabledFixture;

  zapretSyncDomainsOnlyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        syncDirectRouting = true;
        syncDirectRoutingUpstreamIps = false;
      };
    }
  ];
  zapretSyncDomainsOnlyRules = mkRoutingRules zapretSyncDomainsOnlyFixture;

  zapretExtrasFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        listGeneral = [ "pixiv.net" ];
      };
    }
  ];
  zapretExtrasRules = mkRoutingRules zapretExtrasFixture;

  zapretIpExtrasFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        ipsetAll = [ "203.0.113.0/24" ];
      };
    }
  ];
  zapretIpExtrasRules = mkRoutingRules zapretIpExtrasFixture;

  zapretExcludesFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        listExclude = [ "discord.com" ];
      };
    }
  ];
  zapretExcludesRules = mkRoutingRules zapretExcludesFixture;

  zapretIpExcludesFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        ipsetExclude = [ "1.1.1.0/24" ];
        ipsetAll = [ "1.1.1.0/24" ];
      };
    }
  ];
  zapretIpExcludesRules = mkRoutingRules zapretIpExcludesFixture;

  zapretHostlistRulesFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        hostlistRules = [
          {
            name = "googlevideo";
            domains = [
              "googlevideo.com"
              "ggpht.com"
            ];
            preset = "google";
          }
          {
            name = "example";
            domains = [
              "example.com"
              "example.de"
            ];
            nfqwsArgs = [ "--filter-tcp=443 --dpi-desync=fake,multisplit" ];
          }
          {
            name = "twitter-no-direct";
            domains = [ "x.example" ];
            nfqwsArgs = [ "--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6" ];
            enableDirectSync = false;
          }
        ];
      };
    }
  ];
  zapretHostlistRules = mkRoutingRules zapretHostlistRulesFixture;
  zapretHostlistBase = mkZapretBase zapretHostlistRulesFixture;

  duplicateZapretHostlistNames = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.zapret = {
          enable = true;
          hostlistRules = [
            {
              name = "dup";
              domains = [ "one.example" ];
              nfqwsArgs = [ "--filter-tcp=443 --dpi-desync=fake" ];
            }
            {
              name = "dup";
              domains = [ "two.example" ];
              nfqwsArgs = [ "--filter-tcp=443 --dpi-desync=fake" ];
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  emptyZapretHostlistDomains = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.zapret = {
          enable = true;
          hostlistRules = [
            {
              name = "empty";
              domains = [ ];
              nfqwsArgs = [ "--filter-tcp=443 --dpi-desync=fake" ];
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  missingZapretHostlistAction = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.zapret = {
          enable = true;
          hostlistRules = [
            {
              name = "missing";
              domains = [ "missing.example" ];
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  proxyDirectFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.proxyByDefault = false;
    }
  ];
  proxyDirectConfig = mkTProxyConfig proxyDirectFixture;

  trayAutostartFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.tray.enable = true;
    }
  ];

  trayManualFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.tray = {
        enable = true;
        autostart = false;
      };
    }
  ];

  # ---------------------------------------------------------------------------
  # Subscription fixtures
  # ---------------------------------------------------------------------------

  subscriptionOnlyFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        singBox.subscriptions = [
          {
            tag = "community";
            url = "https://example.com/sub/token";
          }
        ];
      };
    }
  ];

  subscriptionWithStaticFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        singBox = {
          outbounds = [
            {
              tag = "own-vps";
              url = "http://proxy.example.com:8080";
            }
          ];
          subscriptions = [
            {
              tag = "backup";
              url = "https://example.com/sub/token";
            }
          ];
          selection = "urltest";
          subscriptionUpdateInterval = "6h";
        };
      };
    }
  ];

  # selection=first with subscriptions only – start script must rename first
  # subscription outbound to "proxy" so routing rules resolve at runtime.
  subscriptionFirstSelectionFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        singBox = {
          subscriptions = [
            {
              tag = "community";
              url = "https://example.com/sub/token";
            }
          ];
          selection = "first";
        };
      };
    }
  ];

  subscriptionUrlFileFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        singBox.subscriptions = [
          {
            tag = "private";
            urlFile = "/run/secrets/sub-url";
          }
        ];
      };
    }
  ];

  urlTestCustomFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        singBox = {
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
            tolerance = 100;
          };
        };
      };
    }
  ];

  # Validation failures
  subscriptionBothSources = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          singBox.subscriptions = [
            {
              tag = "bad";
              url = "https://example.com/sub/token";
              urlFile = "/run/secrets/sub-url";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  subscriptionNoSources = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          singBox.subscriptions = [
            {
              tag = "bad";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  noOutboundsNoSubscriptions = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          # neither outbounds nor subscriptions set
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  blockGeoFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.routing.block = {
        geosites = [ "category-ads-all" ];
        geoips = [ "cn" ];
      };
    }
  ];
  blockGeoRules = mkRoutingRules blockGeoFixture;

  routingOrRules = mkRoutingRules routingOrFixture;

  routingOrDomainRules = builtins.filter (
    rule: (rule ? domain_suffix) && rule.domain_suffix == [ "example.com" ]
  ) routingOrRules;

  routingOrGeoIPRules = builtins.filter (
    rule: (rule ? rule_set) && rule.rule_set == [ "geoip-us" ]
  ) routingOrRules;

  validated = builtins.all (x: x) [
    (
      assert minimal.config.services.proxy-suite.singBox.listenAddress == "127.0.0.1";
      true
    )
    (
      assert tgSecretFile.config.services.proxy-suite.tgWsProxy.host == "127.0.0.1";
      true
    )
    (
      assert minimal.config.services.proxy-suite.tgWsProxy.host == "127.0.0.1";
      true
    )
    (
      assert minimal.config.services.proxy-suite.tgWsProxy.dcIps == { };
      true
    )
    (
      assert
        tgSecretFile.config.systemd.services."proxy-suite-tg-ws-proxy".serviceConfig.LoadCredential
        == [ "tg_ws_proxy_secret:/run/secrets/tg-ws-proxy" ];
      true
    )
    (
      assert duplicateTags.success == false;
      true
    )
    (
      assert reservedTag.success == false;
      true
    )
    (
      assert unknownRoutingTarget.success == false;
      true
    )
    (
      assert duplicateZapretHostlistNames.success == false;
      true
    )
    (
      assert emptyZapretHostlistDomains.success == false;
      true
    )
    (
      assert missingZapretHostlistAction.success == false;
      true
    )
    (
      assert tproxyWithFirewall.config.networking.firewall.enable;
      true
    )
    (
      assert tproxyManualFixture.config.services.proxy-suite.singBox.tproxy.autostart == false;
      assert tproxyManualFixture.config.systemd.services."proxy-suite-tproxy".wantedBy == [ ];
      true
    )
    (
      assert
        tproxyAutostartFixture.config.systemd.services."proxy-suite-tproxy".wantedBy
        == [ "multi-user.target" ];
      true
    )
    (
      assert tunManualFixture.config.services.proxy-suite.singBox.tun.autostart == false;
      assert tunManualFixture.config.systemd.services."proxy-suite-tun".wantedBy == [ ];
      true
    )
    (
      assert
        tunAutostartFixture.config.systemd.services."proxy-suite-tun".wantedBy
        == [ "multi-user.target" ];
      true
    )
    (
      assert conflictingAutostartModes.success == false;
      true
    )
    (
      assert builtins.length routingOrDomainRules == 1;
      true
    )
    (
      assert builtins.length routingOrGeoIPRules == 1;
      true
    )
    (
      assert (builtins.head routingOrDomainRules).outbound == "proxy";
      true
    )
    (
      assert (builtins.head routingOrGeoIPRules).outbound == "proxy";
      true
    )
    (
      let
        localDns = dnsServerByTag ruDefaultConfig "local";
        remoteDns = dnsServerByTag ruDefaultConfig "remote";
      in
      assert localDns.type == "udp";
      assert localDns.server == "1.1.1.1";
      assert localDns.server_port == 53;
      assert localDns.detour == "direct";
      assert remoteDns.type == "udp";
      assert remoteDns.server == "1.1.1.1";
      assert remoteDns.server_port == 53;
      assert remoteDns.detour == "proxy";
      true
    )
    (
      assert hasRuleSet ruDefaultRules "direct" "geosite-category-ru";
      true
    )
    (
      assert hasRuleSet ruDefaultRules "direct" "geoip-ru";
      true
    )
    (
      assert dnsHasRuleSet ruDefaultConfig.dns.rules "geosite-category-ru";
      true
    )
    (
      assert !(hasRuleSet ruDisabledRules "direct" "geosite-category-ru");
      true
    )
    (
      assert !(hasRuleSet ruDisabledRules "direct" "geoip-ru");
      true
    )
    (
      assert !(dnsHasRuleSet ruDisabledConfig.dns.rules "geosite-category-ru");
      true
    )
    (
      assert dnsHasRuleSet ruExplicitConfig.dns.rules "geosite-category-ru";
      true
    )
    (
      let
        localDns = dnsServerByTag dnsLocalOverrideConfig "local";
      in
      assert localDns.type == "tcp";
      assert localDns.server == "9.9.9.9";
      assert localDns.server_port == 5353;
      assert localDns.detour == "direct";
      true
    )
    (
      let
        remoteDns = dnsServerByTag dnsRemoteOverrideConfig "remote";
      in
      assert remoteDns.type == "tls";
      assert remoteDns.server == "1.0.0.1";
      assert remoteDns.server_port == 853;
      assert remoteDns.detour == "proxy";
      true
    )
    (
      let
        localDns = dnsServerByTag tunDefaultConfig "local";
      in
      assert localDns.detour == "proxy";
      true
    )
    (
      assert hasDirectDomain zapretSyncRules "discord.com";
      true
    )
    (
      assert hasDirectDomain zapretSyncRules "youtube.com";
      true
    )
    (
      assert hasDirectDomain zapretSyncRules "cloudflare-ech.com";
      true
    )
    (
      assert !(hasDirectDomain zapretSyncRules "twitter.com");
      true
    )
    (
      assert !(hasDirectIP zapretSyncRules "1.1.1.0/24");
      true
    )
    (
      assert hasDirectDomain zapretSyncDomainsOnlyRules "cloudflare-ech.com";
      true
    )
    (
      assert !(hasDirectIP zapretSyncDomainsOnlyRules "1.1.1.0/24");
      true
    )
    (
      assert hasDirectIP zapretSyncIpsRules "1.1.1.0/24";
      true
    )
    (
      assert !(hasDirectDomain zapretSyncNoExtraListsRules "twitter.com");
      true
    )
    (
      assert hasDirectDomain zapretSyncExtraListsRules "twitter.com";
      true
    )
    (
      assert !(hasDirectIP zapretSyncUserIpsDisabledRules "203.0.113.0/24");
      true
    )
    (
      assert !(hasDirectDomain zapretSyncDisabledRules "discord.com");
      true
    )
    (
      assert !(hasDirectIP zapretSyncDisabledRules "1.1.1.0/24");
      true
    )
    (
      assert hasDirectDomain zapretExtrasRules "pixiv.net";
      true
    )
    (
      assert hasDirectIP zapretIpExtrasRules "203.0.113.0/24";
      true
    )
    (
      assert !(hasDirectDomain zapretExcludesRules "discord.com");
      true
    )
    (
      assert !(hasDirectIP zapretIpExcludesRules "1.1.1.0/24");
      true
    )
    (
      assert hasDirectDomain zapretHostlistRules "googlevideo.com";
      true
    )
    (
      assert hasDirectDomain zapretHostlistRules "example.com";
      true
    )
    (
      assert !(hasDirectDomain zapretHostlistRules "x.example");
      true
    )
    (
      assert hasRuleSet blockGeoRules "block" "geosite-category-ads-all";
      true
    )
    (
      assert hasRuleSet blockGeoRules "block" "geoip-cn";
      true
    )
    (
      assert proxyDirectConfig.dns.final == "local";
      true
    )
    (
      assert ruDefaultConfig.dns.final == "remote";
      true
    )
    (
      assert packagePathMatches trayAutostartFixture.config.environment.systemPackages
        ".*/[^/]*proxy-suite-tray(-[0-9.]+)?$";
      true
    )
    (
      assert packagePathMatches trayAutostartFixture.config.environment.systemPackages
        ".*/[^/]*proxy-suite-tray\\.desktop$";
      true
    )
    (
      assert
        builtins.match ".*/share/xdg/autostart/proxy-suite-tray\\.desktop$" (
          builtins.unsafeDiscardStringContext
            trayAutostartFixture.config.environment.etc."xdg/autostart/proxy-suite-tray.desktop".source
        ) != null;
      true
    )
    (
      assert !(trayManualFixture.config.environment.etc ? "xdg/autostart/proxy-suite-tray.desktop");
      true
    )
    (
      assert packagePathMatches trayManualFixture.config.environment.systemPackages
        ".*/[^/]*proxy-suite-tray\\.desktop$";
      true
    )

    # -- subscription: basic config is accepted --
    (
      assert subscriptionOnlyFixture.config.services.proxy-suite.singBox.subscriptions != [ ];
      true
    )

    # -- subscription: update service is created when subscriptions are configured --
    (
      assert subscriptionOnlyFixture.config.systemd.services ? "proxy-suite-subscription-update";
      true
    )

    # -- subscription: update timer is created when subscriptions are configured --
    (
      assert subscriptionOnlyFixture.config.systemd.timers ? "proxy-suite-subscription-update";
      true
    )

    # -- subscription: StateDirectory set on socks service --
    (
      assert
        subscriptionOnlyFixture.config.systemd.services."proxy-suite-socks".serviceConfig.StateDirectory
        == "proxy-suite";
      true
    )

    # -- subscription: custom update interval flows through to timer --
    (
      assert
        subscriptionWithStaticFixture.config.systemd.timers."proxy-suite-subscription-update".timerConfig.OnUnitActiveSec
        == "6h";
      true
    )

    # -- subscription: selection=first renames first subscription outbound to "proxy" --
    (
      let
        startScript =
          subscriptionFirstSelectionFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart;
        scriptText = builtins.readFile startScript;
      in
      assert builtins.match ".*proxy.*" scriptText != null;
      true
    )

    # -- subscription: no update service/timer without subscriptions --
    (
      assert !(minimal.config.systemd.services ? "proxy-suite-subscription-update");
      true
    )
    (
      assert !(minimal.config.systemd.timers ? "proxy-suite-subscription-update");
      true
    )

    # -- subscription: urlFile form accepted --
    (
      assert subscriptionUrlFileFixture.config.services.proxy-suite.singBox.subscriptions != [ ];
      true
    )

    # -- subscription: both url + urlFile fails --
    (
      assert subscriptionBothSources.success == false;
      true
    )

    # -- subscription: neither url nor urlFile fails --
    (
      assert subscriptionNoSources.success == false;
      true
    )

    # -- subscription: no outbounds + no subscriptions fails --
    (
      assert noOutboundsNoSubscriptions.success == false;
      true
    )

    # -- urlTest: custom url/interval/tolerance propagate to start script --
    (
      let
        startScript =
          urlTestCustomFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart;
        scriptText = builtins.readFile startScript;
      in
      assert builtins.match ".*telegram\\.org.*" scriptText != null;
      assert builtins.match ".*1m.*" scriptText != null;
      assert builtins.match ".*100.*" scriptText != null;
      true
    )

    # -- urlTest: defaults are sane --
    (
      let
        cfg = minimal.config.services.proxy-suite.singBox.urlTest;
      in
      assert cfg.url == "https://www.gstatic.com/generate_204";
      assert cfg.interval == "3m";
      assert cfg.tolerance == 50;
      true
    )
  ];
in
{
  proxy-suite-module = builtins.seq validated (pkgs.writeText "proxy-suite-module-check" "ok");

  zapret-hostlist-rules = pkgs.runCommand "proxy-suite-zapret-hostlist-rules-check" { } ''
    grep -F -- '--hostlist="${zapretSyncExtraListsBase}/hostlists/list-twitter.txt"' "${zapretSyncExtraListsBase}/config"
    grep -F -- '--hostlist="${zapretSyncExtraListsBase}/hostlists/list-instagram.txt"' "${zapretSyncExtraListsBase}/config"
    grep -F -- '--hostlist="${zapretSyncExtraListsBase}/hostlists/list-soundcloud.txt"' "${zapretSyncExtraListsBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncBase}/hostlists/list-twitter.txt"' "${zapretSyncBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncBase}/hostlists/list-instagram.txt"' "${zapretSyncBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncBase}/hostlists/list-soundcloud.txt"' "${zapretSyncBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncNoExtraListsBase}/hostlists/list-twitter.txt"' "${zapretSyncNoExtraListsBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncNoExtraListsBase}/hostlists/list-instagram.txt"' "${zapretSyncNoExtraListsBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncNoExtraListsBase}/hostlists/list-soundcloud.txt"' "${zapretSyncNoExtraListsBase}/config"
    grep -F 'googlevideo.com' "${zapretHostlistBase}/hostlists/list-googlevideo.txt"
    grep -F 'example.de' "${zapretHostlistBase}/hostlists/list-example.txt"
    grep -F -- '--hostlist="${zapretHostlistBase}/hostlists/list-googlevideo.txt"' "${zapretHostlistBase}/config"
    grep -F -- '--hostlist="${zapretHostlistBase}/hostlists/list-example.txt"' "${zapretHostlistBase}/config"
    grep -F -- '--filter-tcp=443 --dpi-desync=fake,multisplit --hostlist="${zapretHostlistBase}/hostlists/list-example.txt" --hostlist-exclude="${zapretHostlistBase}/hostlists/list-exclude.txt" --hostlist-exclude="${zapretHostlistBase}/hostlists/list-exclude-user.txt" --ipset-exclude="${zapretHostlistBase}/hostlists/ipset-exclude.txt" --ipset-exclude="${zapretHostlistBase}/hostlists/ipset-exclude-user.txt" --new' "${zapretHostlistBase}/config"
    touch "$out"
  '';

  build-outbound-parser =
    pkgs.runCommand "build-outbound-parser-check" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export BUILD_OUTBOUND_SCRIPT=${../scripts/build-outbound.py}
        python ${../scripts/test-build-outbound.py}
        touch "$out"
      '';

  fetch-subscription-parser =
    pkgs.runCommand "fetch-subscription-parser-check" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export FETCH_SUBSCRIPTION_SCRIPT=${../scripts/fetch-subscription.py}
        python ${../scripts/test-fetch-subscription.py}
        touch "$out"
      '';

  no-secrets = pkgs.runCommand "proxy-suite-no-secrets-check" { } ''
    repo_root=${../.}
    if ${rg} --pcre2 -n -I -H -S \
      -e '-----BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----' \
      -e 'ghp_[A-Za-z0-9]{36}' \
      -e 'github_pat_[A-Za-z0-9_]{20,}' \
      -e 'glpat-[A-Za-z0-9_-]{20,}' \
      -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'AIza[0-9A-Za-z_-]{35}' \
      -e 'sk-(proj-)?[A-Za-z0-9_-]{20,}' \
      "$repo_root"; then
      echo "secret-like content detected in source tree" >&2
      exit 1
    fi
    touch "$out"
  '';

  options-doc = pkgs.runCommand "proxy-suite-options-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    diff -u ${../docs/options.md} ${generatedOptionsDoc}
    touch "$out"
  '';
}
