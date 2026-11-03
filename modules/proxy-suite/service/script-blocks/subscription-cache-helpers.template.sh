@readSourceFunction@
SUB_CACHE_DIR="@cacheDir@"
SUB_META_DIR="@metaDir@"
RUNTIME_SUBS_DIR="@runtimeSubscriptionsDir@"

# The caches hold every server's credentials and original link: root and, with the
# "secrets" scope, the userControl groups only, as for the share file.
mkdir -p "$SUB_CACHE_DIR"
@cacheDirAccess@
# What each server last said of its subscription that anyone may see (traffic, expiry, a
# title): <tag>.json, for proxy-ctl. The rest of it stays beside the cache, as <tag>.meta.json.
mkdir -p "$SUB_META_DIR"
chmod 0755 "$SUB_META_DIR"

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

# The HWID fetches with --device-info send (x-hwid), worked out once per script by root: the
# fetcher's user can neither read an HWID file nor keep the fallback one.
_proxy_suite_subscription_hwid() {
  [ -n "${PROXY_SUITE_SUBSCRIPTION_HWID:-}" ] && return 0
  PROXY_SUITE_SUBSCRIPTION_HWID=$(@python3@ -I @subscriptionMetaPy@ hwid --fallback @hwidFallback@ @hwidFileArg@) &&
    [ -n "$PROXY_SUITE_SUBSCRIPTION_HWID" ]
}

# $1 "direct" to fetch as the service user, past the kill switch and outside the tunnel;
# otherwise as an unprivileged user the tunnel and the kill switch take as they take root.
# Root opens the output files either way (the links on fd 3, the metadata on fd 4). The URL
# goes in on stdin, and the HWID on the line after it: not in argv, which anyone can read.
_proxy_suite_run_fetcher() {
  local how="$1" tag="$2" src="$3" cache_tmp="$4" links_tmp="$5" meta_tmp="$6" as=(@tunnelFetch@) url arg extra=
  shift 6
  [ "$how" = direct ] && as=(@directFetch@)
  url=$(_proxy_suite_read_source "$src") || return 1
  for arg in "$@"; do
    if [ "$arg" = --device-info ]; then
      if ! _proxy_suite_subscription_hwid; then
        echo "proxy-suite: subscription '$tag': no HWID to send" >&2
        return 1
      fi
      extra=$'\n'"hwid=$PROXY_SUITE_SUBSCRIPTION_HWID"
    fi
  done
  printf '%s%s' "$url" "$extra" \
    | PYTHONPATH="@pythonPath@" "${as[@]}" @python3@ @fetchSubscriptionPy@ \
        @backendArg@ --tag-prefix "$tag" --links-fd 3 --meta-fd 4 "$@" > "$cache_tmp" 3> "$links_tmp" 4> "$meta_tmp"
}

# $1 tag, $2 the metadata a fetch wrote: kept whole beside the cache, and what anyone may see
# of it in the metadata directory. Never part of the cache itself: traffic counts change
# with every fetch, and a changed cache restarts the proxy.
_proxy_suite_save_subscription_meta() {
  local tag="$1" meta_tmp="$2" public
  if ! @jq@ -e 'type == "object"' "$meta_tmp" >/dev/null 2>&1; then
    rm -f "$meta_tmp"
    return 0
  fi
  mv "$meta_tmp" "$SUB_CACHE_DIR/$tag.meta.json"
  public=$(_proxy_suite_cache_tmp "$SUB_META_DIR/$tag.json") || return 0
  if @jq@ @publicMetaFilter@ "$SUB_CACHE_DIR/$tag.meta.json" > "$public"; then
    mv "$public" "$SUB_META_DIR/$tag.json"
  else
    rm -f "$public"
  fi
}

