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
    # A oneshot left active would swallow every later timer run.
    (
      assert
        !subscriptionOnlyFixture.config.systemd.services."proxy-suite-subscription-update".serviceConfig.RemainAfterExit;
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

    # selection=first puts "proxy" in front of the pinned outbound - or the first one,
    # absent a pin - at start, keeping every tag for rules that name one.
    (
      assert pkgs.lib.hasInfix ''PROXY_TAG="$PINNED_OUTBOUND"'' subscriptionFirstSelectionStartScript;
      assert pkgs.lib.hasInfix ''[{type:"selector",tag:"proxy",outbounds:[$t],default:$t}] + .''
        subscriptionFirstSelectionStartScript;
      true
    )

    # The pin is read from state, and one that names nothing is dropped.
    (
      assert pkgs.lib.hasInfix "/var/lib/proxy-suite/pinned-outbound" subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "pinned outbound '$PINNED_OUTBOUND' is not available"
        subscriptionOnlyStartScript;
      true
    )

    # proxy-ctl reads the inventory the start script leaves behind.
    (
      assert pkgs.lib.hasInfix ''> "$RUNTIME_DIR/outbounds.json"'' subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix ''chmod 644 "$RUNTIME_DIR/outbounds.json"'' subscriptionOnlyStartScript;
      true
    )

    # Outbounds added at runtime share the URL path with the declared ones.
    (
      assert pkgs.lib.hasInfix "_proxy_suite_runtime_outbounds" subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "_proxy_suite_add_url_outbound" subscriptionWithStaticStartScript;
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

    # Cache paths are built from the tag argument, so a tag never reaches the
    # filename shell-quoted.
    (
      assert pkgs.lib.hasInfix ''SUB_CACHE_DIR="/var/lib/proxy-suite/subscriptions/sing-box"''
        subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix ''cache="$SUB_CACHE_DIR/$1.json"'' subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix ''cache="$SUB_CACHE_DIR/$1.json"'' subscriptionOnlyUpdateScript;
      assert !(pkgs.lib.hasInfix "subscriptions/'community'.json" subscriptionOnlyStartScript);
      assert !(pkgs.lib.hasInfix "subscriptions/'community'.json" subscriptionOnlyUpdateScript);
      true
    )

    # Declared and runtime subscriptions both go through the same two entry
    # points, with the tag passed raw.
    (
      assert pkgs.lib.hasInfix "_proxy_suite_load_subscription community " subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "_proxy_suite_fetch_subscription community " subscriptionOnlyUpdateScript;
      assert pkgs.lib.hasInfix ''_proxy_suite_load_subscription "$RUNTIME_SUB_TAG"''
        subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix ''_proxy_suite_fetch_subscription "$RUNTIME_SUB_TAG"''
        subscriptionOnlyUpdateScript;
      true
    )

    # The fetcher's output must land in the cache, not after a stray newline.
    (
      assert pkgs.lib.hasInfix ''--tag-prefix "$tag" --links-out "$links.tmp" > "$cache.tmp"''
        subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix ''--tag-prefix "$tag" --links-out "$links.tmp" > "$cache.tmp"''
        subscriptionOnlyUpdateScript;
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

    # The update service and timer exist whenever the proxy does, because a
    # subscription can be added at runtime after the rebuild.
    (
      assert minimal.config.systemd.services ? "proxy-suite-subscription-update";
      true
    )
    (
      assert minimal.config.systemd.timers ? "proxy-suite-subscription-update";
      true
    )

    # Runtime spool dirs are root-only unless userControl grants outbounds (see user-control.nix).
    (
      assert builtins.any (
        rule: builtins.match "d /var/lib/proxy-suite/outbounds\\.d 0700 root root -" rule != null
      ) minimal.config.systemd.tmpfiles.rules;
      assert builtins.any (
        rule: builtins.match "d /var/lib/proxy-suite/subscriptions\\.d 0700 root root -" rule != null
      ) minimal.config.systemd.tmpfiles.rules;
      true
    )

    # Both kinds of subscription go through one loader, and the runtime spool is
    # walked at start and on refresh.
    (
      assert pkgs.lib.hasInfix "_proxy_suite_load_subscription" subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "_proxy_suite_runtime_subscriptions" subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "_proxy_suite_runtime_subscriptions" subscriptionOnlyUpdateScript;
      true
    )
  ];
}
