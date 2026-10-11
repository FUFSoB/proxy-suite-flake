{
  evalProxySuite,
  baseModule,
}:

let
  # `extra`: more of services.proxy-suite, beside zapret.
  mkZapret2With =
    extra: zapret:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          zapret = {
            engine = "zapret2";
          }
          // zapret;
        }
        // extra;
      }
    ];
  mkZapret2 = mkZapret2With { };
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

  zapret2Tuned = mkZapret2With { debug.zapret2.autoHostlist = true; } {
    enable = true;
    zapret2 = {
      domains = [ "pinned.example" ];
      excludeDomains = [ "excluded.example" ];
      ports = {
        extraTcp = [ 8444 ];
        extraUdp = [
          "27015-27030"
          "50000-50100"
        ];
      };
      autoHostlist = {
        failThreshold = 5;
        failTime = 120;
        retransThreshold = 4;
        extendedDetection = false;
      };
    };
  };

  zapret2NoAuto = mkZapret2 {
    enable = true;
    zapret2.autoHostlist.enable = false;
  };

  zapret2Z2k = mkZapret2 {
    enable = true;
    zapret2.strategySource = "z2k";
  };

  zapret2Z2kTuned = mkZapret2 {
    enable = true;
    zapret2 = {
      strategySource = "z2k";
      ports.extraTcp = [ 8444 ];
      strategyLog = false;
      # The old name of debug.zapret2.packets: the alias must still reach nfqws2.
      debug = true;
      autoHostlist.extendedDetection = false;
    };
  };

  zapret2NoFallback = mkZapret2 {
    enable = true;
    zapret2.cutoff.proxyFallback = false;
  };
}
