{
  evalProxySuite,
  baseModule,
  mkRoutingRules,
  mkTProxyNftRules,
  mkBadFixture,
  mkFailingAssertions,
}:

let
  generated = import ../read-generated.nix;

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
  tgSecretFileService = tgSecretFile.config.systemd.services."proxy-suite-tg-ws-proxy";

  tgAllOptions = evalProxySuite [
    baseModule
    {
      services.proxy-suite.tgWsProxy = {
        enable = true;
        port = 2443;
        host = "0.0.0.0";
        secretFile = "/run/secrets/tg-ws-proxy";
        verbose = true;
        logFile = "/var/log/tg-ws-proxy.log";
        logMaxMb = 2.5;
        logBackups = 3;
        bufKb = 512;
        poolSize = 8;
        cfProxyDomains = [
          "cdn.example.com"
          "edge.example.net"
        ];
        cfProxyWorkerDomains = [ "worker.example.com" ];
        cfProxyFallback = false;
        fakeTlsDomain = "mask.example.com";
        proxyProtocol = true;
      };
    }
  ];
  tgAllOptionsStartScript = generated.readDerivation (
    tgAllOptions.config.systemd.services."proxy-suite-tg-ws-proxy".serviceConfig.ExecStart
  );

  tgWithGlobalTun = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy.tun.enable = true;
        tgWsProxy = {
          enable = true;
          secretFile = "/run/secrets/tg-ws-proxy";
          dcIps."2" = "149.154.167.220";
        };
      };
    }
  ];
  tgWithGlobalTunServiceConfig =
    tgWithGlobalTun.config.systemd.services."proxy-suite-tg-ws-proxy".serviceConfig;
  tgWithGlobalTunBypassUp = generated.readDerivation tgWithGlobalTunServiceConfig.ExecStartPre;
  tgWithGlobalTunBypassDown = generated.readDerivation tgWithGlobalTunServiceConfig.ExecStopPost;
  tgWithGlobalTunRules = mkRoutingRules tgWithGlobalTun;

  tgWithGlobalTproxy = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy.tproxy.enable = true;
        tgWsProxy = {
          enable = true;
          secretFile = "/run/secrets/tg-ws-proxy";
        };
      };
    }
  ];
  tgWithGlobalTproxyNft = mkTProxyNftRules tgWithGlobalTproxy;

  invalidTgWsProxyAssertions = mkFailingAssertions mkBadFixture [
    [
      {
        services.proxy-suite = {
          proxy.tproxy.enable = true;
          tgWsProxy = {
            enable = true;
            secretFile = "/run/secrets/tg-ws-proxy";
            routingMark = 1;
          };
        };
      }
    ]
    [
      {
        services.proxy-suite.tgWsProxy = {
          enable = true;
          secretFile = "/run/secrets/tg-ws-proxy";
          bufKb = 3;
        };
      }
    ]
    [
      {
        services.proxy-suite.tgWsProxy = {
          enable = true;
          secretFile = "/run/secrets/tg-ws-proxy";
          poolSize = -1;
        };
      }
    ]
    [
      {
        services.proxy-suite.tgWsProxy = {
          enable = true;
          secretFile = "/run/secrets/tg-ws-proxy";
          logBackups = 0;
        };
      }
    ]
  ];
in
{
  inherit
    tgSecretFile
    tgSecretFileService
    tgAllOptionsStartScript
    tgWithGlobalTunServiceConfig
    tgWithGlobalTunBypassUp
    tgWithGlobalTunBypassDown
    tgWithGlobalTunRules
    tgWithGlobalTproxyNft
    invalidTgWsProxyAssertions
    ;
}
