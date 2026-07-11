# Subscription cache and outbound-loading script fragments.
{
  lib,
  pkgs,
  proxyCfg,
  hasSubscriptions,
  hybridEnabled,
  mainBackend,
  backend,
  jq,
  python3,
  parserScriptsPythonPath,
  fetchSubscriptionPy,
  routingMarkJq,
}:

let
  subscriptionBackend = if hybridEnabled then "hybrid" else mainBackend;
  subscriptionBackendArg = "--backend ${subscriptionBackend}";
  subscriptionCacheDir = "/var/lib/proxy-suite/subscriptions/${backend}";

  mkSubscriptionCacheFile = sub: "${subscriptionCacheDir}/${sub.tag}.json";

  mkSubscriptionUrlSource =
    sub:
    if sub.urlFile != null then
      sub.urlFile
    else
      pkgs.writeText "proxy-suite-sub-url-${sub.tag}" sub.url;

  mkSubscriptionFetchCommand =
    sub:
    let
      urlSource = mkSubscriptionUrlSource sub;
    in
    ''
      printf '%s' "$(cat "${urlSource}")" \
        | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${fetchSubscriptionPy} ${subscriptionBackendArg} --tag-prefix ${lib.escapeShellArg sub.tag}
    '';

  subscriptionCacheHelpersBlock = lib.optionalString hasSubscriptions ''
    _proxy_suite_valid_subscription_cache() {
      [ -s "$1" ] && ${jq} -e ${
        lib.escapeShellArg (
          if hybridEnabled then
            ''type == "object" and (.singBox | type == "array") and (.xray | type == "array")''
          else
            ''type == "array"''
        )
      } "$1" >/dev/null 2>&1
    }

    _proxy_suite_commit_subscription_cache() {
      local tmp="$1" target="$2" tag="$3"
      if _proxy_suite_valid_subscription_cache "$tmp"; then
        mv "$tmp" "$target"
        return 0
      fi
      rm -f "$tmp"
      echo "proxy-suite: warning: subscription '$tag' produced an invalid cache; ignoring it" >&2
      return 1
    }

    _proxy_suite_drop_invalid_subscription_cache() {
      local target="$1" tag="$2"
      if [ -f "$target" ] && ! _proxy_suite_valid_subscription_cache "$target"; then
        rm -f "$target"
        echo "proxy-suite: warning: removed invalid subscription cache for '$tag'" >&2
      fi
    }
  '';

  mkSubscriptionBlock =
    sub: routingMark:
    let
      cacheFile = mkSubscriptionCacheFile sub;
      markFilter = routingMarkJq routingMark;
    in
    ''
      # subscription: ${sub.tag}
      CACHE_DIR="${subscriptionCacheDir}"
      CACHE_FILE="${cacheFile}"
      _proxy_suite_drop_invalid_subscription_cache "$CACHE_FILE" ${lib.escapeShellArg sub.tag}
      if [ ! -f "$CACHE_FILE" ]; then
        mkdir -p "$CACHE_DIR"
        if ${mkSubscriptionFetchCommand sub} > "$CACHE_FILE.tmp"; then
          _proxy_suite_commit_subscription_cache "$CACHE_FILE.tmp" "$CACHE_FILE" ${lib.escapeShellArg sub.tag} || true
        else
          rm -f "$CACHE_FILE.tmp"
          echo "proxy-suite: warning: could not fetch subscription '${sub.tag}'" >&2
        fi
      fi
      ${
        if hybridEnabled then
          ''
            if [ -f "$CACHE_FILE" ]; then
              SUB_SING_BOX_JSON=$(${jq} -c '.singBox' "$CACHE_FILE")
              ${
                lib.optionalString (routingMark != null) ''
                  SUB_SING_BOX_JSON=$(${jq} 'map(.${markFilter})' <<< "$SUB_SING_BOX_JSON")
                ''
              }OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_SING_BOX_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
              while IFS= read -r SUB_XRAY_OB; do
                SUB_XRAY_TAG="$(${jq} -r '.tag' <<< "$SUB_XRAY_OB")"
                _proxy_suite_add_xray_sidecar_ob "$SUB_XRAY_OB" "$SUB_XRAY_TAG"
              done < <(${jq} -c '.xray[]' "$CACHE_FILE")
            fi
          ''
        else
          ''
            if [ -f "$CACHE_FILE" ]; then
              SUB_JSON=$(cat "$CACHE_FILE")
              ${
                lib.optionalString (routingMark != null) ''
                  SUB_JSON=$(${jq} 'map(.${markFilter})' <<< "$SUB_JSON")
                ''
              }OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
            fi
          ''
      }
    '';

  mkSubscriptionFetchBlock =
    sub:
    let
      cacheFile = mkSubscriptionCacheFile sub;
    in
    ''
      if ${mkSubscriptionFetchCommand sub} > "${cacheFile}.tmp"; then
        if _proxy_suite_commit_subscription_cache "${cacheFile}.tmp" "${cacheFile}" ${lib.escapeShellArg sub.tag}; then
          echo "Updated subscription: ${sub.tag}"
        else
          FAILED=1
        fi
      else
        rm -f "${cacheFile}.tmp"
        echo "proxy-suite: failed to update subscription '${sub.tag}'" >&2
        FAILED=1
      fi
    '';

  subscriptionTagsFile = pkgs.writeText "proxy-suite-subscription-tags.json" (
    builtins.toJSON (map (sub: sub.tag) proxyCfg.subscriptions)
  );
in
{
  inherit
    subscriptionCacheDir
    subscriptionCacheHelpersBlock
    mkSubscriptionBlock
    mkSubscriptionFetchBlock
    subscriptionTagsFile
    ;
}
