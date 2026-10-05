@readSourceFunction@
SUB_CACHE_DIR="@cacheDir@"
RUNTIME_SUBS_DIR="@runtimeSubscriptionsDir@"

# The caches hold every server's credentials and original link: root and, with the
# "secrets" scope, the userControl groups only, as for the share file.
mkdir -p "$SUB_CACHE_DIR"
@cacheDirAccess@

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

# $1 "direct" to fetch as the service user, past the kill switch and outside the tunnel;
# otherwise as an unprivileged user the tunnel and the kill switch take as they take root.
# Root opens the output files either way (the links on fd 3).
_proxy_suite_run_fetcher() {
  local how="$1" tag="$2" src="$3" cache_tmp="$4" links_tmp="$5" as=(@tunnelFetch@)
  shift 5
  [ "$how" = direct ] && as=(@directFetch@)
  printf '%s' "$(_proxy_suite_read_source "$src")" \
    | PYTHONPATH="@pythonPath@" "${as[@]}" @python3@ @fetchSubscriptionPy@ \
        @backendArg@ --tag-prefix "$tag" --links-fd 3 "$@" > "$cache_tmp" 3> "$links_tmp"
}

# A temporary file of its own next to $1: the start scripts share the directory and fetch at
# once. Readable as the caches always were; the directory's mode keeps others out.
_proxy_suite_cache_tmp() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  chmod 0644 "$tmp"
  printf '%s' "$tmp"
}

# $1 tag, $2 file holding the subscription URL, then the fetcher's flags. Writes the cache
# atomically, and <tag>.links for proxy-ctl to share. Through the tunnel; directly past the
# kill switch only with no cache, which has no proxy to fetch through.
_proxy_suite_fetch_subscription() {
  local tag="$1" src="$2" cache="$SUB_CACHE_DIR/$1.json" links="$SUB_CACHE_DIR/$1.links" cache_tmp links_tmp
  # What a fetch killed midway (a stop's timeout) left behind.
  @findutils@/bin/find "$SUB_CACHE_DIR" -maxdepth 1 -type f \( -name "$tag.json.??????" -o -name "$tag.links.??????" \) \
    -mmin +10 -delete 2>/dev/null || true
  cache_tmp=$(_proxy_suite_cache_tmp "$cache") || return 1
  links_tmp=$(_proxy_suite_cache_tmp "$links") || { rm -f "$cache_tmp"; return 1; }
  if _proxy_suite_run_fetcher tunnel "$tag" "$src" "$cache_tmp" "$links_tmp" "${@:3}" ||
    { @killSwitch@ && ! _proxy_suite_valid_subscription_cache "$cache" &&
      echo "proxy-suite: subscription '$tag' not fetched through the tunnel and not cached; fetching it directly, past the kill switch" >&2 &&
      _proxy_suite_run_fetcher direct "$tag" "$src" "$cache_tmp" "$links_tmp" "${@:3}"; }; then
    if _proxy_suite_commit_subscription_cache "$cache_tmp" "$cache" "$tag"; then
      mv "$links_tmp" "$links"
      return 0
    fi
    rm -f "$links_tmp"
    return 1
  fi
  rm -f "$cache_tmp" "$links_tmp"
  echo "proxy-suite: failed to update subscription '$tag'" >&2
  return 1
}

# Every runtime subscription, as "<tag>\t<url file>" lines. Checked again here, as the spool
# is group-writable: a declared subscription's name would take over its cache.
_proxy_suite_runtime_subscriptions() {
  local f tag declared
  [ -d "$RUNTIME_SUBS_DIR" ] || return 0
  for f in "$RUNTIME_SUBS_DIR"/*.url; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    tag="${f##*/}"
    tag="${tag%.url}"
    if [[ ! $tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || $tag == proxy-suite-* ]]; then
      echo "proxy-suite: warning: ignoring a runtime subscription whose name is not a valid tag" >&2
      continue
    fi
    for declared in @declaredTags@; do
      if [ "$tag" = "$declared" ]; then
        echo "proxy-suite: warning: ignoring runtime subscription '$tag': a declared one has that name" >&2
        continue 2
      fi
    done
    printf '%s\t%s\n' "$tag" "$f"
  done
}
