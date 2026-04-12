{
  system,
  nixpkgs,
  proxySuiteModule,
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

  zapretSyncFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret.enable = true;
    }
  ];
  zapretSyncRules = mkRoutingRules zapretSyncFixture;

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

  zapretExtrasFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        listGeneral = [ "pixiv.net" ];
        ipsetAll = [ "203.0.113.0/24" ];
      };
    }
  ];
  zapretExtrasRules = mkRoutingRules zapretExtrasFixture;

  zapretExcludesFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.zapret = {
        enable = true;
        listExclude = [ "discord.com" ];
        ipsetExclude = [ "1.1.1.0/24" ];
      };
    }
  ];
  zapretExcludesRules = mkRoutingRules zapretExcludesFixture;

  proxyDirectFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.singBox.proxyByDefault = false;
    }
  ];
  proxyDirectConfig = mkTProxyConfig proxyDirectFixture;

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
      assert tproxyWithFirewall.config.networking.firewall.enable;
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
      assert hasDirectDomain zapretSyncRules "discord.com";
      true
    )
    (
      assert hasDirectDomain zapretSyncRules "youtube.com";
      true
    )
    (
      assert hasDirectIP zapretSyncRules "1.1.1.0/24";
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
      assert hasDirectIP zapretExtrasRules "203.0.113.0/24";
      true
    )
    (
      assert !(hasDirectDomain zapretExcludesRules "discord.com");
      true
    )
    (
      assert !(hasDirectIP zapretExcludesRules "1.1.1.0/24");
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
  ];
in
{
  proxy-suite-module = builtins.seq validated (pkgs.writeText "proxy-suite-module-check" "ok");

  build-outbound-parser =
    pkgs.runCommand "build-outbound-parser-check" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export BUILD_OUTBOUND_SCRIPT=${../scripts/build-outbound.py}
        python ${../scripts/test-build-outbound.py}
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
}