# $1 tag, $2 the seconds between its fetches when set explicitly (empty: what the server
# last asked for in profile-update-interval, else @defaultIntervalSeconds@). True when it is
# time to fetch it again; always without a cache. The timer ticks at least hourly, a few
# seconds after the hour has run out, so five minutes early still counts.
_proxy_suite_subscription_due() {
  local tag="$1" interval="${2:-}" meta="$SUB_META_DIR/$1.json" at hours
  [ -f "$SUB_CACHE_DIR/$tag.json" ] || return 0
  at=$(@jq@ -r '.fetchedAt | if type == "number" then floor else 0 end' "$meta" 2>/dev/null) || at=0
  [[ $at =~ ^[0-9]+$ ]] || at=0
  if [[ ! $interval =~ ^[0-9]+$ ]]; then
    hours=$(@jq@ -r '.updateIntervalHours | if type == "number" and . >= 1 then floor else empty end' "$meta" 2>/dev/null) || hours=
    if [[ $hours =~ ^[0-9]+$ ]]; then
      interval=$((hours * 3600))
    else
      interval=@defaultIntervalSeconds@
    fi
  fi
  (( $(@coreutils@/bin/date +%s) - at >= interval - 300 ))
}

# A runtime subscription's settings, from <tag>.options beside its URL (`proxy-ctl proxy subs
# add --ua … --device-info --interval …`). The spool is group-writable, so each value is
# checked again here: User-Agents are printable ASCII (a header), the interval an hour or more.
_proxy_suite_runtime_subscription_options() {
  local f="$RUNTIME_SUBS_DIR/$1.options"
  [ -e "$f" ] || return 0
  _proxy_suite_read_source "$f" | @jq@ -c '
    if type != "object" then {} else . end
    | {
        userAgent: ((.userAgent // []) | if type == "array" then . else [] end
          | map(select(type == "string" and test("^[ -~]{1,256}$"))) | .[:5]),
        deviceInfo: (.deviceInfo == true),
        interval: (.intervalSeconds | if type == "number" and . >= 3600 then floor else null end),
        # The fetcher checks these itself (proxy_parsing.checked_tweaks).
        tweaks: ({fragment, multiplex} | with_entries(select(.value | type == "object"))
                 | if . == {} then null else . end)
      }' 2>/dev/null || {
    echo "proxy-suite: warning: ignoring the unreadable settings of runtime subscription '$1'" >&2
    return 0
  }
}

# $1 tag: its fetcher flags (User-Agents, device info), NUL-separated, for mapfile -d ''.
_proxy_suite_runtime_subscription_flags() {
  _proxy_suite_runtime_subscription_options "$1" | @jq@ -j '
    ((.userAgent // [])[] | "--user-agent\u0000\(.)\u0000"), (if .deviceInfo then "--device-info\u0000" else empty end),
    (if .tweaks then "--tweaks\u0000\(.tweaks | tojson)\u0000" else empty end)'
}

# $1 tag: its explicit refetch interval in seconds, or nothing.
_proxy_suite_runtime_subscription_interval() {
  _proxy_suite_runtime_subscription_options "$1" | @jq@ -r '.interval // empty'
}

# Metadata of subscriptions gone from the config and the spool: proxy-ctl would show nothing
# of them, but a title is still something said about the user.
_proxy_suite_prune_subscription_meta() {
  local f tag declared
  for f in "$SUB_META_DIR"/*.json; do
    [ -f "$f" ] || continue
    tag="${f##*/}"
    tag="${tag%.json}"
    for declared in @declaredTags@; do
      [ "$tag" = "$declared" ] && continue 2
    done
    [ -f "$RUNTIME_SUBS_DIR/$tag.url" ] && continue
    rm -f "$f"
  done
}

# A temporary file of its own next to $1: the start scripts share the directory and fetch at
# once. Readable as the caches always were; the directory's mode keeps others out.
_proxy_suite_cache_tmp() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  chmod 0644 "$tmp"
  printf '%s' "$tmp"
}

# What a cache is fetched with, for <tag>.fingerprint: $1 the file holding the URL, then the
# fetcher's flags (allowInsecure's and the like). Hashed: the URL itself can be a secret.
_proxy_suite_subscription_fingerprint() {
  local url sum
  url=$(_proxy_suite_read_source "$1") || return 1
  shift
  sum=$({ printf '%s' "$url"; printf '\n%s' "$@"; } | @coreutils@/bin/sha256sum) || return 1
  printf '%s\n' "${sum%% *}"
}

