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
        listener.address = "127.0.0.1";
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
        listener.port = 2443;
        listener.address = "0.0.0.0";
        secretFile = "/run/secrets/tg-ws-proxy";
        log.verbose = true;
        log.file = "/var/log/tg-ws-proxy.log";
        log.maxSizeMiB = 2.5;
        log.keep = 3;
        bufferKiB = 512;
        poolSize = 8;
        cloudflare.domains = [
          "cdn.example.com"
          "edge.example.net"
        ];
        cloudflare.workerDomains = [ "worker.example.com" ];
        cloudflare.fallback = false;
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
            fwmark = 1;
          };
        };
      }
    ]
    [
      {
        services.proxy-suite.tgWsProxy = {
          enable = true;
          secretFile = "/run/secrets/tg-ws-proxy";
          bufferKiB = 3;
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
          log.keep = 0;
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
