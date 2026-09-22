{
  evalProxySuite,
  baseModule,
  mkBadFixture,
  mkFailingAssertions,
  mkTunConfig,
  mkTProxyConfig,
  mkTProxyNftRules,
  mkNftRules,
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
          backend = "sing-box";
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
  tproxyManualConfig = mkTProxyConfig tproxyManualFixture;
  tproxyManualNftRules = mkTProxyNftRules tproxyManualFixture;

  tproxyLanFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.tproxy = {
        enable = true;
        lanInterfaces = [ "br0" ];
      };
    }
  ];
  tproxyLanNftRules = mkTProxyNftRules tproxyLanFixture;
  tproxyLanStartScript =
    generated.readDerivation
      tproxyLanFixture.config.systemd.services."proxy-suite-tproxy".serviceConfig.ExecStart;

  killSwitchFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.killSwitch.enable = true;
      services.proxy-suite.proxy = {
        tun.enable = true;
        tproxy = {
          enable = true;
          lanInterfaces = [ "br0" ];
        };
      };
    }
  ];
  killSwitchNftRules = mkNftRules killSwitchFixture "killSwitchRulesFile";

  # A global AmneziaWG profile alone, no proxy.
  awgKillSwitchFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        killSwitch.enable = true;
        amneziaWg = {
          enable = true;
          kernelModulePackage = null;
          profiles.home.configFile = "/run/secrets/awg.conf";
        };
      };
    }
  ];
  awgKillSwitchNftRules = mkNftRules awgKillSwitchFixture "killSwitchRulesFile";
  awgKillSwitchPrepare = generated.readDerivation (
    builtins.head awgKillSwitchFixture.config.systemd.services.proxy-suite-awg-home.serviceConfig.ExecStartPre
  );

  tproxyIPv4OnlyFixture = evalProxySuite [
    baseModule
    {
      networking.enableIPv6 = false;
      services.proxy-suite.proxy = {
        tproxy.enable = true;
        tun.enable = true;
      };
      services.proxy-suite.perAppRouting = {
        enable = true;
        tun.enable = true;
      };
    }
  ];
  tproxyIPv4OnlyStartScript =
    generated.readDerivation
      tproxyIPv4OnlyFixture.config.systemd.services."proxy-suite-tproxy".serviceConfig.ExecStart;
  tproxyIPv4OnlyConfig = mkTProxyConfig tproxyIPv4OnlyFixture;
  tproxyIPv4OnlyNftRules = mkTProxyNftRules tproxyIPv4OnlyFixture;
  ipv4OnlyTunConfig = mkTunConfig tproxyIPv4OnlyFixture;
  ipv4OnlyPerAppTunUpScript =
    generated.readDerivation
      tproxyIPv4OnlyFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig.ExecStartPost;

  # XRay's TUN configures IPv6 itself: with it off, its up script must not touch IPv6 addresses.
  xrayIPv4OnlyFixture = evalProxySuite [
    baseModule
    (
      { lib, ... }:
      {
        networking.enableIPv6 = false;
        services.proxy-suite.proxy = {
          backend = lib.mkForce "xray";
          tun.enable = true;
        };
      }
    )
  ];
  xrayIPv4OnlyTunConfig = mkTunConfig xrayIPv4OnlyFixture;
  xrayIPv4OnlyTunUpScript =
    generated.readDerivation
      xrayIPv4OnlyFixture.config.systemd.services."proxy-suite-tun".serviceConfig.ExecStartPost;

  tproxyAutostartFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy = {
        tproxy.enable = true;
        autostart = "tproxy";
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
      services.proxy-suite.proxy = {
        tun.enable = true;
        autostart = "tun";
      };
    }
  ];

  invalidGlobalProxyModeAssertions = mkFailingAssertions mkBadFixture [
    # TUN and TProxy can no longer both autostart: proxy.autostart holds one mode.

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
    # The kill switch guards a global mode, and a gateway needs TProxy.
    [ { services.proxy-suite.killSwitch.enable = true; } ]
    [ { services.proxy-suite.proxy.tproxy.lanInterfaces = [ "br0" ]; } ]
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
    tproxyManualConfig
    tproxyManualNftRules
    tproxyLanFixture
    tproxyLanNftRules
    tproxyLanStartScript
    killSwitchFixture
    killSwitchNftRules
    awgKillSwitchFixture
    awgKillSwitchNftRules
    awgKillSwitchPrepare
    tproxyIPv4OnlyStartScript
    tproxyIPv4OnlyConfig
    tproxyIPv4OnlyNftRules
    ipv4OnlyTunConfig
    ipv4OnlyPerAppTunUpScript
    xrayIPv4OnlyTunConfig
    xrayIPv4OnlyTunUpScript
    tproxyWithFirewall
    tunAutostartFixture
    tunCleanupScript
    tunDefaultConfig
    tunManualFixture
    tunServiceConfig
    ;
}
