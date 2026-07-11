{
  pkgs,
  evalProxySuite,
  baseModule,
  mkRouteModeRules,
  shellValueByPrefix,
  minimalProxyCtlWrapper,
  minimalProxyCtlScript,
}:

let
  generated = import ./read-generated.nix;

  routeModeFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.routing = {
        proxy = {
          domains = [ "proxy.example" ];
          geosites = [ "google" ];
        };
        direct.domains = [ "direct.example" ];
        block.domains = [ "block.example" ];
        rules = [
          {
            outbound = "direct";
            domains = [ "custom-direct.example" ];
          }
          {
            outbound = "primary";
            domains = [ "custom-proxy.example" ];
          }
          {
            outbound = "block";
            domains = [ "custom-block.example" ];
          }
        ];
      };
    }
  ];
  routeModeStartScript = generated.readDerivation (
    routeModeFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );
  routeModeBackendJqFilter =
    import ../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix
      {
        pureXrayEnabled = false;
        selectionMode = routeModeFixture.config.services.proxy-suite.proxy.selection;
      };
  routeModeSetterScript = generated.readDerivation (
    (import ../../modules/proxy-suite/service/control-scripts.nix {
      inherit pkgs;
      lib = pkgs.lib;
      proxyCfg = routeModeFixture.config.services.proxy-suite.proxy;
      routeModeStateFile = "/run/proxy-suite/route-mode";
      subscriptionCacheDir = "/var/lib/proxy-suite/subscriptions/sing-box";
      subscriptionCacheHelpersBlock = "";
      mkSubscriptionFetchBlock = _: "";
    }).setRouteModeScript
  );
  routeModeRules = mkRouteModeRules routeModeFixture;
in
{
  assertions = [
    # proxy-ctl wrapper exports the volatile state file and baseline default.
    (
      assert
        shellValueByPrefix minimalProxyCtlWrapper "export ROUTE_MODE_STATE_FILE="
        == "/run/proxy-suite/route-mode";
      assert shellValueByPrefix minimalProxyCtlWrapper "export DEFAULT_ROUTE_MODE=" == "blacklist";
      true
    )

    # proxy-ctl help/status exposes default plus the explicit route modes.
    (
      assert pkgs.lib.hasInfix "route-mode default|whitelist|blacklist|all-proxy|all-bypass|status"
        minimalProxyCtlScript;
      assert pkgs.lib.hasInfix ''printf 'route_mode=%s\n' "$(_route_mode_current)"''
        minimalProxyCtlScript;
      assert pkgs.lib.hasInfix ''printf 'default_route_mode=%s\n' "$(_route_mode_default)"''
        minimalProxyCtlScript;
      assert pkgs.lib.hasInfix ''systemctl start "proxy-suite-route-mode@''${action}.service"''
        minimalProxyCtlScript;
      true
    )

    # The socks start script includes every override branch and uses volatile state.
    (
      assert pkgs.lib.hasInfix ''ROUTE_MODE_STATE_FILE="/run/proxy-suite/route-mode"''
        routeModeStartScript;
      assert pkgs.lib.hasInfix "BACKEND_JQ_FILTER=" routeModeStartScript;
      assert pkgs.lib.hasInfix ''-f "$BACKEND_JQ_FILTER"'' routeModeStartScript;
      assert pkgs.lib.hasInfix "all-proxy)" routeModeStartScript;
      assert pkgs.lib.hasInfix "all-bypass)" routeModeStartScript;
      assert pkgs.lib.hasInfix ".route.rules = (sing_box_preserved_rules + $route_rules)"
        routeModeBackendJqFilter;
      assert pkgs.lib.hasInfix ".dns.rules = []" routeModeBackendJqFilter;
      true
    )

    # Grouped routing metadata preserves custom rule categories and order.
    (
      assert builtins.length routeModeRules.custom == 3;
      assert (builtins.elemAt routeModeRules.custom 0).category == "direct";
      assert (builtins.elemAt routeModeRules.custom 1).category == "proxy";
      assert (builtins.elemAt routeModeRules.custom 2).category == "block";
      true
    )

    # Setter unit is present and writes into /run.
    (
      let
        setterSvc = routeModeFixture.config.systemd.services."proxy-suite-route-mode@";
      in
      assert !(setterSvc.serviceConfig ? RuntimeDirectory);
      assert pkgs.lib.hasInfix "/run/proxy-suite/route-mode" routeModeSetterScript;
      assert pkgs.lib.hasInfix "default)" routeModeSetterScript;
      assert pkgs.lib.hasInfix "all-proxy)" routeModeSetterScript;
      assert pkgs.lib.hasInfix "all-bypass)" routeModeSetterScript;
      true
    )
  ];
}
