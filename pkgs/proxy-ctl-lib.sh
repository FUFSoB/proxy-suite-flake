ALL_SERVICES=(
  proxy-suite-socks
  proxy-suite-tproxy
  proxy-suite-tun
  proxy-suite-inbounds
  proxy-suite-ssh-proxy
  proxy-suite-tg-ws-proxy
  proxy-suite-zapret-vm-exempt
  zapret-discord-youtube
)

RESTART_SERVICES=(
  proxy-suite-tproxy
  proxy-suite-tun
  proxy-suite-inbounds
  proxy-suite-ssh-proxy
  proxy-suite-tg-ws-proxy
  zapret-discord-youtube
)

_help() {
  cat <<'EOF'
Usage: proxy-ctl <group> [verb] [args]
A group without a verb shows its status or list.

  status [--tray]                        services and routing mode
  restart                                restart active services
  logs [unit]                            follow logs (default: every proxy-suite unit)
  where <domain>                         how this host is routed right now

  proxy [status|on|off]                  local proxy backend
  proxy outbounds [list]                 outbounds, where each came from, and the pick
  proxy outbounds add <tag> <url>        add an outbound at runtime
  proxy outbounds rm <tag>               remove a runtime outbound
  proxy select [<tag>|auto]              pin the priority outbound (no tag: pick from a menu)
  proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]
                                         show or override the routing mode
  proxy subs [list|update]               subscription caches; update refetches them
  proxy subs add <tag> <url>             add a subscription at runtime
  proxy subs rm <tag>                    remove a runtime subscription
  proxy tun [status|on|off]              global TUN mode
  proxy tproxy [status|on|off]           global TProxy mode
  proxy auto [list]                      what autoProxy routed, and via which exit (sudo, or userControl)
  proxy auto probe <domain>[/path] [--json] [--exits a,b | --via tag]
                                         find an exit that reaches a domain
  proxy auto learn <domain>              probe now and route it if an exit works (sudo)
  proxy auto queue [count]               destinations waiting to be probed (sudo, or userControl)

  zapret [status|on|off]                 DPI bypass
  zapret auto [list]                     hosts zapret2 learned as blocked
  zapret auto add|forget|exclude <domain>
                                         pin, forget, or never learn a host (sudo)
  zapret auto clear                      forget every learned host (sudo)

  awg [list]                             AmneziaWG profiles and their state
  awg on <profile> | off [profile] | restart [profile]

  ssh [status|on|off]                    SSH SOCKS5 tunnel

  apps [list]                            per-app routing profiles
  apps run <profile> -- <cmd> [args]     run a command through a profile

  inbounds [list]                        server inbounds
  inbounds link <tag> [user] [--qr]      client share link
  inbounds sub [user] [--qr]             subscription users, or one user's URL
  inbounds stats [days]                  traffic per user (sudo, or userControl)
EOF
}

# Completion candidates for the words already typed, one per line. The tree
# lives here, next to _help, not in the completion file.
_complete_tree() {
  local profile
  case "$*" in
    "") printf '%s\n' status restart logs where proxy zapret awg ssh apps inbounds help ;;
    proxy) printf '%s\n' status on off outbounds select mode subs tun tproxy auto ;;
    "proxy outbounds") printf '%s\n' list add rm ;;
    "proxy outbounds rm") _runtime_tags outbound ;;
    "proxy subs") printf '%s\n' list update add rm ;;
    "proxy subs rm") _runtime_tags subscription ;;
    "proxy select") printf 'auto\n'; _outbound_tags ;;
    "proxy mode") printf '%s\n' default whitelist blacklist all-proxy all-bypass ;;
    "proxy tun" | "proxy tproxy" | zapret | ssh) printf '%s\n' status on off ;;
    "proxy auto") printf '%s\n' list probe learn queue ;;
    "zapret auto") printf '%s\n' list add forget exclude clear ;;
    "zapret auto forget" | "zapret auto exclude") cat "$(_zapret_auto_file zapret-hosts-auto.txt)" ;;
    awg) printf '%s\n' list on off restart ;;
    "awg on" | "awg off" | "awg restart") printf '%s\n' "${AWG_PROFILES[@]}" ;;
    apps) printf '%s\n' list run ;;
    "apps run") jq -r '.[].name' "$PER_APP_ROUTING_PROFILES_FILE" ;;
    inbounds) printf '%s\n' list link sub stats ;;
    "inbounds link") jq -r '.[].tag' "$INBOUNDS_LINKS_FILE" | sort -u ;;
    "inbounds sub") jq -r '.[].user' "$INBOUNDS_SUBS_FILE" ;;
    logs)
      printf '%s\n' "${ALL_SERVICES[@]}"
      for profile in "${AWG_PROFILES[@]}"; do
        _awg_service "$profile"
        echo
      done
      ;;
    where) jq -r '(.domains // {}) | keys[]' "$(_autoproxy_dir)/state.json" ;;
  esac
}

# The hidden verb the installed bash completion calls. Completing must never
# die or say anything, however unreadable the state behind an arm is.
cmd_complete() {
  _complete_tree "$@" 2>/dev/null || true
}

_die() {
  echo "$*" >&2
  exit 1
}

_usage() {
  _die "Usage: proxy-ctl $*"
}

_bool() {
  if "$@"; then printf true; else printf false; fi
}

_svc_exists() {
  systemctl cat "$1" &>/dev/null
}

_svc_active() {
  systemctl is-active --quiet "$1"
}

_svc_status() {
  _svc_exists "$1" || return 0
  printf "  %-44s %s\n" "$1" "$(systemctl is-active "$1" 2>/dev/null || true)"
}

_stop_if_exists() {
  if _svc_exists "$1"; then systemctl stop "$1" || true; fi
}

_toggle() {
  local unit="$1" name="$2" verb="${3:-status}"
  _svc_exists "$unit" || _die "$name is not enabled in this configuration."
  case "$verb" in
    status) systemctl is-active "$unit" || true ;;
    on) systemctl start "$unit" ;;
    off) systemctl stop "$unit" ;;
    *) _usage "$name [status|on|off]" ;;
  esac
}

# Prints the QR code instead when $2 is 1.
_emit() {
  if [ "$2" = 1 ]; then
    printf '%s' "$1" | qrencode -t ANSIUTF8
  else
    printf '%s\n' "$1"
  fi
}

# --- status ------------------------------------------------------------------

_route_mode_default() {
  printf '%s' "${DEFAULT_ROUTE_MODE:-blacklist}"
}

_route_mode_effective() {
  local mode=""
  if [ -n "${ROUTE_MODE_STATE_FILE:-}" ] && [ -r "${ROUTE_MODE_STATE_FILE}" ]; then
    mode=$(tr -d '\r\n[:space:]' < "${ROUTE_MODE_STATE_FILE}" 2>/dev/null || true)
  fi
  case "$mode" in
    whitelist|blacklist|all-proxy|all-bypass) printf '%s' "$mode" ;;
    *) _route_mode_default ;;
  esac
}

_route_mode_current() {
  if [ -n "${ROUTE_MODE_STATE_FILE:-}" ] && [ -r "${ROUTE_MODE_STATE_FILE}" ]; then
    _route_mode_effective
  else
    printf 'default'
  fi
}

_route_mode_label() {
  case "$1" in
    default) printf 'Default (%s)' "$(_route_mode_label "$(_route_mode_default)")" ;;
    whitelist) printf 'Whitelist (direct by default)' ;;
    blacklist) printf 'Blacklist (proxy by default)' ;;
    all-proxy) printf 'All Proxy (override)' ;;
    all-bypass) printf 'All Bypass (override)' ;;
    *) printf 'Unknown' ;;
  esac
}

