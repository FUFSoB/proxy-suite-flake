{
  evalProxySuite,
  baseModule,
}:

let
  mkZapret2 =
    zapret:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite.zapret = {
          engine = "zapret2";
        }
        // zapret;
      }
    ];
in
{
  zapretDiscordYoutubeGlobal = evalProxySuite [
    baseModule
    { services.proxy-suite.zapret.enable = true; }
  ];

  zapret2Global = mkZapret2 { enable = true; };

  zapret2PerApp = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        perAppRouting = {
          enable = true;
          zapret.enable = true;
        };
        zapret = {
          engine = "zapret2";
          enable = true;
        };
      };
    }
  ];

  zapret2Tuned = mkZapret2 {
    enable = true;
    zapret2 = {
      domains = [ "pinned.example" ];
      excludeDomains = [ "excluded.example" ];
      autoHostlist = {
        failThreshold = 5;
        failTime = 120;
        retransThreshold = 4;
        debugLog = true;
      };
    };
  };

  zapret2NoAuto = mkZapret2 {
    enable = true;
    zapret2.autoHostlist.enable = false;
  };
}
