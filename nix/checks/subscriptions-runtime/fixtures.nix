{
  evalProxySuite,
  mkProxyCtlDerived,
}:

let
  generated = import ../read-generated.nix;

  subscriptionOnlyFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
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
          singBox.enable = true;
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
  subscriptionWithStaticStartScript = generated.readDerivation (
    subscriptionWithStaticFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  subscriptionFirstSelectionFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
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
  subscriptionFirstSelectionStartScript = generated.readDerivation (
    subscriptionFirstSelectionFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  subscriptionPerAppTunFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
          subscriptions = [
            {
              tag = "community";
              url = "https://example.com/sub/token";
            }
          ];
          tun.perApp.enable = true;
        };
        perAppRouting.enable = true;
      };
    }
  ];
  subscriptionPerAppTunUpdateScript = generated.readDerivation (
    subscriptionPerAppTunFixture.config.systemd.services."proxy-suite-subscription-update".serviceConfig.ExecStart
  );
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
