{
  checkLib,
  evalProxySuite,
  mkProxyCtlDerived,
}:

let
  inherit (checkLib) startScript unitScript;
  generated = import ../read-generated.nix;

  subscriptionOnlyFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          backend = "sing-box";
          subscriptions = [
            {
              tag = "community";
              url = "https://example.com/sub/token";
            }
          ];
        };
      };
    }
  ];
  subscriptionOnlyProxyCtl = mkProxyCtlDerived subscriptionOnlyFixture;
  subscriptionOnlyScript = subscriptionOnlyProxyCtl.script;
  subscriptionOnlyTags = subscriptionOnlyProxyCtl.subscriptionTags;
  subscriptionOnlyStartScript =
    generated.readDerivation
      subscriptionOnlyFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart;
  subscriptionOnlyUpdateScript =
    generated.readDerivation
      subscriptionOnlyFixture.config.systemd.services."proxy-suite-subscription-update".serviceConfig.ExecStart;

  subscriptionWithStaticFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          backend = "sing-box";
          outbounds = [
            {
              tag = "own-vps";
              url = "http://proxy.example.com:8080";
            }
          ];
          subscriptions = [
            {
              tag = "backup";
              url = "https://example.com/sub/token";
            }
          ];
          selection = "urltest";
          subscriptionUpdateInterval = "6h";
        };
      };
    }
  ];
  subscriptionWithStaticStartScript = startScript subscriptionWithStaticFixture;

  subscriptionFirstSelectionFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          backend = "sing-box";
          subscriptions = [
            {
              tag = "community";
              url = "https://example.com/sub/token";
            }
          ];
          selection = "first";
        };
      };
    }
  ];
  subscriptionFirstSelectionStartScript = startScript subscriptionFirstSelectionFixture;

  subscriptionPerAppTunFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          backend = "sing-box";
          subscriptions = [
            {
              tag = "community";
              url = "https://example.com/sub/token";
            }
          ];
        };
        perAppRouting = {
          enable = true;
          tun.enable = true;
        };
      };
    }
  ];
  subscriptionPerAppTunUpdateScript = unitScript subscriptionPerAppTunFixture "proxy-suite-subscription-update";
in
{
  inherit
    subscriptionOnlyFixture
    subscriptionOnlyScript
    subscriptionOnlyTags
    subscriptionOnlyStartScript
    subscriptionOnlyUpdateScript
    subscriptionWithStaticFixture
    subscriptionWithStaticStartScript
    subscriptionFirstSelectionFixture
    subscriptionFirstSelectionStartScript
    subscriptionPerAppTunUpdateScript
    ;
}