_status_tray() {
  local pair key svc
  for pair in \
    socks:proxy-suite-socks \
    tproxy:proxy-suite-tproxy \
    tun:proxy-suite-tun \
    zapret:zapret-discord-youtube; do
    key="${pair%%:*}"
    svc="${pair##*:}"
    printf '%s_available=%s\n' "$key" "$(_bool _svc_exists "$svc")"
    printf '%s_active=%s\n' "$key" "$(_bool _svc_active "$svc")"
  done
  printf 'subscription_update_available=%s\n' "$(_bool _svc_exists proxy-suite-subscription-update)"
  printf 'route_mode_available=%s\n' "$(_bool _svc_exists proxy-suite-socks)"
  printf 'route_mode=%s\n' "$(_route_mode_current)"
  printf 'default_route_mode=%s\n' "$(_route_mode_default)"
  printf 'awg_available=%s\n' "$(_bool test "${#AWG_PROFILES[@]}" -gt 0)"
  printf 'awg_active=%s\n' "$(_active_awg_profiles | head -n1)"
  printf 'awg_profiles=%s\n' "$(IFS=,; echo "${AWG_PROFILES[*]}")"
}

_status_row() {
  printf "  %-44s %s\n" "$1" "$2"
}

# Nothing to say about a state that is absent or unreadable.
_status_row_if() {
  [ -z "$2" ] || _status_row "$1" "$2"
}

# The pin when there is one, otherwise whatever the backend is dialling.
_status_outbound() {
  local pinned current
  pinned="$(_outbound_inventory | jq -r '.pinned // ""' 2>/dev/null || true)"
  if [ -n "$pinned" ]; then
    printf '%s (pinned)' "$pinned"
    return
  fi
  current="$(_outbound_current)"
  if [ -n "$current" ]; then printf '%s' "$current"; fi
}

_status_autoproxy() {
  local state next
  [ "${AUTOPROXY_ENABLED:-0}" = 1 ] || return 0
  state="$(_autoproxy_dir)/state.json"
  [ -r "$state" ] || return 0
  printf '%s routed, %s queued' \
    "$(jq '(.domains // {}) | length' "$state" 2>/dev/null || echo '?')" \
    "$(jq '(.backlog // {}) | length' "$state" 2>/dev/null || echo '?')"
  next="$(_autoproxy_next_run)"
  if [ -n "$next" ]; then printf ', next run %s' "$(_in_time "$next")"; fi
}

_status_zapret() {
  local auto
  [ "${ZAPRET_AUTO_ENABLED:-0}" = 1 ] || return 0
  auto="$(_zapret_auto_file zapret-hosts-auto.txt)"
  [ -r "$auto" ] || return 0
  printf '%s learned' "$(grep -c . "$auto" || true)"
}

cmd_status() {
  if [ "${1:-}" = "--tray" ]; then
    _status_tray
    return
  fi
  local svc profile
  echo "proxy-suite services:"
  for svc in "${ALL_SERVICES[@]}"; do
    _svc_status "$svc"
  done
  for profile in "${AWG_PROFILES[@]}"; do
    _svc_status "$(_awg_service "$profile")"
  done
  if _svc_exists proxy-suite-socks || [ "${ZAPRET_AUTO_ENABLED:-0}" = 1 ]; then
    echo ""
    echo "routing:"
    if _svc_exists proxy-suite-socks; then
      _status_row "active mode" "$(_route_mode_label "$(_route_mode_current)")"
      _status_row_if "outbound" "$(_status_outbound)"
      _status_row_if "autoProxy" "$(_status_autoproxy)"
    fi
    _status_row_if "zapret2" "$(_status_zapret)"
  fi
}

# Restarts what is running; starting something that was stopped on purpose is
# what `proxy on` is for.
cmd_restart() {
  local svc profile
  if _svc_exists proxy-suite-socks && _svc_active proxy-suite-socks; then
    systemctl restart proxy-suite-socks
  fi
  for svc in "${RESTART_SERVICES[@]}"; do
    if _svc_exists "$svc" && _svc_active "$svc"; then
      systemctl restart "$svc"
    fi
  done
  for profile in "${AWG_PROFILES[@]}"; do
    if _svc_active "$(_awg_service "$profile")"; then
      systemctl restart "$(_awg_service "$profile")"
    fi
  done
}

# --- proxy -------------------------------------------------------------------

cmd_proxy() {
  local verb="${1:-status}"
  shift || true
  case "$verb" in
    status | on) _toggle proxy-suite-socks proxy "$verb" ;;
    off)
      _svc_exists proxy-suite-socks || _die "proxy is not enabled in this configuration."
      _stop_if_exists proxy-suite-tproxy
      _stop_if_exists proxy-suite-tun
      systemctl stop proxy-suite-socks
      ;;
    outbounds) cmd_outbounds "$@" ;;
    select) cmd_select "$@" ;;
    mode) cmd_route_mode "$@" ;;
    subs) cmd_subscription "$@" ;;
    tun) _toggle proxy-suite-tun "proxy tun" "$@" ;;
    tproxy) _toggle proxy-suite-tproxy "proxy tproxy" "$@" ;;
    auto) cmd_proxy_auto "$@" ;;
    probe | learn | queue | learned) cmd_proxy_auto "$verb" "$@" ;;
    *) _usage "proxy [status|on|off|outbounds|select|mode|subs|tun|tproxy|auto]" ;;
  esac
}

cmd_outbounds() {
  local verb="${1:-list}"
  shift || true
  case "$verb" in
    list) _outbounds_list ;;
    add) _runtime_entry_add outbound "$@" ;;
    rm | remove | del) _runtime_entry_rm outbound "$@" ;;
    *) _usage "proxy outbounds [list|add <tag> <url>|rm <tag>]" ;;
  esac
}

# The inventory the running backend wrote: tags, where each came from, and the
# pin. Absent until the proxy has started once.
_outbound_inventory() {
  if [ -r "${OUTBOUND_INVENTORY_FILE:-}" ]; then
    cat "$OUTBOUND_INVENTORY_FILE"
  else
    printf '%s' '{}'
  fi
}

_outbound_tags() {
  _outbound_inventory | jq -r '(.tags // [])[]'
}

_require_outbound_inventory() {
  if [ "$(_outbound_inventory | jq -r '(.tags // []) | length')" = 0 ]; then
    _die "No outbounds are available yet - is proxy-suite-socks running?"
  fi
}

# What the backend is dialling right now, when it exposes a selector. Empty
# otherwise, which is the normal case for selection = "first" and for XRay.
_outbound_current() {
  curl -sf "$CLASH_API/proxies/proxy" 2>/dev/null | jq -r '.now // empty' 2>/dev/null || true
}

_outbounds_list() {
  local inv pinned current selection mark tag source
  _require_outbound_inventory
  inv=$(_outbound_inventory)
  pinned=$(jq -r '.pinned // ""' <<<"$inv")
  selection=$(jq -r '.selection // "first"' <<<"$inv")
  current=$(_outbound_current)

  echo "Selection: $selection"
  if [ -n "$pinned" ]; then
    echo "Pinned:    $pinned"
  else
    echo "Pinned:    (auto)"
  fi
  if [ -n "$current" ]; then
    echo "Current:   $current"
  fi
  echo ""
  printf "  %-34s %s\n" "TAG" "SOURCE"
  while IFS=$'\t' read -r tag source; do
    mark=" "
    if [ "$tag" = "$pinned" ]; then
      mark="*"
    elif [ -z "$pinned" ] && [ "$tag" = "$current" ]; then
      mark=">"
    fi
    printf " %s%-34s %s\n" "$mark" "$tag" "$source"
  done < <(jq -r '. as $i | (.tags // [])[] | [., (($i.sources // {})[.] // "-")] | @tsv' <<<"$inv")
}

# Runs in a command substitution, so anything fatal has to be checked by the
# caller first: an exit here would only leave the subshell.
_select_outbound_menu() {
  local inv pinned
  inv=$(_outbound_inventory)
  pinned=$(jq -r '.pinned // ""' <<<"$inv")
  { printf 'auto\n'; jq -r '(.tags // [])[]' <<<"$inv"; } |
    fzf --prompt='outbound> ' --height=40% --reverse \
      --header="pinned: ${pinned:-auto}  (auto = let the configured selection decide)"
}

