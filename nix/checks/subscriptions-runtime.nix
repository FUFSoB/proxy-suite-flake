{
  pkgs,
  evalProxySuite,
  mkProxyCtlDerived,
  minimal,
}:

let
  fixtures = import ./subscriptions-runtime/fixtures.nix {
    inherit
      evalProxySuite
      mkProxyCtlDerived
      ;
  };
  inherit (fixtures)
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
in
{
  assertions = [
    # Basic config is accepted.
    (
      assert subscriptionOnlyFixture.config.services.proxy-suite.proxy.subscriptions != [ ];
      true
    )

    # Wrapper exposes tags through a JSON file, not shell word splitting.
    (
      assert subscriptionOnlyTags == [ "community" ];
      assert pkgs.lib.hasInfix "export SUB_TAGS_FILE=" subscriptionOnlyScript;
      assert !(pkgs.lib.hasInfix "SUB_TAGS_RAW" subscriptionOnlyScript);
      true
    )

    # Update service and timer are created when subscriptions are configured.
    (
      assert subscriptionOnlyFixture.config.systemd.services ? "proxy-suite-subscription-update";
      true
    )
    (
      assert subscriptionOnlyFixture.config.systemd.timers ? "proxy-suite-subscription-update";
      true
    )

    # StateDirectory is set on the socks service.
    (
      assert
        subscriptionOnlyFixture.config.systemd.services."proxy-suite-socks".serviceConfig.StateDirectory
        == "proxy-suite";
      true
    )

    # Custom update interval flows through to the timer.
    (
      assert
        subscriptionWithStaticFixture.config.systemd.timers."proxy-suite-subscription-update".timerConfig.OnUnitActiveSec
        == "6h";
      true
    )

    # selection=first renames the first subscription outbound to "proxy".
    (
      assert builtins.match ".*proxy.*" subscriptionFirstSelectionStartScript != null;
      true
    )

    # Runtime parser imports are available in socks and update scripts.
    (
      assert
        builtins.match ".*PYTHONPATH=.*build-outbound\\.py.*" subscriptionWithStaticStartScript != null;
      true
    )
    (
      assert
        builtins.match ".*PYTHONPATH=.*fetch-subscription\\.py.*" subscriptionOnlyUpdateScript != null;
      true
    )

    # Generated cache paths use the raw validated tag, not shell-escaped quotes.
    (
      assert pkgs.lib.hasInfix ''CACHE_FILE="/var/lib/proxy-suite/subscriptions/sing-box/community.json"''
        subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "/var/lib/proxy-suite/subscriptions/sing-box/community.json.tmp"
        subscriptionOnlyUpdateScript;
      assert !(pkgs.lib.hasInfix "subscriptions/'community'.json" subscriptionOnlyStartScript);
      assert !(pkgs.lib.hasInfix "subscriptions/'community'.json" subscriptionOnlyUpdateScript);
      true
    )

    # Invalid cache files are ignored and refreshed.
    (
      assert pkgs.lib.hasInfix "_proxy_suite_valid_subscription_cache()" subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "_proxy_suite_drop_invalid_subscription_cache" subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "removed invalid subscription cache" subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "produced an invalid cache" subscriptionOnlyUpdateScript;
      true
    )

    # Refresh restarts only active sing-box units, including per-app TUN when present.
    (
      assert pkgs.lib.hasInfix "is-active --quiet proxy-suite-socks" subscriptionOnlyUpdateScript;
      assert pkgs.lib.hasInfix "restart proxy-suite-socks" subscriptionOnlyUpdateScript;
      assert pkgs.lib.hasInfix "is-active --quiet proxy-suite-tun" subscriptionOnlyUpdateScript;
      assert !(pkgs.lib.hasInfix "SOCKS_WAS_ACTIVE" subscriptionOnlyUpdateScript);
      true
    )
    (
      assert pkgs.lib.hasInfix "is-active --quiet proxy-suite-per-app-tun"
        subscriptionPerAppTunUpdateScript;
      assert pkgs.lib.hasInfix "restart proxy-suite-per-app-tun" subscriptionPerAppTunUpdateScript;
      assert !(pkgs.lib.hasInfix "PER_APP_TUN_WAS_ACTIVE" subscriptionPerAppTunUpdateScript);
      true
    )

    # No update service or timer exists without subscriptions.
    (
      assert !(minimal.config.systemd.services ? "proxy-suite-subscription-update");
      true
    )
    (
      assert !(minimal.config.systemd.timers ? "proxy-suite-subscription-update");
      true
    )
  ];
}