# $1 tag, $2 fingerprint. Replaced whole: another start script may be reading it.
_proxy_suite_write_subscription_fingerprint() {
  local stamp="$SUB_CACHE_DIR/$1.fingerprint" tmp
  tmp=$(_proxy_suite_cache_tmp "$stamp") || return 1
  if printf '%s\n' "$2" > "$tmp" && mv "$tmp" "$stamp"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# $1 tag, $2 file holding the subscription URL, then the fetcher's flags. A cache fetched with
# another URL or other flags is some other subscription's, or one fetched as this one no
# longer may be: dropped, so the start fetches it as a new one. One from before fingerprints
# has none and is taken as it is.
_proxy_suite_drop_stale_subscription_cache() {
  local tag="$1" cache="$SUB_CACHE_DIR/$1.json" stamp="$SUB_CACHE_DIR/$1.fingerprint" sum
  [ -f "$cache" ] || return 0
  sum=$(_proxy_suite_subscription_fingerprint "${@:2}") || return 0
  if [ ! -f "$stamp" ]; then
    _proxy_suite_write_subscription_fingerprint "$tag" "$sum" || true
    return 0
  fi
  [ "$(< "$stamp")" = "$sum" ] && return 0
  rm -f "$cache" "$SUB_CACHE_DIR/$tag.links" "$stamp" "$SUB_CACHE_DIR/$tag.meta.json" "$SUB_META_DIR/$tag.json"
  echo "proxy-suite: subscription '$tag' has a new URL or fetch settings; dropped its cache" >&2
}

# $1 tag, $2 file holding the subscription URL, then the fetcher's flags. Writes the cache
# atomically, <tag>.links for proxy-ctl to share, <tag>.fingerprint and the metadata. Through
# the tunnel; directly past the kill switch only with no cache, which has no proxy to fetch
# through.
_proxy_suite_fetch_subscription() {
  local tag="$1" src="$2" cache="$SUB_CACHE_DIR/$1.json" links="$SUB_CACHE_DIR/$1.links" cache_tmp links_tmp meta_tmp sum
  # What a fetch killed midway (a stop's timeout) left behind.
  @findutils@/bin/find "$SUB_CACHE_DIR" "$SUB_META_DIR" -maxdepth 1 -type f \
    \( -name "$tag.json.??????" -o -name "$tag.links.??????" -o -name "$tag.fingerprint.??????" \
       -o -name "$tag.meta.json.??????" \) \
    -mmin +10 -delete 2>/dev/null || true
  # Before the fetch: a URL changed while it runs is then a stale cache at the next start.
  sum=$(_proxy_suite_subscription_fingerprint "$src" "${@:3}") || sum=
  cache_tmp=$(_proxy_suite_cache_tmp "$cache") || return 1
  links_tmp=$(_proxy_suite_cache_tmp "$links") || { rm -f "$cache_tmp"; return 1; }
  meta_tmp=$(_proxy_suite_cache_tmp "$SUB_CACHE_DIR/$tag.meta.json") || { rm -f "$cache_tmp" "$links_tmp"; return 1; }
  if _proxy_suite_run_fetcher tunnel "$tag" "$src" "$cache_tmp" "$links_tmp" "$meta_tmp" "${@:3}" ||
    { @killSwitch@ && ! _proxy_suite_valid_subscription_cache "$cache" &&
      echo "proxy-suite: subscription '$tag' not fetched through the tunnel and not cached; fetching it directly, past the kill switch" >&2 &&
      _proxy_suite_run_fetcher direct "$tag" "$src" "$cache_tmp" "$links_tmp" "$meta_tmp" "${@:3}"; }; then
    if _proxy_suite_commit_subscription_cache "$cache_tmp" "$cache" "$tag"; then
      mv "$links_tmp" "$links"
      _proxy_suite_save_subscription_meta "$tag" "$meta_tmp"
      # Also when the cache came out the same: the settings are what changed.
      if [ -z "$sum" ] || ! _proxy_suite_write_subscription_fingerprint "$tag" "$sum"; then
        rm -f "$SUB_CACHE_DIR/$tag.fingerprint"
      fi
      return 0
    fi
    rm -f "$links_tmp" "$meta_tmp"
    return 1
  fi
  rm -f "$cache_tmp" "$links_tmp" "$meta_tmp"
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