cmd_select() {
  local tag="${1:-}" escaped
  if [ -z "$tag" ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      _usage "proxy select <tag>|auto"
    fi
    _require_outbound_inventory
    # Empty when the menu was dismissed.
    tag="$(_select_outbound_menu)" || return 0
    [ -n "$tag" ] || return 0
  fi
  [ -n "$tag" ] || _usage "proxy select [<tag>|auto]"
  escaped="$(systemd-escape -- "$tag")"
  systemctl start "proxy-suite-outbound-select@${escaped}.service" ||
    _die "Failed - see: proxy-ctl logs proxy-suite-outbound-select@${escaped}"
  if [ "$tag" = auto ]; then
    echo "Selecting automatically again."
  else
    echo "Pinned: $tag"
  fi
}

# --- runtime outbounds and subscriptions -------------------------------------
#
# One URL per file in a spool directory the userControl group may write. The
# backend reads them at start, which the reload unit triggers.

_runtime_dir() {
  if [ "$1" = outbound ]; then
    printf '%s' "${RUNTIME_OUTBOUNDS_DIR:-/var/lib/proxy-suite/outbounds.d}"
  else
    printf '%s' "${RUNTIME_SUBS_DIR:-/var/lib/proxy-suite/subscriptions.d}"
  fi
}

_runtime_noun() {
  if [ "$1" = outbound ]; then printf 'outbounds'; else printf 'subs'; fi
}

_runtime_tags() {
  local dir f tag
  dir="$(_runtime_dir "$1")"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.url; do
    [ -e "$f" ] || continue
    tag="${f##*/}"
    printf '%s\n' "${tag%.url}"
  done
}

_check_runtime_tag() {
  local kind="$1" tag="$2" t
  case "$tag" in
    proxy | direct | block)
      _die "'$tag' is reserved; pick another $kind tag."
      ;;
  esac
  if ! [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    _die "Invalid $kind tag '$tag': letters, digits, dot, dash and underscore only."
  fi
  if _runtime_tags "$kind" | grep -qxF "$tag"; then
    _die "A runtime $kind named '$tag' already exists; remove it first."
  fi
  if [ "$kind" = outbound ]; then
    if _outbound_tags | grep -qxF "$tag"; then
      _die "An outbound named '$tag' already exists."
    fi
  else
    for t in "${SUB_TAGS[@]}"; do
      if [ "$t" = "$tag" ]; then
        _die "A subscription named '$tag' is declared in the configuration."
      fi
    done
  fi
}

_runtime_entry_add() {
  local kind="$1" tag="${2:-}" url="${3:-}" file
  if [ -z "$tag" ] || [ -z "$url" ]; then
    _usage "proxy $(_runtime_noun "$kind") add <tag> <url>"
  fi
  _check_runtime_tag "$kind" "$tag"
  case "$url" in
    *[[:space:]]*) _die "A URL cannot contain whitespace." ;;
  esac
  file="$(_runtime_dir "$kind")/$tag.url"
  ( umask 027; printf '%s\n' "$url" > "$file" ) 2>/dev/null ||
    _die "Cannot write $file - join the ${USER_CONTROL_GROUP:-proxy-suite} group, or re-run with sudo."
  _runtime_reload
  _runtime_entry_verify "$kind" "$tag"
}

_runtime_entry_rm() {
  local kind="$1" tag="${2:-}" file
  [ -n "$tag" ] || _usage "proxy $(_runtime_noun "$kind") rm <tag>"
  file="$(_runtime_dir "$kind")/$tag.url"
  if [ ! -e "$file" ]; then
    _die "No runtime $kind named '$tag'. Ones declared in the NixOS configuration are removed there."
  fi
  rm -f "$file" 2>/dev/null ||
    _die "Cannot remove $file - join the ${USER_CONTROL_GROUP:-proxy-suite} group, or re-run with sudo."
  _runtime_reload
  echo "Removed $kind: $tag"
}

_runtime_reload() {
  systemctl start proxy-suite-outbound-reload.service ||
    _die "Saved, but applying it failed - see: proxy-ctl logs proxy-suite-outbound-reload"
}

# Only the backend parses the URL, so confirm the entry actually came up.
_runtime_entry_verify() {
  local kind="$1" tag="$2" cache
  if [ "$kind" = outbound ]; then
    if _outbound_tags | grep -qxF "$tag"; then
      echo "Added outbound: $tag"
      return
    fi
  else
    cache="${SUB_CACHE_DIR:-/var/lib/proxy-suite/subscriptions}/$tag.json"
    if [ -f "$cache" ]; then
      echo "Added subscription: $tag ($(_subscription_proxy_count "$cache" 2>/dev/null || echo '?') proxies)"
      return
    fi
  fi
  echo "Saved $kind '$tag', but it did not come up. Check: proxy-ctl logs" >&2
  echo "Remove it again with: proxy-ctl proxy $(_runtime_noun "$kind") rm $tag" >&2
  exit 1
}

cmd_route_mode() {
  local action="${1:-status}"
  _svc_exists proxy-suite-socks || _die "proxy is not enabled in this configuration."
  case "$action" in
    status) _route_mode_current; echo ;;
    default|whitelist|blacklist|all-proxy|all-bypass)
      systemctl start "proxy-suite-route-mode@${action}.service"
      echo "Switched to: $(_route_mode_label "$action")"
      ;;
    *) _usage "proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]" ;;
  esac
}

_subscription_proxy_count() {
  jq '
    if type == "array" then length
    elif type == "object" and (.singBox | type == "array") and (.xray | type == "array")
    then (.singBox | length) + (.xray | length)
    else error("unsupported subscription cache shape")
    end
  ' "$1"
}

_subscription_row() {
  local tag="$1" source="$2" dir="${SUB_CACHE_DIR:-/var/lib/proxy-suite/subscriptions}"
  local cache="$dir/$tag.json" age count
  if [ -f "$cache" ]; then
    age=$(date -r "$cache" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
    count=$(_subscription_proxy_count "$cache" 2>/dev/null || echo "?")
  else
    age="(no cache)"
    count="-"
  fi
  printf "  %-30s %-22s %-9s %s\n" "$tag" "$age" "$count" "$source"
}

_subscription_list() {
  local t runtime
  runtime="$(_runtime_tags subscription)"
  if [ ${#SUB_TAGS[@]} -eq 0 ] && [ -z "$runtime" ]; then
    echo "No subscriptions configured."
    return
  fi
  printf "  %-30s %-22s %-9s %s\n" "TAG" "LAST UPDATED" "PROXIES" "SOURCE"
  for t in "${SUB_TAGS[@]}"; do
    _subscription_row "$t" static
  done
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    _subscription_row "$t" runtime
  done <<<"$runtime"
}

cmd_subscription() {
  local verb="${1:-list}"
  shift || true
  case "$verb" in
    list) _subscription_list ;;
    add) _runtime_entry_add subscription "$@" ;;
    rm | remove | del) _runtime_entry_rm subscription "$@" ;;
    update)
      _svc_exists proxy-suite-subscription-update || _die "The proxy is not enabled in this configuration."
      systemctl start proxy-suite-subscription-update
      echo "Subscription update triggered. Follow with: proxy-ctl logs proxy-suite-subscription-update"
      ;;
    *) _usage "proxy subs [list|update|add <tag> <url>|rm <tag>]" ;;
  esac
}

# --- proxy auto: reachability probe ------------------------------------------
#
# Fetches a URL through one exit after another (direct first) and finds one
# whose origin answers. The exits are the per-exit loopback listeners
# proxy-suite-socks opens for autoProxy (PROBE_EXITS_FILE); without them, only
# this host and the local proxy. The apex decides when any exit gets content
# from it; robots.txt breaks ties when the apex is refused everywhere.

