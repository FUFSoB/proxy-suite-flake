{
  evalProxySuite,
  baseModule,
  mkRoutingRules,
  mkZapretBase,
  mkBadFixture,
  mkFailingAssertions,
}:

let
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
          {
            name = "google-general";
            defaultDomains = [ "google" ];
            configName = "general";
          }
          {
            name = "general-alt12";
            defaultDomains = [ "general" ];
            configName = "general (ALT12)";
          }
          {
            name = "youtube-alias";
            defaultDomains = [ "youtube" ];
            configName = "general";
            enableDirectSync = false;
          }
          {
            name = "discord-alias";
            defaultDomains = [ "discord" ];
            configName = "general (ALT12)";
            enableDirectSync = false;
          }
          {
            name = "upstream-ips";
            defaultIps = [ "all" ];
            configName = "general";
            enableDirectSync = false;
          }
          {
            name = "explicit-ips";
            ips = [ "203.0.113.0/24" ];
            configName = "general";
          }
        ];
      };
    }
  ];
  zapretHostlistRules = mkRoutingRules zapretHostlistRulesFixture;
  zapretHostlistBase = mkZapretBase zapretHostlistRulesFixture;

  invalidHostlistAssertions = mkFailingAssertions mkBadFixture [
    [
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
    ]
    [
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
    ]
    [
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
    ]
    [
      {
        services.proxy-suite.zapret = {
          enable = true;
          hostlistRules = [
            {
              name = "conflict";
              defaultDomains = [ "google" ];
              configName = "general";
              nfqwsArgs = [ "--filter-tcp=443 --dpi-desync=fake" ];
            }
          ];
        };
      }
    ]
    [
      {
        services.proxy-suite.zapret = {
          enable = true;
          hostlistRules = [
            {
              name = "missing-family";
              domains = [ "example.com" ];
              configName = "general";
            }
          ];
        };
      }
    ]
  ];
in
{
  inherit
    zapretHostlistRules
    zapretHostlistBase
    invalidHostlistAssertions
    ;
}
