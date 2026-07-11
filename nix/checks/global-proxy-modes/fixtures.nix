{
  evalProxySuite,
  baseModule,
  mkBadFixture,
  mkFailingAssertions,
  mkTunConfig,
}:

let
  generated = import ../read-generated.nix;

  tproxyWithFirewall = evalProxySuite [
    {
      system.stateVersion = "26.05";
      networking.firewall.enable = true;
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
          tproxy.enable = true;
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      };
    }
  ];

  tproxyManualFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.tproxy.enable = true;
    }
  ];
  tproxyManualServiceConfig =
    tproxyManualFixture.config.systemd.services."proxy-suite-tproxy".serviceConfig;
  tproxyManualStartScript = generated.readDerivation tproxyManualServiceConfig.ExecStart;
  tproxyManualStopScript = generated.readDerivation tproxyManualServiceConfig.ExecStop;

  tproxyAutostartFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.tproxy = {
        enable = true;
        autostart = true;
      };
    }
  ];

  tunManualFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.tun.enable = true;
    }
  ];

  tunAutostartFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.tun = {
        enable = true;
        autostart = true;
      };
    }
  ];

  invalidGlobalProxyModeAssertions = mkFailingAssertions mkBadFixture [
    # TUN and TProxy cannot both autostart globally.
    [
      {
        services.proxy-suite.proxy = {
          tproxy = {
            enable = true;
            autostart = true;
          };
          tun = {
            enable = true;
            autostart = true;
          };
        };
      }
    ]

    # Transparent proxy backends require proxy.enable.
    [
      {
        services.proxy-suite.proxy = {
          enable = false;
          tun.enable = true;
        };
      }
    ]
    [
      {
        services.proxy-suite.proxy = {
          enable = false;
          tproxy.enable = true;
        };
      }
    ]
  ];

  tunDefaultConfig = mkTunConfig tunManualFixture;
  tunServiceConfig = tunManualFixture.config.systemd.services."proxy-suite-tun".serviceConfig;
  tunCleanupScript = generated.readDerivation tunServiceConfig.ExecStopPost;
in
{
  inherit
    invalidGlobalProxyModeAssertions
    tproxyAutostartFixture
    tproxyManualFixture
    tproxyManualStartScript
    tproxyManualStopScript
    tproxyWithFirewall
    tunAutostartFixture
    tunCleanupScript
    tunDefaultConfig
    tunManualFixture
    tunServiceConfig
    ;
}