PROBE_PATH="${PROBE_PATH:-/}"
PROBE_PATH_FALLBACK="${PROBE_PATH_FALLBACK:-/robots.txt}"
PROBE_UA="${PROBE_UA:-Mozilla/5.0 (X11; Linux x86_64) proxy-suite-probe}"
PROBE_EXITS_FILE="${PROBE_EXITS_FILE:-/run/proxy-suite-socks/probe-exits.json}"
PROBE_BLOCK_REDIRECT='unavailable|not-available|blocked|geo|region|restricted'

# Last two labels: only used to keep redirect following on one site.
_probe_site() {
  local host="${1#*://}"
  host="${host%%[/:?#]*}"
  printf '%s' "$host" | awk -F. '{ print $(NF - 1) "." $NF }'
}

# $1 domain, $2 path, rest: curl egress selector. Echoes
# "<curl-exit>|<appconnect-seconds>|<http-status>|<bytes>|<location>" for the
# first hop that is not a same-site redirect: a block can sit at the end of a
# chain (spotify.com -> www -> open -> accounts -> why-not-available).
_probe_fetch() {
  local domain="$1" path="$2" url site result hop rc
  local -a ua=()
  shift 2
  url="https://${domain}${path}"
  site="$(_probe_site "$url")"
  # An impersonating curl must keep its browser's own User-Agent.
  [ -n "${PROBE_CURL:-}" ] || ua=(-A "$PROBE_UA")
  for hop in 1 2 3 4 5 6; do
    rc=0
    result="$("${PROBE_CURL:-curl}" -sS -o /dev/null \
      "${ua[@]}" \
      --connect-timeout "${PROBE_CONNECT_TIMEOUT:-8}" \
      --max-time "${PROBE_MAX_TIME:-15}" \
      -w '%{exitcode}|%{time_appconnect}|%{http_code}|%{size_download}|%{redirect_url}' \
      "$@" "$url" 2>/dev/null)" || rc=$?
    # Not a dead site: curl itself did not start.
    if [ -z "$result" ] && [ "$rc" -ge 126 ]; then
      _die "Cannot run ${PROBE_CURL:-curl} (exit $rc)."
    fi
    [ -n "$result" ] || result='99|0|000|0|'
    case "$(_probe_field "$result" 3)" in
      3??) ;;
      *) break ;;
    esac
    _probe_redirect_is_block "$result" && break
    url="$(_probe_field "$result" 5)"
    { [ -n "$url" ] && [ "$(_probe_site "$url")" = "$site" ]; } || break
    : "$hop"
  done
  printf '%s' "$result"
}

_probe_field() {
  printf '%s' "$1" | cut -d'|' -f"$2"
}

# curl reports appconnect 0 when TLS never finished.
_probe_tls_ok() {
  case "$(_probe_field "$1" 2)" in
    "" | 0 | 0.000000) return 1 ;;
    *) return 0 ;;
  esac
}

_probe_http_ok() {
  case "$(_probe_field "$1" 3)" in
    2?? | 401 | 404) return 0 ;;
    3??) ! _probe_redirect_is_block "$1" ;;
    *) return 1 ;;
  esac
}

_probe_redirect_is_block() {
  printf '%s' "$(_probe_field "$1" 5)" | grep -qiE "$PROBE_BLOCK_REDIRECT"
}

# dead: failed before the origin spoke (the censor's doing, zapret's job).
# blocked: the origin answered and refused (a proxy hop can fix it).
_probe_exit_verdict() {
  if ! _probe_tls_ok "$1" || [ "$(_probe_field "$1" 3)" = "000" ]; then
    printf 'dead'
  elif _probe_http_ok "$1"; then
    printf 'ok'
  else
    printf 'blocked'
  fi
}

_probe_verdict() {
  local direct via
  direct="$(_probe_exit_verdict "$1")"
  via="$(_probe_exit_verdict "$2")"
  if [ "$direct" = ok ]; then
    printf 'ok'
  elif [ "$via" = ok ]; then
    if [ "$direct" = dead ]; then printf 'censor'; else printf 'destination'; fi
  elif [ "$direct" = dead ]; then
    printf 'unreachable'
  else
    printf 'both-fail'
  fi
}

_probe_verdict_text() {
  case "$1" in
    ok) printf 'reachable directly - nothing to do' ;;
    destination) printf 'destination-side block - route via %s' "${2:-proxy}" ;;
    censor) printf 'censor-side block - zapret2 territory, do not proxy' ;;
    both-fail) printf 'fails through every egress - not an egress problem' ;;
    unreachable) printf 'no egress reaches it at all' ;;
    *) printf 'inconclusive' ;;
  esac
}

_probe_describe() {
  local r="$1" status location
  if ! _probe_tls_ok "$r"; then
    printf 'no TLS (curl exit %s)' "$(_probe_field "$r" 1)"
    return
  fi
  status="$(_probe_field "$r" 3)"
  location="$(_probe_field "$r" 5)"
  if [ "$status" = "000" ]; then
    printf 'TLS %ss, then no response' "$(_probe_field "$r" 2)"
    return
  fi
  printf 'TLS %ss, %s, %s bytes' "$(_probe_field "$r" 2)" "$status" "$(_probe_field "$r" 4)"
  [ -n "$location" ] && printf ' -> %s' "$location"
  return 0
}

# "tag<TAB>proxy-url" per exit, in order; an empty url means this host.
_probe_exits() {
  if [ -r "$PROBE_EXITS_FILE" ]; then
    jq -r '.[] | "\(.tag)\thttp://127.0.0.1:\(.port)"' "$PROBE_EXITS_FILE"
  else
    printf 'direct\t\n'
    printf 'proxy\t%s\n' "${LOCAL_PROXY_URL:-http://127.0.0.1:1080}"
  fi
}

_probe_fetch_exit() {
  if [ -n "$3" ]; then
    _probe_fetch "$1" "$2" --proxy "$3"
  else
    _probe_fetch "$1" "$2" --noproxy '*'
  fi
}

