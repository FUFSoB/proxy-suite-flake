{
  checkLib,
  pkgs,
  evalProxySuite,
  mkTProxyConfig,
  mkTunConfig,
  shellValueByPrefix,
}:

let
  inherit (checkLib) startScript unitScript;
  generated = import ../read-generated.nix;

  hybridModule = {
    system.stateVersion = "26.05";
    services.proxy-suite = {
      enable = true;
      proxy = {
        enable = true;
        backend = "hybrid";
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
      };
      perAppRouting.tun.enable = true;
    };
  };
  hybridFixture = evalProxySuite [ hybridModule ];
  hybridTproxyConfig = mkTProxyConfig hybridFixture;
  hybridTunConfig = mkTunConfig hybridFixture;
  hybridStartScript = startScript hybridFixture;
  hybridTunStartScript = unitScript hybridFixture "proxy-suite-tun";
  hybridPerAppTunStartScript = unitScript hybridFixture "proxy-suite-per-app-tun";
  hybridBackendJqFilter =
    import ../../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix
      {
        lib = pkgs.lib;
        proxyInboundsGuardPrivate = false;
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
          backend = "hybrid";
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
  hybridXrayRawStartScript = startScript hybridXrayRawFixture;

  hybridSubscriptionFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          backend = "hybrid";
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
  hybridSubscriptionStartScript = startScript hybridSubscriptionFixture;
  hybridSubscriptionUpdateScript = unitScript hybridSubscriptionFixture "proxy-suite-subscription-update";
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
