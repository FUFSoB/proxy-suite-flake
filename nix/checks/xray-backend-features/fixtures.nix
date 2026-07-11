{
  pkgs,
  evalProxySuite,
  mkTProxyConfig,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
}:

let
  generated = import ../read-generated.nix;
  rawOutboundJson =
    (import ../../../modules/proxy-suite/service/script-blocks/outbounds.nix {
      lib = pkgs.lib;
      inherit pkgs;
      pureXrayEnabled = true;
      singBoxCfg = null;
      proxyCfg = null;
      hybridEnabled = null;
      collapseNamedOutbounds = null;
      selectionMode = null;
      backend = null;
      backendArg = null;
      xraySidecarRoutingMark = null;
      jq = null;
      python3 = null;
      parserScriptsPythonPath = null;
      buildOutboundPy = null;
      mkSubscriptionBlock = null;
    }).rawOutboundJson;

  xrayRawStreamDefinition = {
    tag = "raw-stream";
    xrayJson = {
      protocol = "vless";
      settings = {
        address = "example.com";
        port = 443;
        id = "00000000-0000-0000-0000-000000000000";
        encryption = "none";
      };
      streamSettings = {
        network = "ws";
        security = "tls";
        tlsSettings.serverName = "cdn.example.com";
        wsSettings.path = "/ws";
        sockopt.tcpFastOpen = true;
      };
    };
  };

  xraySubscriptionFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          xray.enable = true;
          subscriptions = [
            {
              tag = "xray-sub";
              url = "https://example.com/xray-sub";
            }
          ];
        };
      };
    }
  ];
  xraySubscriptionStartScript = generated.readDerivation (
    xraySubscriptionFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  xrayRawStreamFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          xray.enable = true;
          outbounds = [ xrayRawStreamDefinition ];
        };
      };
    }
  ];
  xrayRawStreamOutbound =
    rawOutboundJson (builtins.head xrayRawStreamFixture.config.services.proxy-suite.proxy.outbounds)
      "proxy"
      2;

  xrayDnsTcpConfig = mkTProxyConfig (evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          xray.enable = true;
          dns.local = {
            type = "tcp";
            address = "9.9.9.9";
            port = 5353;
          };
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      };
    }
  ]);

  invalidXrayFeatureAssertions = mkFailingAssertions mkBadProxySuiteFixture [
    {
      enable = true;
      proxy = {
        enable = true;
        xray.enable = true;
        dns.remote = {
          type = "tls";
          address = "1.1.1.1";
          port = 853;
        };
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    }
    {
      enable = true;
      proxy = {
        enable = true;
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    }
    {
      enable = true;
      proxy = {
        enable = true;
        xray.enable = true;
        selection = "selector";
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    }
    {
      enable = true;
      proxy = {
        enable = true;
        xray.enable = true;
        outbounds = [
          {
            tag = "raw";
            singBoxJson = {
              type = "direct";
            };
          }
        ];
      };
    }
    {
      enable = true;
      proxy = {
        enable = true;
        singBox.enable = true;
        outbounds = [
          {
            tag = "raw";
            xrayJson = {
              protocol = "freedom";
              settings = { };
            };
          }
        ];
      };
    }
  ];
in
{
  inherit
    xraySubscriptionStartScript
    xrayRawStreamOutbound
    xrayDnsTcpConfig
    invalidXrayFeatureAssertions
    ;
}