# Walks EXIT_TAGS/EXIT_URLS (direct first) and stops at the first exit that
# gets content. Sets WALK_VERDICT, WALK_EXIT, WALK_PATH, WALK_DIRECT, WALK_VIA
# and WALK_ROWS ("tag<TAB>path<TAB>result<TAB>judgement" per request).
_probe_walk() {
  local domain="$1" path direct result judgement i first_direct=""
  WALK_ROWS=()
  WALK_EXIT=""
  WALK_VIA=""
  for path in "$PROBE_PATH" ${PROBE_PATH_FALLBACK:+"$PROBE_PATH_FALLBACK"}; do
    direct="$(_probe_fetch_exit "$domain" "$path" "${EXIT_URLS[0]}")"
    judgement="$(_probe_exit_verdict "$direct")"
    WALK_ROWS+=("${EXIT_TAGS[0]}"$'\t'"$path"$'\t'"$direct"$'\t'"$judgement")
    [ -n "$first_direct" ] || first_direct="$direct"
    if [ "$judgement" = ok ]; then
      WALK_VERDICT=ok
      WALK_PATH="$path"
      WALK_DIRECT="$direct"
      return
    fi
    for ((i = 1; i < ${#EXIT_TAGS[@]}; i++)); do
      result="$(_probe_fetch_exit "$domain" "$path" "${EXIT_URLS[i]}")"
      judgement="$(_probe_exit_verdict "$result")"
      WALK_ROWS+=("${EXIT_TAGS[i]}"$'\t'"$path"$'\t'"$result"$'\t'"$judgement")
      if [ "$judgement" = ok ]; then
        WALK_VERDICT="$(_probe_verdict "$direct" "$result")"
        WALK_EXIT="${EXIT_TAGS[i]}"
        WALK_PATH="$path"
        WALK_DIRECT="$direct"
        WALK_VIA="$result"
        return
      fi
    done
  done
  WALK_PATH="$PROBE_PATH"
  WALK_DIRECT="$first_direct"
  if [ "$(_probe_exit_verdict "$first_direct")" = dead ]; then
    WALK_VERDICT=unreachable
  else
    WALK_VERDICT=both-fail
  fi
}

# --via: can EXIT_TAGS[1] carry what direct reaches? It must get content on
# some path and fail on none where direct succeeds. Verdict "ok" or "blocked".
_probe_stand_in() {
  local domain="$1" path direct via dj vj got=0
  WALK_ROWS=()
  WALK_VERDICT=ok
  WALK_EXIT="${EXIT_TAGS[1]}"
  WALK_PATH="$PROBE_PATH"
  for path in "$PROBE_PATH" ${PROBE_PATH_FALLBACK:+"$PROBE_PATH_FALLBACK"}; do
    direct="$(_probe_fetch_exit "$domain" "$path" "${EXIT_URLS[0]}")"
    via="$(_probe_fetch_exit "$domain" "$path" "${EXIT_URLS[1]}")"
    dj="$(_probe_exit_verdict "$direct")"
    vj="$(_probe_exit_verdict "$via")"
    WALK_ROWS+=("${EXIT_TAGS[0]}"$'\t'"$path"$'\t'"$direct"$'\t'"$dj")
    WALK_ROWS+=("${EXIT_TAGS[1]}"$'\t'"$path"$'\t'"$via"$'\t'"$vj")
    if [ "$path" = "$PROBE_PATH" ]; then
      WALK_DIRECT="$direct"
      WALK_VIA="$via"
    fi
    [ "$vj" != ok ] || got=1
    if [ "$dj" = ok ] && [ "$vj" != ok ]; then WALK_VERDICT=blocked; fi
  done
  [ "$got" = 1 ] || WALK_VERDICT=blocked
}

cmd_proxy_probe() {
  local json=0 domain="" want="" have_want=0 via="" row tag
  local -a rows wanted
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --exits)
        want="${2?--exits needs a comma-separated list of exit tags}"
        have_want=1
        shift
        ;;
      --via)
        via="${2?--via needs an exit tag}"
        want="$via"
        have_want=1
        shift
        ;;
      -*) _die "Unknown option: $1" ;;
      *) domain="$1" ;;
    esac
    shift
  done

  [ -n "$domain" ] || _usage "proxy auto probe <domain>[/path] [--json] [--exits a,b | --via tag]"
  domain="${domain#*://}"
  if [[ "$domain" == */* ]]; then
    local PROBE_PATH="/${domain#*/}" PROBE_PATH_FALLBACK=""
    domain="${domain%%/*}"
  fi

  _svc_active proxy-suite-socks || _die "The local proxy (proxy-suite-socks) is not running; a probe needs its exits."

  # direct first, then every exit in order, or the ones asked for in that order.
  mapfile -t rows < <(_probe_exits)
  EXIT_TAGS=()
  EXIT_URLS=()
  for row in "${rows[@]}"; do
    if [ "${row%%$'\t'*}" = direct ]; then
      EXIT_TAGS+=(direct)
      EXIT_URLS+=("${row#*$'\t'}")
    fi
  done
  if [ "$have_want" = 1 ]; then
    IFS=, read -ra wanted <<<"$want"
  else
    wanted=()
    for row in "${rows[@]}"; do wanted+=("${row%%$'\t'*}"); done
  fi
  for tag in "${wanted[@]}"; do
    [ "$tag" = direct ] && continue
    for row in "${rows[@]}"; do
      if [ "${row%%$'\t'*}" = "$tag" ]; then
        EXIT_TAGS+=("$tag")
        EXIT_URLS+=("${row#*$'\t'}")
        break
      fi
    done
  done
  if [ "${#EXIT_TAGS[@]}" -eq 0 ] || [ "${EXIT_TAGS[0]}" != direct ]; then
    _die "No direct exit to probe from ($PROBE_EXITS_FILE)."
  fi
  if [ -n "$via" ] && [ "${#EXIT_TAGS[@]}" -ne 2 ]; then
    _die "No exit named $via other than direct ($PROBE_EXITS_FILE)."
  fi

  if [ -n "$via" ]; then
    _probe_stand_in "$domain"
  else
    _probe_walk "$domain"
  fi

  if [ "$json" = 1 ]; then
    printf '%s\n' "${WALK_ROWS[@]}" | jq -R -s -c \
      --arg domain "$domain" \
      --arg url "https://${domain}${WALK_PATH}" \
      --arg path "$WALK_PATH" \
      --arg verdict "$WALK_VERDICT" \
      --arg exit "$WALK_EXIT" \
      --arg direct "$WALK_DIRECT" \
      --arg via "$WALK_VIA" '
      (split("\n") | map(select(length > 0) | split("\t")
        | {tag: .[0], path: .[1], result: .[2], judgement: .[3]})) as $exits
      | {domain: $domain, url: $url, path: $path, verdict: $verdict,
         exit: (if $exit == "" then null else $exit end),
         direct: $direct, proxy: $via, exits: $exits}'
    return
  fi

  local t p r j chosen
  printf '  domain     %s\n' "$domain"
  printf '  probe      https://%s%s\n' "$domain" "$WALK_PATH"
  printf '  exits\n'
  for row in "${WALK_ROWS[@]}"; do
    IFS=$'\t' read -r t p r j <<<"$row"
    chosen=""
    [ "$t" = "$WALK_EXIT" ] && [ "$p" = "$WALK_PATH" ] && chosen="  <- chosen"
    printf '    %-18s %-12s %-44s %s%s\n' "$t" "$p" "$(_probe_describe "$r")" "$j" "$chosen"
  done
  if [ -n "$via" ]; then
    if [ "$WALK_VERDICT" = ok ]; then
      printf '  verdict    %s answers it as well as direct does - it can carry it\n' "$via"
    else
      printf '  verdict    %s answers it worse than direct does\n' "$via"
    fi
    return
  fi
  printf '  verdict    %s\n' "$(_probe_verdict_text "$WALK_VERDICT" "$WALK_EXIT")"
  case "$WALK_VERDICT" in
    destination)
      printf '             pin: proxy.routing.rules = [ { outbound = "%s"; domains = [ "%s" ]; } ]\n' \
        "$WALK_EXIT" "$domain"
      ;;
    censor)
      printf '             try: proxy-ctl zapret auto add %s\n' "$domain"
      ;;
  esac
}

_autoproxy_dir() {
  printf '%s' "${AUTOPROXY_STATE_DIR:-/var/lib/proxy-suite/autoproxy}"
}

_require_autoproxy() {
  [ "${AUTOPROXY_ENABLED:-0}" = 1 ] || _die "proxy.autoProxy is not enabled in this configuration."
}

# Root-only without userControl: say so rather than show an empty queue.
_require_autoproxy_readable() {
  [ -d "$1" ] || _die "No autoProxy state yet - the prober has not completed a run."
  { [ -x "$1" ] && [ -r "$1" ]; } || _die "Cannot read $1 - enable userControl, or run with sudo."
}

cmd_proxy_auto() {
  local verb="${1:-list}"
  shift || true
  case "$verb" in
    list | learned) cmd_proxy_learned ;;
    probe) cmd_proxy_probe "$@" ;;
    learn) cmd_proxy_learn "$@" ;;
    queue) cmd_proxy_queue "$@" ;;
    *) _usage "proxy auto [list|probe|learn|queue]" ;;
  esac
}

# The timer is relative, so only list-timers knows the next run. Empty when
# none is armed.
_autoproxy_next_run() {
  local next
  next="$(systemctl list-timers -o json proxy-suite-autoproxy.timer 2>/dev/null |
    jq -r '.[0].next // empty' 2>/dev/null || true)"
  if [ -n "$next" ] && [ "$next" != 0 ]; then printf '%s' "$((next / 1000000))"; fi
}

_in_time() {
  local left=$(($1 - $(date +%s)))
  if [ "$left" -lt 60 ]; then printf 'under a minute'; else printf 'in %s min' "$((left / 60))"; fi
}

