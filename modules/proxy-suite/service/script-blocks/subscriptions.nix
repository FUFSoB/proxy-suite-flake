# Subscription cache and outbound-loading script fragments.
#
# Everything is emitted as shell functions taking a tag and a file holding the
# subscription URL, so a subscription declared in Nix and one added at runtime
# under `subscriptions.d/` go through exactly the same code.
{
  lib,
  pkgs,
  proxyCfg,
  hybridEnabled,
  mainBackend,
  backend,
  stateDir,
  runtimeSubscriptionsDir,
  jq,
  python3,
  parserScriptsPythonPath,
  fetchSubscriptionPy,
  routingMarkJq,
}:

let
  subscriptionBackend = if hybridEnabled then "hybrid" else mainBackend;
  subscriptionBackendArg = "--backend ${subscriptionBackend}";
  subscriptionCacheDir = "${stateDir}/subscriptions/${backend}";

  mkSubscriptionUrlSource =
    sub:
    if sub.urlFile != null then
      sub.urlFile
    else
      pkgs.writeText "proxy-suite-core" sub.url;

  # Defined in every script that touches a cache: the start scripts and the
  # update unit.
  subscriptionCacheHelpersBlock = ''
    SUB_CACHE_DIR="${subscriptionCacheDir}"
    RUNTIME_SUBS_DIR="${runtimeSubscriptionsDir}"

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

    # $1 tag, $2 file holding the subscription URL. Writes the cache atomically,
    # and next to it <tag>.links: each entry's original URI, for proxy-ctl to share.
    _proxy_suite_fetch_subscription() {
      local tag="$1" src="$2" cache="$SUB_CACHE_DIR/$1.json" links="$SUB_CACHE_DIR/$1.links"
      mkdir -p "$SUB_CACHE_DIR"
      if printf '%s' "$(cat "$src")" \
        | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${fetchSubscriptionPy} \
            ${subscriptionBackendArg} --tag-prefix "$tag" --links-out "$links.tmp" > "$cache.tmp"; then
        if _proxy_suite_commit_subscription_cache "$cache.tmp" "$cache" "$tag"; then
          mv "$links.tmp" "$links"
          return 0
        fi
        rm -f "$links.tmp"
        return 1
      fi
      rm -f "$cache.tmp" "$links.tmp"
      echo "proxy-suite: failed to update subscription '$tag'" >&2
      return 1
    }

    # Every runtime subscription, as "<tag>\t<url file>" lines.
    _proxy_suite_runtime_subscriptions() {
      local f tag
      [ -d "$RUNTIME_SUBS_DIR" ] || return 0
      for f in "$RUNTIME_SUBS_DIR"/*.url; do
        [ -e "$f" ] || continue
        tag="''${f##*/}"
        tag="''${tag%.url}"
        printf '%s\t%s\n' "$tag" "$f"
      done
    }
  '';

  # Merging a cache into OUTBOUNDS_JSON needs the routing mark, which differs per
  # start script, so this one is emitted separately from the cache helpers.
  mkSubscriptionLoadHelperBlock =
    routingMark:
    let
      markFilter = routingMarkJq routingMark;
      subVar = if hybridEnabled then "SUB_SING_BOX_JSON" else "SUB_JSON";
      # Plain string concatenation: "$" next to an interpolation is exactly the
      # spot where an indented string's escaping bites.
      markBlock = lib.optionalString (routingMark != null) (
        subVar + "=$(${jq} 'map(.${markFilter})' <<< \"$" + subVar + "\")\n"
      );
      mergeBlock =
        if hybridEnabled then
          ''
            SUB_SING_BOX_JSON=$(${jq} -c '.singBox' "$cache")
            ${markBlock}OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_SING_BOX_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
            _proxy_suite_add_xray_sidecar_obs "$(${jq} -c '.xray' "$cache")"
          ''
        else
          ''
            SUB_JSON=$(cat "$cache")
            ${markBlock}OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
          '';
    in
    ''
      # $1 tag, $2 file holding the subscription URL. Fetches on a cold cache and
      # merges whatever is cached; a subscription that cannot be fetched is a
      # warning, never a failed start.
      _proxy_suite_load_subscription() {
        local tag="$1" src="$2" cache="$SUB_CACHE_DIR/$1.json" before after
        _proxy_suite_drop_invalid_subscription_cache "$cache" "$tag"
        if [ ! -f "$cache" ]; then
          _proxy_suite_fetch_subscription "$tag" "$src" \
            || echo "proxy-suite: warning: could not fetch subscription '$tag'" >&2
        fi
        [ -f "$cache" ] || return 0
        before=$(${jq} 'length' <<< "$OUTBOUNDS_JSON")
        ${mergeBlock}
        after=$(${jq} 'length' <<< "$OUTBOUNDS_JSON")
        _proxy_suite_record_outbound_source "sub:$tag" "$before" "$after"
        _proxy_suite_record_subscription_share "$tag" "$src" "$SUB_CACHE_DIR/$tag.links"
      }
    '';

  mkSubscriptionBlock =
    sub: _routingMark:
    ''
      # subscription: ${sub.tag}
      _proxy_suite_load_subscription ${lib.escapeShellArg sub.tag} ${
        lib.escapeShellArg (mkSubscriptionUrlSource sub)
      }
    '';

  runtimeSubscriptionsBlock = ''
    # subscriptions added at runtime
    while IFS=$'\t' read -r RUNTIME_SUB_TAG RUNTIME_SUB_SRC; do
      [ -n "$RUNTIME_SUB_TAG" ] || continue
      _proxy_suite_load_subscription "$RUNTIME_SUB_TAG" "$RUNTIME_SUB_SRC"
    done < <(_proxy_suite_runtime_subscriptions)
  '';

  mkSubscriptionFetchBlock =
    sub:
    ''
      if _proxy_suite_fetch_subscription ${lib.escapeShellArg sub.tag} ${
        lib.escapeShellArg (mkSubscriptionUrlSource sub)
      }; then
        echo "Updated subscription: ${sub.tag}"
      else
        FAILED=1
      fi
    '';

  runtimeSubscriptionsFetchBlock = ''
    while IFS=$'\t' read -r RUNTIME_SUB_TAG RUNTIME_SUB_SRC; do
      [ -n "$RUNTIME_SUB_TAG" ] || continue
      if _proxy_suite_fetch_subscription "$RUNTIME_SUB_TAG" "$RUNTIME_SUB_SRC"; then
        echo "Updated subscription: $RUNTIME_SUB_TAG"
      else
        FAILED=1
      fi
    done < <(_proxy_suite_runtime_subscriptions)
  '';

  subscriptionTagsFile = pkgs.writeText "proxy-suite-core" (
    builtins.toJSON (map (sub: sub.tag) proxyCfg.subscriptions)
  );
in
{
  inherit
    subscriptionCacheDir
    subscriptionCacheHelpersBlock
    mkSubscriptionLoadHelperBlock
    mkSubscriptionBlock
    runtimeSubscriptionsBlock
    mkSubscriptionFetchBlock
    runtimeSubscriptionsFetchBlock
    subscriptionTagsFile
    ;
}
