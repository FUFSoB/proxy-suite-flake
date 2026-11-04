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
  perApp.perAppRouting = {
    enable = true;
    zapret.enable = true;
  };
  siteFilters = {
    domains = [ "pinned.example" ];
    excludeDomains = [ "excluded.example" ];
  };
in
{
  zapretDiscordYoutubeGlobal = evalProxySuite [
    baseModule
    { services.proxy-suite.zapret.enable = true; }
  ];

  zapret2Global = mkZapret2 { enable = true; };

  # The site filters: the per-app instance keeps the excludes alone.
  zapret2PerApp = mkZapret2With perApp {
    enable = true;
    zapret2 = siteFilters;
  };

  zapret2PerAppZ2k = mkZapret2With perApp {
    enable = true;
    zapret2 = siteFilters // {
      strategySource = "z2k";
    };
  };

  zapret2Tuned = mkZapret2With { debug.zapret2.autoHostlist = true; } {
    enable = true;
    cidrExemption = {
      enable = true;
      cidrs = [
        "192.168.123.0/24"
        "fd00:123::/64"
      ];
    };
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

  # The global and the per-app TUN route by their own sing-box, not the socks unit's.
  zapret2Tun = mkZapret2With {
    proxy.tun.enable = true;
    perAppRouting = {
      enable = true;
      tun.enable = true;
    };
  } { enable = true; };

  zapret2NoFallback = mkZapret2 {
    enable = true;
    zapret2.cutoff.proxyFallback = false;
  };

  zapret2Xray = evalProxySuite [
    baseModule
    (
      { lib, ... }:
      {
        services.proxy-suite = {
          proxy.backend = lib.mkForce "xray";
          zapret = {
            engine = "zapret2";
            enable = true;
          };
        };
      }
    )
  ];

  zapret2OwnProfiles = mkZapret2 {
    enable = true;
    zapret2.profiles = [ "--filter-tcp=443 --filter-l7=tls <HOSTLIST> --lua-desync=multisplit" ];
  };
}