cmd_proxy_queue() {
  local dir top="${1:-20}" waiting next
  _require_autoproxy
  [[ "$top" =~ ^[0-9]+$ ]] || _usage "proxy auto queue [count]"
  dir="$(_autoproxy_dir)"
  _require_autoproxy_readable "$dir"

  echo "Requested with proxy-ctl proxy auto learn:"
  if [ -s "$dir/requests" ] || [ -s "$dir/requests.taking" ]; then
    cat "$dir/requests" "$dir/requests.taking" 2>/dev/null | awk '{ print "  " $0 }'
  else
    echo "  (none)"
  fi

  waiting="$(jq '(.backlog // {}) | length' "$dir/state.json" 2>/dev/null || echo 0)"
  echo ""
  echo "Waiting to be probed, most-dialled first ($waiting):"
  if [ "$waiting" -gt 0 ]; then
    jq -r --argjson top "$top" '(.backlog // {}) | to_entries | sort_by(-.value.hits)
      | .[:$top][] | "  \(.value.hits)\t\(.key)"' "$dir/state.json"
    [ "$waiting" -le "$top" ] || echo "  ... and $((waiting - top)) more"
  else
    echo "  (none)"
  fi

  next="$(_autoproxy_next_run)"
  if [ -n "$next" ]; then
    echo ""
    echo "Next run: $(date -d "@$next" '+%H:%M:%S'), $(_in_time "$next")"
  elif [ "$(systemctl show -p ActiveState --value proxy-suite-autoproxy.service 2>/dev/null)" = activating ]; then
    echo ""
    echo "Next run: one is running now"
  fi
}

cmd_proxy_learned() {
  local dir
  _require_autoproxy
  dir="$(_autoproxy_dir)"
  _require_autoproxy_readable "$dir"

  if ! jq -e '(.domains // {}) | length > 0' "$dir/state.json" > /dev/null 2>&1; then
    echo "Nothing routed yet."
  else
    echo "Routed through an exit:"
    jq -r --argjson now "$(date +%s)" '
      .domains | to_entries | sort_by(.key)[]
      | ((($now - (.value.at // 0)) / 60) | floor) as $m
      | "\(.key)\t\(.value.exit)\t\(.value.host)\(if .value.verdict == "slow" then ", which crawled directly" else "" end)\t\(if $m < 120 then "\($m)m" else "\($m / 60 | floor)h" end)"' \
      "$dir/state.json" |
      awk -F'\t' '{ printf "  %-28s -> %-12s (learned from %s, checked %s ago)\n", $1, $2, $3, $4 }'
  fi

  echo ""
  echo "Hosts judged: $(jq -r '[(.hosts // {})[] | .verdict] | group_by(.)
    | map("\(.[0])=\(length)") | join("  ") | if . == "" then "none yet" else . end' \
    "$dir/state.json" 2>/dev/null || echo "none yet")"
}

# Queues the host for the prober's own unit, so it is recorded under the same
# lock as a timer run.
cmd_proxy_learn() {
  local host="${1:-}" dir
  _require_autoproxy
  dir="$(_autoproxy_dir)"
  # Lands in a root-owned file and then in a URL: hostnames only.
  [[ "$host" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || _usage "proxy auto learn <domain>"
  printf '%s\n' "$host" >> "$dir/requests" 2>/dev/null || _die "Cannot write $dir/requests - re-run with sudo."
  echo "Probing $host through each exit..."
  if ! systemctl start proxy-suite-autoproxy-learn.service 2> /dev/null; then
    echo "The probe run failed. $host is still queued and will be tried again at the next run." >&2
    _die "Details: journalctl -u proxy-suite-autoproxy-learn -n 20"
  fi
  jq -r --arg h "$host" '
    (.hosts // {})[$h]
    | if . == null then "No verdict recorded; see: journalctl -u proxy-suite-autoproxy-learn"
      elif .exit then "\(.domain): \(.verdict) - routed via \(.exit) from now on, no restart needed"
      else "\($h): \(.verdict) - nothing to route" end' "$dir/state.json"
}

# --- zapret ------------------------------------------------------------------

cmd_zapret() {
  if [ "${1:-}" = auto ]; then
    shift
    cmd_zapret_auto "$@"
    return
  fi
  _toggle zapret-discord-youtube zapret "$@"
}

_zapret_auto_file() {
  printf '%s/%s' "${ZAPRET_STATE_DIR:-/var/lib/proxy-suite/zapret2}" "$1"
}

# nfqws2 re-reads a list when its mtime changes; no reload needed.
_zapret_auto_edit() {
  local file="$1" domain="$2" action="$3" tmp
  if [ ! -e "$file" ] && [ "$action" = drop ]; then
    return 0
  fi
  tmp=$(mktemp "$file.XXXXXX" 2>/dev/null) || _die "Cannot write $file - re-run with sudo."
  grep -v -x -F -- "$domain" "$file" 2>/dev/null >"$tmp" || true
  if [ "$action" = add ]; then
    printf '%s\n' "$domain" >>"$tmp"
  fi
  chmod 0644 "$tmp"
  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    _die "Cannot replace $file - re-run with sudo."
  fi
}

cmd_zapret_auto() {
  local verb="${1:-list}" domain="${2:-}" auto user exclude
  [ "${ZAPRET_AUTO_ENABLED:-0}" = 1 ] || _die "Learned hostlists need zapret.engine = \"zapret2\"."
  auto=$(_zapret_auto_file zapret-hosts-auto.txt)
  user=$(_zapret_auto_file zapret-hosts-user.txt)
  exclude=$(_zapret_auto_file zapret-hosts-user-exclude.txt)

  case "$verb" in
    add | forget | exclude)
      [[ "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || _usage "zapret auto $verb <domain>"
      ;;
  esac
  case "$verb" in
    list)
      if [ -s "$auto" ]; then cat "$auto"; else echo "No hostnames learned yet."; fi
      ;;
    add)
      _zapret_auto_edit "$user" "$domain" add
      echo "Pinned $domain (always bypassed)."
      ;;
    forget)
      _zapret_auto_edit "$auto" "$domain" drop
      echo "Forgot $domain. It is learned again if it keeps failing; 'exclude' prevents that."
      ;;
    exclude)
      _zapret_auto_edit "$auto" "$domain" drop
      _zapret_auto_edit "$exclude" "$domain" add
      echo "Excluded $domain. It is no longer touched or learned."
      ;;
    clear)
      : >"$auto" 2>/dev/null || _die "Cannot write $auto - re-run with sudo."
      echo "Cleared the learned hostlist."
      ;;
    *) _usage "zapret auto [list|add|forget|exclude|clear]" ;;
  esac
}

# --- where -------------------------------------------------------------------
#
# What the runtime state says about one host. Hostlists and autoProxy both key
# on an apex, so a miss on the full name retries each parent label.

_where_row() {
  printf '  %-14s %s\n' "$1" "$2"
}

_where_parents() {
  local d="$1"
  while [ -n "$d" ]; do
    printf '%s\n' "$d"
    case "$d" in
      *.*) d="${d#*.}" ;;
      *) d="" ;;
    esac
  done
}

# The first parent of $2 that file $1 lists, empty when none is.
_where_in_list() {
  local file="$1" d
  [ -r "$file" ] || return 0
  while IFS= read -r d; do
    if grep -qxF -- "$d" "$file" 2>/dev/null; then
      printf '%s' "$d"
      return 0
    fi
  done < <(_where_parents "$2")
}

_where_in_autoproxy() {
  local state="$1" d
  while IFS= read -r d; do
    if jq -e --arg d "$d" 'has("domains") and (.domains | has($d))' "$state" > /dev/null 2>&1; then
      printf '%s' "$d"
      return 0
    fi
  done < <(_where_parents "$2")
}

