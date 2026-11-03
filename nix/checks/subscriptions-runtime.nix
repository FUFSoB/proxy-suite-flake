{
  checkLib,
  pkgs,
  evalProxySuite,
  mkProxyCtlDerived,
  minimal,
}:

let
  inherit (checkLib) ok;
  fixtures = import ./subscriptions-runtime/fixtures.nix {
    inherit checkLib;
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
    (ok (subscriptionOnlyFixture.config.services.proxy-suite.proxy.subscriptions != [ ]))

    # Wrapper exposes tags through a JSON file, not shell word splitting.
    (
      assert subscriptionOnlyTags == [ "community" ];
      assert pkgs.lib.hasInfix "export SUB_TAGS_FILE=" subscriptionOnlyScript;
      assert !(pkgs.lib.hasInfix "SUB_TAGS_RAW" subscriptionOnlyScript);
      true
    )

    # Update service and timer are created when subscriptions are configured.
    (ok (subscriptionOnlyFixture.config.systemd.services ? "proxy-suite-subscription-update"))
    (ok (subscriptionOnlyFixture.config.systemd.timers ? "proxy-suite-subscription-update"))
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

    # The timer looks for subscriptions due hourly (a server may ask for that), sooner when
    # the default interval is shorter, and starts the unit that fetches only those.
    (
      let
        timer =
          subscriptionWithStaticFixture.config.systemd.timers."proxy-suite-subscription-update".timerConfig;
        refresh = subscriptionWithStaticFixture.config.systemd.services."proxy-suite-subscription-refresh";
      in
      assert timer.OnUnitActiveSec == "3600s";
      assert timer.Unit == "proxy-suite-subscription-refresh.service";
      assert pkgs.lib.hasSuffix " due" refresh.serviceConfig.ExecStart;
      assert !refresh.serviceConfig.RemainAfterExit;
      # `proxy subs update`'s unit fetches every one.
      assert
        toString
          subscriptionWithStaticFixture.config.systemd.services."proxy-suite-subscription-update".serviceConfig.ExecStart
        == pkgs.lib.removeSuffix " due" refresh.serviceConfig.ExecStart;
      true
    )
    (
      assert pkgs.lib.hasInfix ''SUB_UPDATE_MODE="''${1:-all}"'' subscriptionOnlyUpdateScript;
      assert pkgs.lib.hasInfix
        "if [ \"$SUB_UPDATE_MODE\" != due ] || _proxy_suite_subscription_due community ''; then"
        subscriptionOnlyUpdateScript;
      # Its own interval, else what the server last asked for, else the 6h default.
      assert pkgs.lib.hasInfix "interval=21600" subscriptionWithStaticStartScript;
      assert pkgs.lib.hasInfix ".updateIntervalHours" subscriptionOnlyUpdateScript;
      assert pkgs.lib.hasInfix "_proxy_suite_prune_subscription_meta" subscriptionOnlyUpdateScript;
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

    # proxy-ctl reads the inventory the start script leaves behind, renamed into place whole.
    (
      assert pkgs.lib.hasInfix ''INVENTORY_TMP="$RUNTIME_DIR/outbounds.json.tmp"''
        subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix ''chmod 644 "$INVENTORY_TMP"'' subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix ''mv "$INVENTORY_TMP" "$RUNTIME_DIR/outbounds.json"''
        subscriptionOnlyStartScript;
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

    # Private servers are kept only for a declared subscription that opts in: the flag rides
    # both entry points to the fetcher; runtime subscriptions and the rest never pass it.
    (
      let
        generated = import ./read-generated.nix;
        fixture = evalProxySuite [
          {
            system.stateVersion = "26.05";
            services.proxy-suite = {
              enable = true;
              proxy = {
                enable = true;
                backend = "sing-box";
                subscriptions = [
                  {
                    tag = "lan";
                    url = "https://sub.lan.example/token";
                    allowPrivateServers = true;
                  }
                  {
                    tag = "community";
                    url = "https://example.com/sub/token";
                  }
                ];
              };
            };
          }
        ];
        unitScript =
          unit: generated.readDerivation fixture.config.systemd.services.${unit}.serviceConfig.ExecStart;
        linesWith =
          infix: script: builtins.filter (pkgs.lib.hasInfix infix) (pkgs.lib.splitString "\n" script);
        flagged = pkgs.lib.hasInfix " --allow-private-servers";
        flaggedOnly =
          call: script:
          builtins.all flagged (linesWith "${call} lan " script)
          && linesWith "${call} lan " script != [ ]
          && !(builtins.any flagged (linesWith "${call} community " script))
          && !(builtins.any flagged (linesWith ''${call} "$RUNTIME_SUB_TAG"'' script));
        start = unitScript "proxy-suite-socks";
        update = unitScript "proxy-suite-subscription-update";
      in
      assert flaggedOnly "_proxy_suite_load_subscription" start;
      assert flaggedOnly "_proxy_suite_fetch_subscription" update;
      assert pkgs.lib.hasInfix ''_proxy_suite_fetch_subscription "$tag" "$src" "''${@:3}"'' start;
      # Both the fetch through the tunnel and the kill switch's direct retry.
      assert pkgs.lib.hasInfix
        ''_proxy_suite_run_fetcher tunnel "$tag" "$src" "$cache_tmp" "$links_tmp" "$meta_tmp" "''${@:3}"''
        update;
      assert pkgs.lib.hasInfix
        ''_proxy_suite_run_fetcher direct "$tag" "$src" "$cache_tmp" "$links_tmp" "$meta_tmp" "''${@:3}"''
        update;
      # Through the tunnel too, the subscription server's answer is not parsed as root.
      assert pkgs.lib.hasInfix
        "setpriv --reuid=proxy-suite-fetch --regid=proxy-suite-fetch --clear-groups"
        update;
      # Runtime ones over https only, unless the admin allows http.
      assert pkgs.lib.hasInfix
        ''_proxy_suite_fetch_subscription "$RUNTIME_SUB_TAG" "$RUNTIME_SUB_SRC" --https-only''
        update;
      true
    )

    # The fetcher's output must land in the cache, not after a stray newline; each fetch in
    # a temporary file of its own, which start scripts running at once do not share.
    (
      assert pkgs.lib.hasInfix
        ''--tag-prefix "$tag" --links-fd 3 --meta-fd 4 "$@" > "$cache_tmp" 3> "$links_tmp" 4> "$meta_tmp"''
        subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix
        ''--tag-prefix "$tag" --links-fd 3 --meta-fd 4 "$@" > "$cache_tmp" 3> "$links_tmp" 4> "$meta_tmp"''
        subscriptionOnlyUpdateScript;
      assert pkgs.lib.hasInfix ''tmp=$(mktemp "$1.XXXXXX")'' subscriptionOnlyUpdateScript;
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

    # So is one fetched with another URL or other fetcher flags: a start drops it and fetches
    # afresh. What a cache was fetched with is kept as a hash, the URL being a secret.
    (
      assert pkgs.lib.hasInfix ''_proxy_suite_drop_stale_subscription_cache "$tag" "$src" "''${@:3}"''
        subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix "has a new URL or fetch settings; dropped its cache"
        subscriptionOnlyStartScript;
      assert pkgs.lib.hasInfix ''_proxy_suite_write_subscription_fingerprint "$tag" "$sum"''
        subscriptionOnlyUpdateScript;
      assert pkgs.lib.hasInfix "/bin/sha256sum" subscriptionOnlyUpdateScript;
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
    # ...and only when a cache changed: the timer fires after every switch, and an unchanged
    # refresh must not cut the proxy's connections.
    (
      assert pkgs.lib.hasInfix ''if [ "$SUB_CACHE_CHANGED" -eq 1 ]; then'' subscriptionOnlyUpdateScript;
      assert pkgs.lib.hasInfix "/bin/cmp -s" subscriptionOnlyUpdateScript;
      true
    )
    (
      assert pkgs.lib.hasInfix "is-active --quiet proxy-suite-per-app-tun"
        subscriptionPerAppTunUpdateScript;
      assert pkgs.lib.hasInfix "restart proxy-suite-per-app-tun" subscriptionPerAppTunUpdateScript;
      assert !(pkgs.lib.hasInfix "PER_APP_TUN_WAS_ACTIVE" subscriptionPerAppTunUpdateScript);
      true
    )

    # How a declared subscription presents this client: User-Agents only when not the default
    # (a cache fetched before there was a choice keeps its fingerprint), device info on request,
    # the HWID worked out by root and handed over on stdin. Its own interval shortens the tick.
    (
      let
        generated = import ./read-generated.nix;
        fixture = evalProxySuite [
          {
            system.stateVersion = "26.05";
            services.proxy-suite = {
              enable = true;
              proxy = {
                enable = true;
                backend = "sing-box";
                subscriptionHwidFile = "/run/secrets/hwid";
                subscriptions = [
                  {
                    tag = "panel";
                    url = "https://panel.example/sub";
                    userAgent = [
                      "v2rayN/6.0"
                      "Happ/1.0"
                    ];
                    sendDeviceInfo = true;
                    updateInterval = "30min";
                  }
                  {
                    tag = "plain";
                    url = "https://plain.example/sub";
                  }
                ];
              };
            };
          }
        ];
        unitScript =
          unit: generated.readDerivation fixture.config.systemd.services.${unit}.serviceConfig.ExecStart;
        start = unitScript "proxy-suite-socks";
        update = unitScript "proxy-suite-subscription-update";
      in
      assert pkgs.lib.hasInfix " --user-agent v2rayN/6.0 --user-agent Happ/1.0 --device-info" start;
      assert pkgs.lib.hasInfix " --user-agent v2rayN/6.0 --user-agent Happ/1.0 --device-info" update;
      assert
        !(builtins.any (pkgs.lib.hasInfix "--user-agent") (
          builtins.filter (pkgs.lib.hasInfix "_proxy_suite_load_subscription plain ") (
            pkgs.lib.splitString "\n" start
          )
        ));
      assert pkgs.lib.hasInfix "_proxy_suite_subscription_due panel 1800" update;
      assert
        fixture.config.systemd.timers."proxy-suite-subscription-update".timerConfig.OnUnitActiveSec
        == "1800s";
      assert pkgs.lib.hasInfix
        "hwid --fallback /var/lib/proxy-suite/subscription-hwid --file /run/secrets/hwid"
        update;
      assert pkgs.lib.hasInfix ''extra=$'\n'"hwid=$PROXY_SUITE_SUBSCRIPTION_HWID"'' update;
      true
    )

    # The update service and timer exist whenever the proxy does, because a
    # subscription can be added at runtime after the rebuild.
    (ok (minimal.config.systemd.services ? "proxy-suite-subscription-update"))
    (ok (minimal.config.systemd.timers ? "proxy-suite-subscription-update"))

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
