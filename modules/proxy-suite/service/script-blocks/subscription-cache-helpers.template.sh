@readSourceFunction@
SUB_CACHE_DIR="@cacheDir@"
RUNTIME_SUBS_DIR="@runtimeSubscriptionsDir@"

_proxy_suite_valid_subscription_cache() {
  [ -s "$1" ] && @jq@ -e @validCacheFilter@ "$1" >/dev/null 2>&1
}

# Set when a fetch leaves a cache different from before, so the update unit restarts the
# proxy only for a change: a restart cuts every connection through it.
SUB_CACHE_CHANGED=0

_proxy_suite_commit_subscription_cache() {
  local tmp="$1" target="$2" tag="$3"
  if _proxy_suite_valid_subscription_cache "$tmp"; then
    if [ -f "$target" ] && @diffutils@/bin/cmp -s "$tmp" "$target"; then
      rm -f "$tmp"
    else
      mv "$tmp" "$target"
      SUB_CACHE_CHANGED=1
    fi
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
  if printf '%s' "$(_proxy_suite_read_source "$src")" \
    | PYTHONPATH="@pythonPath@" @python3@ @fetchSubscriptionPy@ \
        @backendArg@ --tag-prefix "$tag" --links-out "$links.tmp" > "$cache.tmp"; then
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
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    tag="${f##*/}"
    tag="${tag%.url}"
    printf '%s\t%s\n' "$tag" "$f"
  done
}