cmd_where() {
  local domain="${1:-}" state hit exit_tag outbound excluded pinned learned verdict=""
  [ -n "$domain" ] || _usage "where <domain>"
  domain="${domain#*://}"
  domain="${domain%%/*}"
  _where_row domain "$domain"

  if _svc_exists proxy-suite-socks; then
    _where_row "route mode" "$(_route_mode_label "$(_route_mode_current)")"
    outbound="$(_status_outbound)"
    [ -z "$outbound" ] || _where_row outbound "$outbound"
  fi

  if [ "${AUTOPROXY_ENABLED:-0}" = 1 ]; then
    state="$(_autoproxy_dir)/state.json"
    if [ ! -r "$state" ]; then
      _where_row autoProxy "state is not readable - enable userControl, or run with sudo"
    else
      hit="$(_where_in_autoproxy "$state" "$domain")"
      if [ -z "$hit" ]; then
        _where_row autoProxy "not routed"
      else
        exit_tag="$(jq -r --arg d "$hit" '.domains[$d].exit' "$state")"
        _where_row autoProxy "$(jq -r --arg d "$hit" --argjson now "$(date +%s)" '
          .domains[$d] | ((($now - (.at // 0)) / 60) | floor) as $m
          | "routed via \(.exit), learned from \(.host), checked \(
              if $m < 120 then "\($m)m" else "\($m / 60 | floor)h" end) ago"' "$state")"
        verdict="proxied via $exit_tag"
      fi
    fi
  fi

  if [ "${ZAPRET_AUTO_ENABLED:-0}" = 1 ]; then
    excluded="$(_where_in_list "$(_zapret_auto_file zapret-hosts-user-exclude.txt)" "$domain")"
    pinned="$(_where_in_list "$(_zapret_auto_file zapret-hosts-user.txt)" "$domain")"
    learned="$(_where_in_list "$(_zapret_auto_file zapret-hosts-auto.txt)" "$domain")"
    if [ -n "$excluded" ]; then
      _where_row zapret2 "excluded ($excluded) - never bypassed, never learned"
    elif [ -n "$pinned" ]; then
      _where_row zapret2 "pinned ($pinned) - always bypassed"
      [ -n "$verdict" ] || verdict="direct, with the zapret2 bypass"
    elif [ -n "$learned" ]; then
      _where_row zapret2 "learned ($learned) - bypassed"
      [ -n "$verdict" ] || verdict="direct, with the zapret2 bypass"
    else
      _where_row zapret2 "not learned, not pinned, not excluded"
    fi
  fi

  echo "  -> ${verdict:-nothing runtime matches it; the configured routing decides}"
  echo "  Declared proxy.routing.rules are not visible here. Test what reaches it:"
  echo "    proxy-ctl proxy auto probe $domain"
}

# --- awg ---------------------------------------------------------------------

_awg_service() {
  printf 'proxy-suite-awg-%s' "$1"
}

_require_awg_profile() {
  local profile
  for profile in "${AWG_PROFILES[@]}"; do
    [ "$profile" = "$1" ] && return 0
  done
  _die "Unknown AmneziaWG profile: $1"
}

_active_awg_profiles() {
  local profile
  for profile in "${AWG_PROFILES[@]}"; do
    if _svc_active "$(_awg_service "$profile")"; then
      printf '%s\n' "$profile"
    fi
  done
}

cmd_awg() {
  local verb="${1:-list}" profile active
  shift || true
  if [ "$#" -gt 0 ]; then
    _require_awg_profile "$1"
  fi
  case "$verb" in
    list | status)
      if [ "${#AWG_PROFILES[@]}" -eq 0 ]; then
        echo "No AmneziaWG profiles configured."
        return
      fi
      printf "  %-24s %s\n" "PROFILE" "STATUS"
      for profile in "${AWG_PROFILES[@]}"; do
        active="$(systemctl is-active "$(_awg_service "$profile")" 2>/dev/null || true)"
        printf "  %-24s %s\n" "$profile" "${active:-unknown}"
      done
      ;;
    on)
      [ "$#" -gt 0 ] || _usage "awg on <profile>"
      systemctl start "$(_awg_service "$1")"
      ;;
    off | restart)
      if [ "$#" -gt 0 ]; then
        active="$1"
      else
        active="$(_active_awg_profiles)"
        if [ -z "$active" ]; then
          [ "$verb" = off ] && return
          _die "No AmneziaWG profile is active."
        fi
      fi
      [ "$verb" = off ] && verb=stop
      while IFS= read -r profile; do
        systemctl "$verb" "$(_awg_service "$profile")"
      done <<< "$active"
      ;;
    *) _usage "awg [list] | on <profile> | off [profile] | restart [profile]" ;;
  esac
}

# --- apps --------------------------------------------------------------------

_ensure_app_routing() {
  [ "${PER_APP_ROUTING_ENABLED:-0}" = "1" ] || _die "perAppRouting is not enabled in this configuration."
}

_check_no_global_proxy() {
  local svc
  for svc in proxy-suite-tun proxy-suite-tproxy; do
    if _svc_active "$svc.service"; then
      _die "Global $svc.service is active. Stop it before using route=$1 profiles."
    fi
  done
}

_cleanup_slice_if_idle() {
  local slice_base="$1" anchor_unit="$2" user_svc="$3" backend_svc="$4"
  if ! systemctl --user list-units --type=scope --state=running --plain --no-legend "$slice_base-*" | grep -q .; then
    systemctl stop "$user_svc" || true
    systemctl --user stop "$anchor_unit" || true
    if ! systemctl list-units --type=service --state=active --plain --no-legend "$slice_base-user@*.service" | grep -q .; then
      systemctl stop "$backend_svc" || true
    fi
  fi
}

# _wrap_slice <slice_base> <profile> <enabled> <disabled_msg> <backend_svc> <cmd...>
_wrap_slice() {
  local slice_base="$1" profile="$2" enabled="$3" disabled_msg="$4" backend_svc="$5"
  shift 5
  [ "$enabled" = "1" ] || _die "$disabled_msg"
  local uid; uid="$(id -u)"
  local scope_unit="$slice_base-${profile}-$$"
  local anchor_unit="$slice_base-anchor.service"
  local user_svc="$slice_base-user@$uid.service"
  local status=0

  cleanup_slice() {
    _cleanup_slice_if_idle "$slice_base" "$anchor_unit" "$user_svc" "$backend_svc"
  }
  trap cleanup_slice EXIT

  systemctl --user start "$anchor_unit" || status=$?
  [ "$status" -ne 0 ] || systemctl start "$backend_svc" || status=$?
  [ "$status" -ne 0 ] || systemctl start "$user_svc" || status=$?
  if [ "$status" -eq 0 ]; then
    systemd-run --user --scope --quiet --collect --same-dir \
      --slice="$slice_base" --unit="$scope_unit" "$@" || status=$?
  fi
  exit "$status"
}

cmd_apps() {
  local verb="${1:-list}"
  shift || true
  _ensure_app_routing
  case "$verb" in
    list)
      if [ "$(jq 'length' "$PER_APP_ROUTING_PROFILES_FILE")" -eq 0 ]; then
        echo "No perAppRouting profiles configured."
        return
      fi
      printf "  %-24s %s\n" "PROFILE" "ROUTE"
      jq -r '.[] | "\(.name)\t\(.route)"' "$PER_APP_ROUTING_PROFILES_FILE" |
        awk -F'\t' '{ printf "  %-24s %s\n", $1, $2 }'
      ;;
    run) cmd_apps_run "$@" ;;
    *) _usage "apps [list] | run <profile> -- <cmd> [args]" ;;
  esac
}

