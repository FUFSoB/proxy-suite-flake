{
  system,
  nixpkgs,
  proxySuiteModule,
  generatedOptionsDoc,
  generatedReadmeDoc,
  zapret,
}:

let
  pkgs = import nixpkgs { inherit system; };
  readmeDocSource = builtins.readFile ../nix/readme-doc.nix;
  trayModuleSource = builtins.readFile ../modules/proxy-suite/tray.nix;
  tgWsProxyModuleSource = builtins.readFile ../modules/proxy-suite/tg-ws-proxy.nix;
  controlModuleSource = builtins.readFile ../modules/proxy-suite/service/control.nix;
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
  mkPerAppTunConfig =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
      rules = mkRouting fixture;
      configs = import ../modules/proxy-suite/config.nix {
        lib = pkgs.lib;
        inherit pkgs cfg rules;
      };
    in
    builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile configs.perAppTunFile));
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
  mkZapretBaseFor =
    fixture: serviceName:
    let
      env = fixture.config.systemd.services.${serviceName}.serviceConfig.Environment;
      zapretBaseEnv = builtins.head (
        builtins.filter (value: pkgs.lib.hasPrefix "ZAPRET_BASE=" value) env
      );
    in
    pkgs.lib.removePrefix "ZAPRET_BASE=" zapretBaseEnv;
  mkZapretBase = fixture: mkZapretBaseFor fixture "zapret-discord-youtube";
  packagePathMatches =
    packages: pattern:
    builtins.any (
      pkg: builtins.match pattern (builtins.unsafeDiscardStringContext (toString pkg)) != null
    ) packages;
  packageByPattern =
    packages: pattern:
    builtins.head (
      builtins.filter (
        pkg: builtins.match pattern (builtins.unsafeDiscardStringContext (toString pkg)) != null
      ) packages
    );
  lineByPrefix =
    text: prefix:
    builtins.head (
      builtins.filter (line: pkgs.lib.hasPrefix prefix line) (pkgs.lib.splitString "\n" text)
    );
  normalizeExec = value: if builtins.isList value then builtins.head value else value;
  readExecScripts =
    value:
    let
      execs = if builtins.isList value then value else [ value ];
    in
    pkgs.lib.concatStringsSep "\n" (map builtins.readFile execs);
  quotedValueByPrefix =
    text: prefix:
    pkgs.lib.removeSuffix "\"" (pkgs.lib.removePrefix prefix (lineByPrefix text prefix));
  shellValueByPrefix =
    text: prefix:
    let
      value = pkgs.lib.removePrefix prefix (lineByPrefix text prefix);
    in
    if pkgs.lib.hasPrefix "'" value && pkgs.lib.hasSuffix "'" value then
      pkgs.lib.removeSuffix "'" (pkgs.lib.removePrefix "'" value)
    else if pkgs.lib.hasPrefix "\"" value && pkgs.lib.hasSuffix "\"" value then
      pkgs.lib.removeSuffix "\"" (pkgs.lib.removePrefix "\"" value)
    else
      value;

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
  mkFixture = proxySuiteConfig: evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = proxySuiteConfig;
    }
  ];

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
    (mkFixture {
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
    }).config.system.build.toplevel.drvPath
  );

  reservedTag = forceEval (
    (mkFixture {
      enable = true;
      singBox.outbounds = [
        {
          tag = "proxy";
          url = "http://proxy.example.com:8080";
        }
      ];
    }).config.system.build.toplevel.drvPath
  );

  unknownRoutingTarget = forceEval (
    (mkFixture {
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
    }).config.system.build.toplevel.drvPath
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

  globalTunWithoutSingBox = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.singBox = {
          enable = false;
          tun.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  globalTproxyWithoutSingBox = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.singBox = {
          enable = false;
          tproxy.enable = true;
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

  perAppRoutingProxychainsFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.perAppRouting = {
        enable = true;
        proxychains.enable = true;
        profiles = [
          {
            name = "steam-browser";
            route = "proxychains";
          }
          {
            name = "native-direct";
            route = "direct";
          }
        ];
      };
    }
  ];
  perAppRoutingProxychainsProxyCtl =
    packageByPattern perAppRoutingProxychainsFixture.config.environment.systemPackages ".*/[^/]*proxy-ctl(-[0-9.]+)?$";
  perAppRoutingProxychainsWrapper =
    builtins.readFile "${perAppRoutingProxychainsProxyCtl}/bin/proxy-ctl";
  perAppRoutingProxychainsScript =
    perAppRoutingProxychainsWrapper
    + "\n"
    + builtins.readFile "${perAppRoutingProxychainsProxyCtl}/bin/.proxy-ctl-wrapped";
  perAppRoutingProxychainsConfig =
    builtins.readFile (
      shellValueByPrefix perAppRoutingProxychainsWrapper "export PROXYCHAINS_CONFIG="
    );
  perAppRoutingProxychainsProfiles =
    builtins.fromJSON (
      builtins.readFile (
        shellValueByPrefix perAppRoutingProxychainsWrapper "export PER_APP_ROUTING_PROFILES_FILE="
      )
    );

  perAppRoutingDefaultProfilesFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.perAppRouting = {
        enable = true;
        createDefaultProfiles = true;
        proxychains.enable = true;
      };
    }
  ];
  perAppRoutingDefaultProfilesProxyCtl =
    packageByPattern perAppRoutingDefaultProfilesFixture.config.environment.systemPackages ".*/[^/]*proxy-ctl(-[0-9.]+)?$";
  perAppRoutingDefaultProfilesWrapper =
    builtins.readFile "${perAppRoutingDefaultProfilesProxyCtl}/bin/proxy-ctl";
  perAppRoutingDefaultProfilesScript =
    perAppRoutingDefaultProfilesWrapper
    + "\n"
    + builtins.readFile "${perAppRoutingDefaultProfilesProxyCtl}/bin/.proxy-ctl-wrapped";
  perAppRoutingDefaultProfiles =
    builtins.fromJSON (
      builtins.readFile (
        shellValueByPrefix perAppRoutingDefaultProfilesWrapper "export PER_APP_ROUTING_PROFILES_FILE="
      )
    );

  perAppRoutingNoDefaultProfilesFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        singBox = {
          tun.perApp.enable = true;
          tproxy.perApp.enable = true;
        };
        zapret = {
          enable = true;
          perApp.enable = true;
        };
        perAppRouting = {
          enable = true;
          createDefaultProfiles = false;
          proxychains.enable = true;
        };
      };
    }
  ];
  perAppRoutingNoDefaultProfilesProxyCtl =
    packageByPattern perAppRoutingNoDefaultProfilesFixture.config.environment.systemPackages ".*/[^/]*proxy-ctl(-[0-9.]+)?$";
  perAppRoutingNoDefaultProfilesWrapper =
    builtins.readFile "${perAppRoutingNoDefaultProfilesProxyCtl}/bin/proxy-ctl";
  perAppRoutingNoDefaultProfilesScript =
    perAppRoutingNoDefaultProfilesWrapper
    + "\n"
    + builtins.readFile "${perAppRoutingNoDefaultProfilesProxyCtl}/bin/.proxy-ctl-wrapped";
  perAppRoutingNoDefaultProfiles =
    builtins.fromJSON (
      builtins.readFile (
        shellValueByPrefix perAppRoutingNoDefaultProfilesWrapper "export PER_APP_ROUTING_PROFILES_FILE="
      )
    );

  perAppRoutingDefaultProfilesWithoutProxychainsEnable = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTunFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        singBox.tun.perApp.enable = true;
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      };
    }
  ];
  perAppRoutingTunProxyCtl =
    packageByPattern perAppRoutingTunFixture.config.environment.systemPackages ".*/[^/]*proxy-ctl(-[0-9.]+)?$";
  perAppRoutingTunWrapper =
    builtins.readFile "${perAppRoutingTunProxyCtl}/bin/proxy-ctl";
  perAppRoutingTunScript =
    perAppRoutingTunWrapper
    + "\n"
    + builtins.readFile "${perAppRoutingTunProxyCtl}/bin/.proxy-ctl-wrapped";
  perAppRoutingTunProfiles =
    builtins.fromJSON (
      builtins.readFile (
        shellValueByPrefix perAppRoutingTunWrapper "export PER_APP_ROUTING_PROFILES_FILE="
      )
    );
  perAppRoutingTunStartScript =
    builtins.readFile perAppRoutingTunFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig.ExecStart;
  perAppRoutingTunConfig = mkPerAppTunConfig perAppRoutingTunFixture;
  perAppRoutingTunDirectOutbound =
    builtins.head (builtins.filter (item: item.tag == "direct") perAppRoutingTunConfig.outbounds);
  perAppRoutingTunUserStartExec =
    perAppRoutingTunFixture.config.systemd.services."proxy-suite-per-app-tun-user@".serviceConfig.ExecStart;
  perAppRoutingTunUserStartScript =
    builtins.readFile (builtins.head (pkgs.lib.splitString " " perAppRoutingTunUserStartExec));

  perAppRoutingTunWithTproxyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        singBox = {
          tproxy.enable = true;
          tun.perApp.enable = true;
        };
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      };
    }
  ];
  perAppRoutingTunWithTproxyStartScript =
    builtins.readFile perAppRoutingTunWithTproxyFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig.ExecStart;
  perAppRoutingTunWithTproxyConfig = mkPerAppTunConfig perAppRoutingTunWithTproxyFixture;
  perAppRoutingTunWithTproxyDirectOutbound =
    builtins.head (builtins.filter (item: item.tag == "direct") perAppRoutingTunWithTproxyConfig.outbounds);

  perAppRoutingTunWithoutEnable = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          profiles = [
            {
              name = "game";
              route = "tun";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTproxyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        singBox.tproxy.perApp.enable = true;
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
      };
    }
  ];
  perAppRoutingTproxyProxyCtl =
    packageByPattern perAppRoutingTproxyFixture.config.environment.systemPackages ".*/[^/]*proxy-ctl(-[0-9.]+)?$";
  perAppRoutingTproxyWrapper =
    builtins.readFile "${perAppRoutingTproxyProxyCtl}/bin/proxy-ctl";
  perAppRoutingTproxyScript =
    perAppRoutingTproxyWrapper
    + "\n"
    + builtins.readFile "${perAppRoutingTproxyProxyCtl}/bin/.proxy-ctl-wrapped";
  perAppRoutingTproxyProfiles =
    builtins.fromJSON (
      builtins.readFile (
        shellValueByPrefix perAppRoutingTproxyWrapper "export PER_APP_ROUTING_PROFILES_FILE="
      )
    );
  perAppRoutingTproxyStartScript =
    builtins.readFile perAppRoutingTproxyFixture.config.systemd.services."proxy-suite-per-app-tproxy".serviceConfig.ExecStart;
  perAppRoutingTproxyUserStartExec =
    perAppRoutingTproxyFixture.config.systemd.services."proxy-suite-per-app-tproxy-user@".serviceConfig.ExecStart;
  perAppRoutingTproxyUserStartScript =
    builtins.readFile (builtins.head (pkgs.lib.splitString " " perAppRoutingTproxyUserStartExec));

  perAppRoutingTproxyWithoutEnable = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          profiles = [
            {
              name = "browser";
              route = "tproxy";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingProxychainsWithoutSingBox = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox.enable = false;
          perAppRouting = {
            enable = true;
            proxychains.enable = true;
          };
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTunBackendWithoutSingBox = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox = {
            enable = false;
            tun.perApp.enable = true;
          };
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTproxyBackendWithoutSingBox = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox = {
            enable = false;
            tproxy.perApp.enable = true;
          };
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTunProfileWithoutSingBox = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox.enable = false;
          perAppRouting = {
            enable = true;
            profiles = [
              {
                name = "game";
                route = "tun";
              }
            ];
          };
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTproxyProfileWithoutSingBox = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox.enable = false;
          perAppRouting = {
            enable = true;
            profiles = [
              {
                name = "browser";
                route = "tproxy";
              }
            ];
          };
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingZapretFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        zapret = {
          enable = true;
          perApp.enable = true;
        };
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
          proxychains.enable = true;
        };
      };
    }
  ];
  perAppRoutingZapretProxyCtl =
    packageByPattern perAppRoutingZapretFixture.config.environment.systemPackages ".*/[^/]*proxy-ctl(-[0-9.]+)?$";
  perAppRoutingZapretWrapper =
    builtins.readFile "${perAppRoutingZapretProxyCtl}/bin/proxy-ctl";
  perAppRoutingZapretScript =
    perAppRoutingZapretWrapper
    + "\n"
    + builtins.readFile "${perAppRoutingZapretProxyCtl}/bin/.proxy-ctl-wrapped";
  perAppRoutingZapretProfiles =
    builtins.fromJSON (
      builtins.readFile (
        shellValueByPrefix perAppRoutingZapretWrapper "export PER_APP_ROUTING_PROFILES_FILE="
      )
    );
  perAppRoutingZapretStartScript =
    readExecScripts perAppRoutingZapretFixture.config.systemd.services."proxy-suite-per-app-zapret".serviceConfig.ExecStartPre;
  perAppRoutingZapretUserStartExec =
    perAppRoutingZapretFixture.config.systemd.services."proxy-suite-per-app-zapret-user@".serviceConfig.ExecStart;
  perAppRoutingZapretUserStartScript =
    builtins.readFile (builtins.head (pkgs.lib.splitString " " perAppRoutingZapretUserStartExec));
  perAppRoutingZapretBase = mkZapretBase perAppRoutingZapretFixture;
  perAppRoutingZapretConfig = builtins.readFile "${perAppRoutingZapretBase}/config";
  perAppRoutingPerAppZapretBase = mkZapretBaseFor perAppRoutingZapretFixture "proxy-suite-per-app-zapret";
  perAppRoutingPerAppZapretConfig = builtins.readFile "${perAppRoutingPerAppZapretBase}/config";
  perAppRoutingZapretGlobalCustomScript =
    builtins.readFile "${perAppRoutingZapretBase}/init.d/sysv/custom.d/50-proxy-suite-custom.sh";
  perAppRoutingTunPolkitConfig = perAppRoutingTunFixture.config.security.polkit.extraConfig;

  userControlGlobalOnlyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.userControl = {
        global.enable = true;
        perApp.enable = false;
      };
    }
  ];
  userControlGlobalOnlyPolkitConfig = userControlGlobalOnlyFixture.config.security.polkit.extraConfig;

  userControlPerAppOnlyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        singBox.tun.perApp.enable = true;
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
        };
        userControl = {
          global.enable = false;
          perApp.enable = true;
        };
      };
    }
  ];
  userControlPerAppOnlyPolkitConfig = userControlPerAppOnlyFixture.config.security.polkit.extraConfig;

  userControlDisabledFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.userControl = {
        global.enable = false;
        perApp.enable = false;
      };
    }
  ];

  perAppRoutingZapretWithoutEnable = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          zapret.enable = true;
          perAppRouting = {
            enable = true;
            profiles = [
              {
                name = "yt";
                route = "zapret";
              }
            ];
          };
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingZapretWithoutZapretService = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          zapret = {
            enable = false;
            perApp.enable = true;
          };
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  duplicatePerAppRoutingProfiles = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          profiles = [
            { name = "dup"; }
            { name = "dup"; }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingProfilesWithoutEnable = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.perAppRouting.profiles = [ { name = "oops"; } ];
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingProxychainsWithoutEnable = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite.perAppRouting = {
          enable = true;
          profiles = [
            {
              name = "steam-browser";
              route = "proxychains";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTunFwmarkCollision = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox = {
            tproxy = {
              enable = true;
              proxyMark = 16;
            };
            tun.perApp = {
              enable = true;
              fwmark = 16;
            };
          };
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTproxyFwmarkCollision = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox.tproxy = {
            proxyMark = 17;
            perApp = {
              enable = true;
              fwmark = 17;
            };
          };
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTunTproxyFwmarkCollision = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox = {
            tun.perApp = {
              enable = true;
              fwmark = 23;
            };
            tproxy.perApp = {
              enable = true;
              fwmark = 23;
            };
          };
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTunTproxyRouteTableCollision = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          singBox = {
            tun.perApp = {
              enable = true;
              routeTable = 123;
            };
            tproxy.perApp = {
              enable = true;
              routeTable = 123;
            };
          };
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingZapretFilterMarkCollision = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          zapret = {
            enable = true;
            perApp = {
              enable = true;
              filterMark = 268435456;
            };
          };
          singBox.tproxy.proxyMark = 268435456;
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  perAppRoutingTproxyZapretMarkCollision = forceEval (
    (evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          zapret = {
            enable = true;
            perApp = {
              enable = true;
              filterMark = 23;
            };
          };
          singBox.tproxy.perApp = {
            enable = true;
            fwmark = 23;
          };
          perAppRouting.enable = true;
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

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
      assert globalTunWithoutSingBox.success == false;
      assert globalTproxyWithoutSingBox.success == false;
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
      assert !(localDns ? detour);
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
      assert !(localDns ? detour);
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
      assert ruDefaultConfig.route.default_domain_resolver == "local";
      assert tunDefaultConfig.route.default_domain_resolver == "local";
      assert perAppRoutingTunConfig.route.default_domain_resolver == "local";
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

    # -- runtime parser: socks start script sets PYTHONPATH for static URL parser imports --
    (
      let
        startScript =
          subscriptionWithStaticFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart;
        scriptText = builtins.readFile startScript;
      in
      assert builtins.match ".*PYTHONPATH=.*build-outbound\\.py.*" scriptText != null;
      true
    )

    # -- subscription/runtime parser: update script sets PYTHONPATH for parser module imports --
    (
      let
        updateScript =
          subscriptionOnlyFixture.config.systemd.services."proxy-suite-subscription-update".serviceConfig.ExecStart;
        scriptText = builtins.readFile updateScript;
      in
      assert builtins.match ".*PYTHONPATH=.*fetch-subscription\\.py.*" scriptText != null;
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

    # -- perAppRouting: proxychains/direct profile config is accepted --
    (
      assert perAppRoutingProxychainsFixture.config.services.proxy-suite.perAppRouting.enable;
      true
    )
    (
      assert builtins.length perAppRoutingProxychainsFixture.config.services.proxy-suite.perAppRouting.profiles == 2;
      true
    )
    (
      assert builtins.length perAppRoutingProxychainsProfiles == 2;
      true
    )

    # -- perAppRouting: createDefaultProfiles injects curated proxychains profile --
    (
      assert builtins.length perAppRoutingDefaultProfiles == 1;
      assert (builtins.head perAppRoutingDefaultProfiles).name == "proxychains";
      assert (builtins.head perAppRoutingDefaultProfiles).route == "proxychains";
      true
    )

    # -- perAppRouting: createDefaultProfiles = false injects no curated profiles --
    (
      assert builtins.length perAppRoutingNoDefaultProfiles == 0;
      true
    )

    # -- perAppRouting: createDefaultProfiles injects curated tun profile when backend is enabled --
    (
      assert builtins.length perAppRoutingTunProfiles == 2;
      assert builtins.any (profile: profile.name == "tun" && profile.route == "tun") perAppRoutingTunProfiles;
      true
    )

    # -- perAppRouting: createDefaultProfiles injects curated tproxy profile when backend is enabled --
    (
      assert builtins.length perAppRoutingTproxyProfiles == 2;
      assert builtins.any (profile: profile.name == "tproxy" && profile.route == "tproxy") perAppRoutingTproxyProfiles;
      true
    )

    # -- perAppRouting: createDefaultProfiles injects curated zapret profile when backend and zapret are enabled --
    (
      assert builtins.length perAppRoutingZapretProfiles == 2;
      assert builtins.any (profile: profile.name == "zapret" && profile.route == "zapret") perAppRoutingZapretProfiles;
      true
    )

    # -- perAppRouting: proxy-ctl script embeds wrap/apps commands --
    (
      assert pkgs.lib.hasInfix "help)" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "show this help message" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "wrap <profile> -- <cmd>" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "apps" perAppRoutingProxychainsScript;
      true
    )

    # -- perAppRouting: proxychains config is quiet and points at local SOCKS listener --
    (
      assert pkgs.lib.hasInfix "quiet_mode" perAppRoutingProxychainsConfig;
      assert pkgs.lib.hasInfix "proxy_dns" perAppRoutingProxychainsConfig;
      assert pkgs.lib.hasInfix "socks5 127.0.0.1 1080" perAppRoutingProxychainsConfig;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches through proxychains4 --
    (
      assert pkgs.lib.hasInfix "export PROXYCHAINS_QUIET_ARG='-q'" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "exec proxychains4 $PROXYCHAINS_QUIET_ARG -f \"$PROXYCHAINS_CONFIG\" \"$@\"" perAppRoutingProxychainsScript;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches tun profiles through systemd slices --
    (
      assert pkgs.lib.hasInfix "PER_APP_ROUTING_TUN_ENABLED" perAppRoutingTunScript;
      assert pkgs.lib.hasInfix "systemd-run --user --scope --quiet --collect --same-dir" perAppRoutingTunScript;
      assert pkgs.lib.hasInfix ''_wrap_slice "proxy-suite-per-app-tun" "$PER_APP_ROUTING_TUN_ENABLED"'' perAppRoutingTunScript;
      assert pkgs.lib.hasInfix "$slice_base-user@$uid.service" perAppRoutingTunScript;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches tproxy profiles through systemd slices --
    (
      assert pkgs.lib.hasInfix "PER_APP_ROUTING_TPROXY_ENABLED" perAppRoutingTproxyScript;
      assert pkgs.lib.hasInfix ''_wrap_slice "proxy-suite-per-app-tproxy" "$PER_APP_ROUTING_TPROXY_ENABLED"'' perAppRoutingTproxyScript;
      assert pkgs.lib.hasInfix ''$slice_base-''${profile}-$$'' perAppRoutingTproxyScript;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches zapret profiles through systemd slices --
    (
      assert pkgs.lib.hasInfix "PER_APP_ROUTING_ZAPRET_ENABLED" perAppRoutingZapretScript;
      assert pkgs.lib.hasInfix ''_wrap_slice "proxy-suite-per-app-zapret" "$PER_APP_ROUTING_ZAPRET_ENABLED"'' perAppRoutingZapretScript;
      assert pkgs.lib.hasInfix ''$slice_base-''${profile}-$$'' perAppRoutingZapretScript;
      true
    )

    # -- perAppRouting: user mark script installs fwmark + conntrack mark rules --
    (
      assert pkgs.lib.hasInfix "meta mark set" perAppRoutingTunUserStartScript;
      assert pkgs.lib.hasInfix "ct mark set" perAppRoutingTunUserStartScript;
      true
    )

    # -- perAppRouting: app TUN config is separate and does not auto-route globally --
    (
      let
        inbound = builtins.head (builtins.filter (item: item.tag == "tun-in") perAppRoutingTunConfig.inbounds);
      in
      assert inbound.interface_name == "psperapptun0";
      assert inbound.address == [ "172.20.0.1/30" ];
      assert inbound.auto_route == false;
      assert inbound.auto_redirect == false;
      assert inbound.strict_route == false;
      true
    )

    # -- perAppRouting: app TUN local DNS keeps direct path without explicit detour --
    (
      let
        localDns = dnsServerByTag perAppRoutingTunConfig "local";
      in
      assert !(localDns ? detour);
      true
    )

    # -- perAppRouting: app TUN does not set outbound routing marks when TProxy is disabled --
    (
      assert builtins.match ".*--routing-mark.*" perAppRoutingTunStartScript == null;
      assert !(perAppRoutingTunDirectOutbound ? routing_mark);
      true
    )

    # -- perAppRouting: app TUN applies outbound routing marks when TProxy is enabled --
    (
      let
        expectedMark = perAppRoutingTunWithTproxyFixture.config.services.proxy-suite.singBox.tproxy.proxyMark;
      in
      assert builtins.match ".*--routing-mark.*" perAppRoutingTunWithTproxyStartScript != null;
      assert perAppRoutingTunWithTproxyDirectOutbound.routing_mark == expectedMark;
      true
    )

    # -- perAppRouting: app TUN service and helper units are created --
    (
      assert perAppRoutingTunFixture.config.systemd.services ? "proxy-suite-per-app-tun";
      assert perAppRoutingTunFixture.config.systemd.services ? "proxy-suite-per-app-tun-user@";
      assert perAppRoutingTunFixture.config.systemd.user.services ? "proxy-suite-per-app-tun-anchor";
      true
    )

    # -- perAppRouting: app TProxy service and helper units are created --
    (
      assert perAppRoutingTproxyFixture.config.systemd.services ? "proxy-suite-per-app-tproxy";
      assert perAppRoutingTproxyFixture.config.systemd.services ? "proxy-suite-per-app-tproxy-user@";
      assert perAppRoutingTproxyFixture.config.systemd.user.services ? "proxy-suite-per-app-tproxy-anchor";
      true
    )

    # -- perAppRouting: app zapret service and helper units are created --
    (
      assert perAppRoutingZapretFixture.config.systemd.services ? "proxy-suite-per-app-zapret";
      assert perAppRoutingZapretFixture.config.systemd.services ? "proxy-suite-per-app-zapret-user@";
      assert perAppRoutingZapretFixture.config.systemd.user.services ? "proxy-suite-per-app-zapret-anchor";
      true
    )

    # -- perAppRouting: app TUN enables nftables and user control group --
    (
      assert perAppRoutingTunFixture.config.networking.nftables.enable;
      assert perAppRoutingTunFixture.config.users.groups ? "proxy-suite";
      true
    )

    # -- userControl: default polkit rule covers both per-app and global proxy-ctl managed units --
    (
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-per-app-\") === 0" perAppRoutingTunPolkitConfig;
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-\") === 0" perAppRoutingTunPolkitConfig;
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-per-app-\") !== 0" perAppRoutingTunPolkitConfig;
      assert pkgs.lib.hasInfix "unit === \"zapret-discord-youtube.service\"" perAppRoutingTunPolkitConfig;
      true
    )

    # -- userControl: global-only rule excludes per-app units --
    (
      assert userControlGlobalOnlyFixture.config.users.groups ? "proxy-suite";
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-\") === 0" userControlGlobalOnlyPolkitConfig;
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-per-app-\") !== 0" userControlGlobalOnlyPolkitConfig;
      assert builtins.match ".*unit\\.indexOf\\(\"proxy-suite-per-app-\"\\) === 0.*" userControlGlobalOnlyPolkitConfig == null;
      assert pkgs.lib.hasInfix "unit === \"zapret-discord-youtube.service\"" userControlGlobalOnlyPolkitConfig;
      true
    )

    # -- userControl: per-app-only rule covers per-app-scoped helpers only --
    (
      assert userControlPerAppOnlyFixture.config.users.groups ? "proxy-suite";
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-per-app-\") === 0" userControlPerAppOnlyPolkitConfig;
      assert builtins.match ".*unit\\.indexOf\\(\"proxy-suite-per-app-\"\\) !== 0.*" userControlPerAppOnlyPolkitConfig == null;
      assert builtins.match ".*unit === \"zapret-discord-youtube\\.service\".*" userControlPerAppOnlyPolkitConfig == null;
      true
    )

    # -- userControl: disabling both scopes removes group and polkit wiring --
    (
      assert !(userControlDisabledFixture.config.users.groups ? "proxy-suite");
      assert !userControlDisabledFixture.config.security.polkit.enable;
      assert builtins.match ".*subject\\.isInGroup\\(\"proxy-suite\"\\).*" userControlDisabledFixture.config.security.polkit.extraConfig == null;
      assert builtins.match ".*org\\.freedesktop\\.systemd1\\.manage-units.*" userControlDisabledFixture.config.security.polkit.extraConfig == null;
      true
    )

    # -- perAppRouting: app TProxy helper installs socket cgroup mark rules --
    (
      assert pkgs.lib.hasInfix "socket cgroupv2" perAppRoutingTproxyUserStartScript;
      assert pkgs.lib.hasInfix "meta mark set" perAppRoutingTproxyUserStartScript;
      assert pkgs.lib.hasInfix "ct mark set" perAppRoutingTproxyUserStartScript;
      true
    )

    # -- perAppRouting: app TProxy startup installs nftables and loopback policy route --
    (
      assert pkgs.lib.hasInfix "proxy_suite_per_app_tproxy" perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "route replace local default dev lo table 102" perAppRoutingTproxyStartScript;
      assert pkgs.lib.hasInfix "rule add fwmark 17 table 102" perAppRoutingTproxyStartScript;
      true
    )

    # -- perAppRouting: app zapret helper installs socket cgroup bitwise mark rules --
    (
      assert pkgs.lib.hasInfix "socket cgroupv2" perAppRoutingZapretUserStartScript;
      assert pkgs.lib.hasInfix "meta mark set meta mark or 268435456" perAppRoutingZapretUserStartScript;
      assert pkgs.lib.hasInfix "ct mark set ct mark or 268435456" perAppRoutingZapretUserStartScript;
      true
    )

    # -- perAppRouting: app zapret startup installs nftables backend --
    (
      assert pkgs.lib.hasInfix "proxy_suite_per_app_zapret_mark" perAppRoutingZapretStartScript;
      true
    )

    # -- perAppRouting: global zapret config keeps FILTER_MARK disabled --
    (
      assert pkgs.lib.hasInfix "FILTER_MARK=" perAppRoutingZapretConfig;
      assert builtins.match ".*FILTER_MARK=0x10000000.*" perAppRoutingZapretConfig == null;
      true
    )

    # -- perAppRouting: app zapret config is a separate instance with its own filter/qnum/marks --
    (
      assert pkgs.lib.hasInfix "FILTER_MARK=0x10000000" perAppRoutingPerAppZapretConfig;
      assert pkgs.lib.hasInfix "MODE_FILTER=none" perAppRoutingPerAppZapretConfig;
      assert pkgs.lib.hasInfix "QNUM=201" perAppRoutingPerAppZapretConfig;
      assert pkgs.lib.hasInfix "DESYNC_MARK=0x8000000" perAppRoutingPerAppZapretConfig;
      assert pkgs.lib.hasInfix "DESYNC_MARK_POSTNAT=0x4000000" perAppRoutingPerAppZapretConfig;
      assert pkgs.lib.hasInfix "ZAPRET_NFT_TABLE=proxy_suite_per_app_zapret" perAppRoutingPerAppZapretConfig;
      true
    )

    # -- perAppRouting: global zapret installs a bypass hook for app-marked traffic --
    (
      assert pkgs.lib.hasInfix "proxy-suite per-app-zapret bypass" perAppRoutingZapretGlobalCustomScript;
      assert pkgs.lib.hasInfix "mark and 268435456 != 0 return" perAppRoutingZapretGlobalCustomScript;
      true
    )

    # -- perAppRouting: route=proxychains requires proxychains.enable --
    (
      assert perAppRoutingProxychainsWithoutEnable.success == false;
      true
    )

    # -- perAppRouting: proxychains requires singBox.enable --
    (
      assert perAppRoutingProxychainsWithoutSingBox.success == false;
      true
    )

    # -- perAppRouting: profiles require perAppRouting.enable --
    (
      assert perAppRoutingProfilesWithoutEnable.success == false;
      true
    )

    # -- perAppRouting: default proxychains profile still requires proxychains.enable --
    (
      assert perAppRoutingDefaultProfilesWithoutProxychainsEnable.success == false;
      true
    )

    # -- perAppRouting: route=tun requires singBox.tun.perApp.enable --
    (
      assert perAppRoutingTunWithoutEnable.success == false;
      true
    )

    # -- perAppRouting: app TUN backend requires singBox.enable --
    (
      assert perAppRoutingTunBackendWithoutSingBox.success == false;
      assert perAppRoutingTunProfileWithoutSingBox.success == false;
      true
    )

    # -- perAppRouting: route=tproxy requires singBox.tproxy.perApp.enable --
    (
      assert perAppRoutingTproxyWithoutEnable.success == false;
      true
    )

    # -- perAppRouting: app TProxy backend requires singBox.enable --
    (
      assert perAppRoutingTproxyBackendWithoutSingBox.success == false;
      assert perAppRoutingTproxyProfileWithoutSingBox.success == false;
      true
    )

    # -- perAppRouting: route=zapret requires zapret.perApp.enable and zapret.enable --
    (
      assert perAppRoutingZapretWithoutEnable.success == false;
      true
    )
    (
      assert perAppRoutingZapretWithoutZapretService.success == false;
      true
    )

    # -- perAppRouting: profile names must be unique --
    (
      assert duplicatePerAppRoutingProfiles.success == false;
      true
    )

    # -- perAppRouting: with TProxy enabled, app TUN fwmark must differ from proxyMark --
    (
      assert perAppRoutingTunFwmarkCollision.success == false;
      true
    )

    # -- perAppRouting: app TProxy fwmark must differ from sing-box proxyMark --
    (
      assert perAppRoutingTproxyFwmarkCollision.success == false;
      true
    )

    # -- perAppRouting: app TUN and app TProxy fwmarks must differ --
    (
      assert perAppRoutingTunTproxyFwmarkCollision.success == false;
      true
    )

    # -- perAppRouting: app TUN and app TProxy route tables must differ --
    (
      assert perAppRoutingTunTproxyRouteTableCollision.success == false;
      true
    )

    # -- perAppRouting: app zapret filter mark must differ from sing-box proxyMark --
    (
      assert perAppRoutingZapretFilterMarkCollision.success == false;
      true
    )

    # -- perAppRouting: app TProxy and app zapret marks must differ --
    (
      assert perAppRoutingTproxyZapretMarkCollision.success == false;
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
        export PYTHONPATH=${../scripts}:$PYTHONPATH
        export BUILD_OUTBOUND_SCRIPT=${../scripts/build-outbound.py}
        python ${../scripts/test-build-outbound.py}
        touch "$out"
      '';

  fetch-subscription-parser =
    pkgs.runCommand "fetch-subscription-parser-check" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export PYTHONPATH=${../scripts}:$PYTHONPATH
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

  readme-doc = pkgs.runCommand "proxy-suite-readme-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    diff -u ${../README.md} ${generatedReadmeDoc}
    touch "$out"
  '';

  readme-doc-source = builtins.seq
    (
      assert !(pkgs.lib.hasInfix "environment.systemPackages" readmeDocSource);
      assert !(pkgs.lib.hasInfix "packageByPattern" readmeDocSource);
      true
    )
    (pkgs.writeText "proxy-suite-readme-doc-source-check" "ok");

  package-source = builtins.seq
    (
      assert !(pkgs.lib.hasInfix "../../pkgs/proxy-suite-tray.nix" trayModuleSource);
      assert !(pkgs.lib.hasInfix "../../pkgs/tg-ws-proxy.nix" tgWsProxyModuleSource);
      assert !(pkgs.lib.hasInfix "../../../pkgs/proxy-ctl.nix" controlModuleSource);
      true
    )
    (pkgs.writeText "proxy-suite-package-source-check" "ok");
}
