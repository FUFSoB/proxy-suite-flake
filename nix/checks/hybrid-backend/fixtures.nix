{
  evalProxySuite,
  mkTProxyConfig,
  mkTunConfig,
  shellValueByPrefix,
}:

let
  generated = import ../read-generated.nix;

  hybridModule = {
    system.stateVersion = "26.05";
    services.proxy-suite = {
      enable = true;
      proxy = {
        enable = true;
        singBox.enable = true;
        xray.enable = true;
        selection = "selector";
        outbounds = [
          {
            tag = "primary";
            url = "vless://uuid@example.com:443?type=tcp&security=reality&pbk=pubkey&fp=qq&sni=last.fm&sid=8a54&spx=%2F-%2Fen%2Fgp%2Fbestsellers&flow=xtls-rprx-vision&encryption=none";
          }
          {
            tag = "xray-only";
            url = "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fx";
          }
        ];
        tproxy.enable = true;
        tun.enable = true;
        tun.perApp.enable = true;
      };
    };
  };
  hybridFixture = evalProxySuite [ hybridModule ];
  hybridTproxyConfig = mkTProxyConfig hybridFixture;
  hybridTunConfig = mkTunConfig hybridFixture;
  hybridStartScript = generated.readDerivation (
    hybridFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );
  hybridTunStartScript = generated.readDerivation (
    hybridFixture.config.systemd.services."proxy-suite-tun".serviceConfig.ExecStart
  );
  hybridPerAppTunStartScript = generated.readDerivation (
    hybridFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig.ExecStart
  );
  hybridBackendJqFilter =
    import ../../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix
      {
        pureXrayEnabled = false;
        selectionMode = hybridFixture.config.services.proxy-suite.proxy.selection;
      };

  hybridXrayRawFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
          xray.enable = true;
          outbounds = [
            {
              tag = "raw-xray";
              xrayJson = {
                protocol = "freedom";
                settings = { };
              };
            }
          ];
        };
      };
    }
  ];
  hybridXrayRawStartScript = generated.readDerivation (
    hybridXrayRawFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  hybridSubscriptionFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
          xray.enable = true;
          subscriptions = [
            {
              tag = "community";
              url = "https://example.com/hybrid-sub";
            }
          ];
          selection = "selector";
        };
      };
    }
  ];
  hybridSubscriptionStartScript = generated.readDerivation (
    hybridSubscriptionFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );
  hybridSubscriptionUpdateScript = generated.readDerivation (
    hybridSubscriptionFixture.config.systemd.services."proxy-suite-subscription-update".serviceConfig.ExecStart
  );
in
{
  inherit
    hybridBackendJqFilter
    hybridFixture
    hybridPerAppTunStartScript
    hybridStartScript
    hybridSubscriptionStartScript
    hybridSubscriptionUpdateScript
    hybridTproxyConfig
    hybridTunConfig
    hybridTunStartScript
    hybridXrayRawStartScript
    ;
}