cmd_apps_run() {
  local profile="${1:-}" route
  shift || true
  [ "${1:-}" != "--" ] || shift
  { [ -n "$profile" ] && [ "$#" -gt 0 ]; } || _usage "apps run <profile> -- <cmd> [args]"

  route="$(jq -r --arg name "$profile" '.[] | select(.name == $name) | .route' "$PER_APP_ROUTING_PROFILES_FILE")"
  [ -n "$route" ] || _die "Unknown perAppRouting profile: $profile"

  case "$route" in
    direct) exec "$@" ;;
    proxychains)
      [ "$PER_APP_ROUTING_PROXYCHAINS_ENABLED" = "1" ] ||
        _die "Profile '$profile' uses route=proxychains, but perAppRouting.proxychains.enable is false."
      [ -r "$PROXYCHAINS_CONFIG" ] ||
        _die "Proxychains config is not readable: $PROXYCHAINS_CONFIG (is proxy-suite-socks running?)"
      exec proxychains4 $PROXYCHAINS_QUIET_ARG -f "$PROXYCHAINS_CONFIG" "$@"
      ;;
    tun)
      _check_no_global_proxy tun
      _wrap_slice "proxy-suite-per-app-tun" "$profile" "$PER_APP_ROUTING_TUN_ENABLED" \
        "Profile '$profile' uses route=tun, but perAppRouting.tun.enable is false." \
        "proxy-suite-per-app-tun.service" "$@"
      ;;
    tproxy)
      _check_no_global_proxy tproxy
      _wrap_slice "proxy-suite-per-app-tproxy" "$profile" "$PER_APP_ROUTING_TPROXY_ENABLED" \
        "Profile '$profile' uses route=tproxy, but perAppRouting.tproxy.enable is false." \
        "proxy-suite-per-app-tproxy.service" "$@"
      ;;
    zapret)
      _check_no_global_proxy zapret
      _wrap_slice "proxy-suite-per-app-zapret" "$profile" "$PER_APP_ROUTING_ZAPRET_ENABLED" \
        "Profile '$profile' uses route=zapret, but perAppRouting.zapret.enable is false." \
        "proxy-suite-per-app-zapret.service" "$@"
      ;;
    *) _die "Route backend '$route' is not implemented." ;;
  esac
}

# --- inbounds ----------------------------------------------------------------

# Links carry listener credentials, so the file is root/group-only.
_inbound_links() {
  [ -f "$INBOUNDS_LINKS_FILE" ] ||
    _die "No share links available. Is proxy-suite-inbounds running, and is inbounds.shareLinks enabled?"
  [ -r "$INBOUNDS_LINKS_FILE" ] || _die "Share links are not readable by this user. Enable userControl, or run as root."
  cat "$INBOUNDS_LINKS_FILE"
}

_inbound_link_for() {
  local tag="$1" user="${2:-}" matches count
  matches="$(_inbound_links | jq -c --arg tag "$tag" --arg user "$user" '[.[] | select(.tag == $tag) | select($user == "" or .user == $user)]')"
  count="$(jq 'length' <<< "$matches")"
  [ "$count" -ne 0 ] || _die "Unknown inbound, or no share link for it: $tag"
  if [ "$count" -ne 1 ]; then
    echo "Multiple users match '$tag'; specify one of:" >&2
    jq -r '.[].user' <<< "$matches" | sed 's/^/  /' >&2
    exit 1
  fi
  jq -r '.[0].link' <<< "$matches"
}

# Per-user traffic over the last $1 days, newest first, then totals.
_inbound_stats() {
  local days="$1" file="${INBOUNDS_STATS_FILE:-/var/lib/proxy-suite/inbound-stats.json}" since
  [[ "$days" =~ ^[1-9][0-9]*$ ]] || _usage "inbounds stats [days]"
  # Collect what XRay counted since the last run first; root and userControl
  # members may, anyone else reads what the timer last wrote.
  systemctl --no-ask-password start proxy-suite-inbound-stats.service 2>/dev/null || true
  [ -e "$file" ] || _die "No traffic recorded yet - the collector runs every 5 minutes."
  [ -r "$file" ] || _die "Cannot read $file - enable userControl, or run with sudo."
  since="$(date -d "-$((days - 1)) days" +%F)"
  echo "Traffic through the inbounds since $since, by user:"
  jq -r --arg since "$since" '
    [(.days // {}) | to_entries[] | select(.key >= $since) | .key as $d
      | .value | to_entries[] | [$d, .key, (.value.down // 0), (.value.up // 0)]]
    | (group_by(.[0]) | reverse | .[] | sort_by(.[1])[] | "day\t" + (map(tostring) | join("\t"))),
      (group_by(.[1])[] | "total\t\t\(.[0][1])\t\(map(.[2]) | add)\t\(map(.[3]) | add)")' "$file" |
    awk -F'\t' '
      function h(b) {
        if (b >= 1073741824) return sprintf("%.1f GiB", b / 1073741824)
        if (b >= 1048576) return sprintf("%.1f MiB", b / 1048576)
        if (b >= 1024) return sprintf("%.0f KiB", b / 1024)
        return b " B"
      }
      $1 == "day" {
        if (!d++) printf "  %-12s %-20s %10s %10s\n", "DAY", "USER", "DOWN", "UP"
        printf "  %-12s %-20s %10s %10s\n", $2, $3, h($4), h($5)
      }
      $1 == "total" {
        if (!t++) printf "\n  %-33s %10s %10s\n", "TOTAL", "DOWN", "UP"
        printf "  %-33s %10s %10s\n", $3, h($4), h($5)
      }
      END { if (!d) print "  (nothing recorded)" }'
}

# Without a user: user names only, since each URL is its user's secret.
_inbound_subscriptions() {
  local user="" qr=0 file="${INBOUNDS_SUBS_FILE:-/run/proxy-suite-inbounds/subscriptions.json}"
  local base="${INBOUNDS_SUB_BASE_URL:-}" arg token
  for arg; do
    case "$arg" in
      --qr) qr=1 ;;
      *) user="$arg" ;;
    esac
  done
  [ -f "$file" ] ||
    _die "No subscriptions available. Is proxy-suite-inbounds running, and is inbounds.subscriptions enabled?"
  [ -r "$file" ] || _die "Subscriptions are not readable by this user. Enable userControl, or run as root."
  if [ -z "$user" ]; then
    [ "$qr" = 0 ] || _usage "inbounds sub <user> --qr"
    jq -r '.[] | "  " + .user' "$file"
    echo "Show one with: proxy-ctl inbounds sub <user> [--qr]" >&2
    return
  fi
  token="$(jq -r --arg u "$user" 'first(.[] | select(.user == $u) | .token) // empty' "$file")"
  [ -n "$token" ] || _die "No subscription for user: $user"
  if [ -n "$base" ]; then
    _emit "${base%/}/$token" "$qr"
  else
    [ "$qr" = 0 ] || _die "A QR code needs inbounds.subscriptions.baseUrl."
    echo "${file%.json}/$token"
    echo "Set inbounds.subscriptions.baseUrl to get a URL instead of a path." >&2
  fi
}

cmd_inbounds() {
  local verb="${1:-list}" qr=0 arg link state
  local -a args=()
  shift || true
  [ "${INBOUNDS_ENABLED:-0}" = 1 ] || _die "inbounds is not enabled in this configuration."
  case "$verb" in
    list)
      state="$(systemctl is-active proxy-suite-inbounds 2>/dev/null || true)"
      printf "  %-24s %-16s %-14s %-8s %s\n" TAG USER TYPE PORT STATE
      _inbound_links \
        | jq -r --arg state "$state" '.[] | "\(.tag)\t\(.user)\t\(.type)\t\(.port)\t\($state)"' \
        | awk -F'\t' '{printf "  %-24s %-16s %-14s %-8s %s\n", $1, $2, $3, $4, $5}'
      ;;
    link | qr)
      [ "$verb" = link ] || qr=1
      for arg; do
        if [ "$arg" = --qr ]; then qr=1; else args+=("$arg"); fi
      done
      [ "${#args[@]}" -gt 0 ] || _usage "inbounds link <tag> [user] [--qr]"
      link="$(_inbound_link_for "${args[@]}")"
      _emit "$link" "$qr"
      ;;
    stats) _inbound_stats "${1:-7}" ;;
    sub) _inbound_subscriptions "$@" ;;
    *) _usage "inbounds [list] | link <tag> [user] [--qr] | sub [user] [--qr] | stats [days]" ;;
  esac
}
