{
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  minimalProxyCtlScript,
}:

let
  generated = import ./read-generated.nix;

  perAppRoutingProxychainsFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.perAppRouting = {
        enable = true;
        proxychains.enable = true;
        profiles = [
          {
            name = "steam-browser";
            route = "proxychains";
          }
          {
            name = "native-direct";
            route = "direct";
          }
        ];
      };
    }
  ];
  perAppRoutingProxychains = mkProxyCtlDerived perAppRoutingProxychainsFixture;
  perAppRoutingProxychainsWrapper = perAppRoutingProxychains.wrapper;
  perAppRoutingProxychainsScript = perAppRoutingProxychains.script;
  perAppRoutingProxychainsProfiles = perAppRoutingProxychains.profiles;
  perAppRoutingProxychainsConfig = generated.readDerivation perAppRoutingProxychains.proxychainsConfigFile;

  perAppRoutingDefaultProfilesFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.perAppRouting = {
        enable = true;
        createDefaultProfiles = true;
        proxychains.enable = true;
      };
    }
  ];
  perAppRoutingDefaultProfiles = (mkProxyCtlDerived perAppRoutingDefaultProfilesFixture).profiles;

  perAppRoutingNoDefaultProfilesFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy = {
          tun.perApp.enable = true;
          tproxy.perApp.enable = true;
        };
        zapret = {
          enable = true;
          perApp.enable = true;
        };
        perAppRouting = {
          enable = true;
          createDefaultProfiles = false;
          proxychains.enable = true;
        };
      };
    }
  ];
  perAppRoutingNoDefaultProfiles = (mkProxyCtlDerived perAppRoutingNoDefaultProfilesFixture).profiles;
in
{
  assertions = [
    # -- perAppRouting: proxychains/direct profile config is accepted --
    (
      assert perAppRoutingProxychainsFixture.config.services.proxy-suite.perAppRouting.enable;
      true
    )
    (
      assert
        builtins.length perAppRoutingProxychainsFixture.config.services.proxy-suite.perAppRouting.profiles
        == 2;
      true
    )
    (
      assert builtins.length perAppRoutingProxychainsProfiles == 2;
      true
    )

    # -- perAppRouting: createDefaultProfiles injects curated proxychains profile --
    (
      assert builtins.length perAppRoutingDefaultProfiles == 1;
      assert (builtins.head perAppRoutingDefaultProfiles).name == "proxychains";
      assert (builtins.head perAppRoutingDefaultProfiles).route == "proxychains";
      true
    )

    # -- perAppRouting: createDefaultProfiles = false injects no curated profiles --
    (
      assert builtins.length perAppRoutingNoDefaultProfiles == 0;
      true
    )

    # -- perAppRouting: proxy-ctl script embeds wrap/apps commands --
    (
      assert pkgs.lib.hasInfix "help)" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "show this help message" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "enable/disable the proxy backend stack" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "restart active global proxy-suite services"
        perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "wrap <profile> -- <cmd>" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix "apps" perAppRoutingProxychainsScript;
      true
    )

    # -- perAppRouting: proxychains config is quiet and points at local SOCKS listener --
    (
      assert pkgs.lib.hasInfix "quiet_mode" perAppRoutingProxychainsConfig;
      assert pkgs.lib.hasInfix "proxy_dns" perAppRoutingProxychainsConfig;
      assert pkgs.lib.hasInfix "socks5 127.0.0.1 1080" perAppRoutingProxychainsConfig;
      true
    )

    # -- proxy-ctl: restart skips services that are not present in zapret-only or tg-only builds --
    (
      assert pkgs.lib.hasInfix "if _svc_exists proxy-suite-socks; then" minimalProxyCtlScript;
      assert pkgs.lib.hasInfix "_svc_exists \"$svc\" && _svc_active \"$svc\"" minimalProxyCtlScript;
      assert pkgs.lib.hasInfix "proxy-suite-tg-ws-proxy" minimalProxyCtlScript;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches through proxychains4 --
    (
      assert pkgs.lib.hasInfix "export PROXYCHAINS_QUIET_ARG=-q" perAppRoutingProxychainsScript;
      assert pkgs.lib.hasInfix
        "exec proxychains4 $PROXYCHAINS_QUIET_ARG -f \"$PROXYCHAINS_CONFIG\" \"$@\""
        perAppRoutingProxychainsScript;
      true
    )
  ];
}
