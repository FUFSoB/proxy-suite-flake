set -euo pipefail

# Wrapped binary provides runtime config through env vars.
SUB_TAGS_RAW="${SUB_TAGS_RAW:-}"
PROXYCHAINS_QUIET_ARG="${PROXYCHAINS_QUIET_ARG:-}"
# shellcheck disable=SC2206
SUB_TAGS=(${SUB_TAGS_RAW})

ALL_SERVICES=(
  proxy-suite-socks
  proxy-suite-tproxy
  proxy-suite-tun
  proxy-suite-tg-ws-proxy
  proxy-suite-zapret-vm-exempt
  zapret-discord-youtube
)

_usage() {
  local status="${1:-1}"
  echo "Usage: proxy-ctl <command> [args]"
  echo ""
  echo "Commands:"
  echo "  help                      show this help message"
  echo "  status [--tray]           show status of all proxy-suite services"
  echo "  proxy on|off              enable/disable the core SOCKS proxy"
  echo "  tproxy on|off             enable/disable TProxy transparent mode"
  echo "  tun on|off                enable/disable TUN mode"
  echo "  zapret on|off             enable/disable zapret-discord-youtube"
  echo "  restart                   restart active global proxy-suite services"
  echo "  logs [service]            follow service logs  (default: proxy-suite-socks)"
  echo "  outbounds                 list outbounds and current selection"
  echo "  select <tag>              switch to a specific outbound  (selector mode)"
  echo "  apps                      list configured per-app routing profiles"
  echo "  wrap <profile> -- <cmd>   run a command via a perAppRouting profile"
  echo "  subscription list         show subscriptions, cache age, and proxy count"
  echo "  subscription update       force-refresh all subscription caches and restart"
  exit "$status"
}

_svc_status() {
  local svc="$1"
  if ! systemctl cat "$svc" &>/dev/null; then
    return
  fi
  local state
  state=$(systemctl is-active "$svc" 2>/dev/null || true)
  printf "  %-44s %s\n" "$svc" "$state"
}

_bool() {
  if "$@"; then
    printf true
  else
    printf false
  fi
}

_svc_exists() {
  systemctl cat "$1" &>/dev/null
}

_svc_active() {
  systemctl is-active --quiet "$1"
}

_status_tray() {
  printf 'socks_available=%s\n' "$(_bool _svc_exists proxy-suite-socks)"
  printf 'socks_active=%s\n' "$(_bool _svc_active proxy-suite-socks)"
  printf 'tproxy_available=%s\n' "$(_bool _svc_exists proxy-suite-tproxy)"
  printf 'tproxy_active=%s\n' "$(_bool _svc_active proxy-suite-tproxy)"
  printf 'tun_available=%s\n' "$(_bool _svc_exists proxy-suite-tun)"
  printf 'tun_active=%s\n' "$(_bool _svc_active proxy-suite-tun)"
  printf 'zapret_available=%s\n' "$(_bool _svc_exists zapret-discord-youtube)"
  printf 'zapret_active=%s\n' "$(_bool _svc_active zapret-discord-youtube)"
  printf 'subscription_update_available=%s\n' "$(_bool _svc_exists proxy-suite-subscription-update)"
}

_ensure_app_routing() {
  if [ "$PER_APP_ROUTING_ENABLED" != "1" ]; then
    echo "perAppRouting is not enabled in services.proxy-suite.perAppRouting."
    exit 1
  fi
}

_profile_route() {
  local profile="$1"
  jq -r --arg name "$profile" '.[] | select(.name == $name) | .route' "$PER_APP_ROUTING_PROFILES_FILE"
}

_scope_running() {
  systemctl --user list-units --type=scope --state=running --plain --no-legend "$1-*" \
    | grep -q .
}

_any_user_active() {
  systemctl list-units --type=service --state=active --plain --no-legend "$1*.service" \
    | grep -q .
}

_check_no_global_proxy() {
  if systemctl is-active --quiet proxy-suite-tun.service; then
    echo "Global proxy-suite-tun.service is active. Stop it before using route=$1 profiles."
    exit 1
  fi
  if systemctl is-active --quiet proxy-suite-tproxy.service; then
    echo "Global proxy-suite-tproxy.service is active. Stop it before using route=$1 profiles."
    exit 1
  fi
}

# _wrap_slice <slice_base> <enabled_var> <disabled_msg> <backend_svc> [cmd...]
_wrap_slice() {
  local slice_base="$1" enabled="$2" disabled_msg="$3" backend_svc="$4"
  shift 4
  if [ "$enabled" != "1" ]; then
    echo "$disabled_msg"
    exit 1
  fi
  local uid; uid="$(id -u)"
  local scope_unit="$slice_base-${profile}-$$"
  local anchor_unit="$slice_base-anchor.service"
  local user_svc="$slice_base-user@$uid.service"

  systemctl --user start "$anchor_unit"
  systemctl start "$backend_svc"
  systemctl start "$user_svc"

  local status=0
  systemd-run --user --scope --quiet --collect --same-dir \
    --slice="$slice_base" --unit="$scope_unit" "$@" || status=$?

  if ! _scope_running "$slice_base"; then
    systemctl stop "$user_svc" || true
    systemctl --user stop "$anchor_unit" || true
    if ! _any_user_active "$slice_base-user@"; then
      systemctl stop "$backend_svc" || true
    fi
  fi
  exit "$status"
}

cmd="${1:-status}"
shift || true

case "$cmd" in
  help)
    _usage 0
    ;;

  status)
    if [ "${1:-}" = "--tray" ]; then
      _status_tray
    else
      echo "proxy-suite services:"
      for svc in "${ALL_SERVICES[@]}"; do
        _svc_status "$svc"
      done
    fi
    ;;

  proxy)
    case "${1:-on}" in
      on)
        systemctl start proxy-suite-socks
        ;;
      off)
        systemctl stop proxy-suite-tproxy || true
        systemctl stop proxy-suite-tun || true
        systemctl stop proxy-suite-socks
        ;;
      *)
        echo "Usage: proxy-ctl proxy on|off"; exit 1 ;;
    esac
    ;;

  tproxy)
    case "${1:-on}" in
      on)  systemctl start proxy-suite-tproxy ;;
      off) systemctl stop  proxy-suite-tproxy ;;
      *)   echo "Usage: proxy-ctl tproxy on|off"; exit 1 ;;
    esac
    ;;

  tun)
    case "${1:-on}" in
      on)  systemctl start proxy-suite-tun ;;
      off) systemctl stop  proxy-suite-tun ;;
      *)   echo "Usage: proxy-ctl tun on|off"; exit 1 ;;
    esac
    ;;

  zapret)
    case "${1:-on}" in
      on)  systemctl start zapret-discord-youtube ;;
      off) systemctl stop  zapret-discord-youtube ;;
      *)   echo "Usage: proxy-ctl zapret on|off"; exit 1 ;;
    esac
    ;;

  restart)
    systemctl restart proxy-suite-socks
    if systemctl is-active --quiet proxy-suite-tproxy; then
      systemctl restart proxy-suite-tproxy
    fi
    if systemctl is-active --quiet proxy-suite-tun; then
      systemctl restart proxy-suite-tun
    fi
    if systemctl is-active --quiet zapret-discord-youtube; then
      systemctl restart zapret-discord-youtube
    fi
    ;;

  logs)
    svc="${1:-proxy-suite-socks}"
    shift || true
    exec journalctl -fu "$svc" "$@"
    ;;

  outbounds)
    data=$(curl -sf "$CLASH_API/proxies/proxy" 2>/dev/null) || {
      echo "Clash API not available."
      echo "  - Make sure proxy-suite-socks is running"
      echo "  - selection must be 'selector' or 'urltest' (currently: $SELECTION)"
      exit 1
    }
    now=$(echo "$data" | jq -r '.now // "n/a"')
    ob_type=$(echo "$data" | jq -r '.type // "n/a"')
    echo "Type:    $ob_type"
    echo "Current: $now"
    echo ""
    echo "Available:"
    echo "$data" | jq -r '.all[]? | "  " + .'
    ;;

  select)
    tag="${1:?Usage: proxy-ctl select <outbound-tag>}"
    if [ "$SELECTION" != "selector" ]; then
      echo "selection must be 'selector' (currently: $SELECTION)"
      exit 1
    fi
    payload=$(jq -cn --arg name "$tag" '{name:$name}')
    if curl -sf -X PUT "$CLASH_API/proxies/proxy" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null; then
      echo "Switched to: $tag"
    else
      echo "Failed – is proxy-suite-socks running with selector mode?"
      exit 1
    fi
    ;;

  apps)
    _ensure_app_routing
    if [ "$(jq 'length' "$PER_APP_ROUTING_PROFILES_FILE")" -eq 0 ]; then
      echo "No perAppRouting profiles configured."
    else
      printf "  %-24s %s\n" "PROFILE" "ROUTE"
      jq -r '.[] | "  " + (.name | tostring) + "\t" + (.route | tostring)' \
        "$PER_APP_ROUTING_PROFILES_FILE" \
        | while IFS=$'\t' read -r profile route; do
            printf "%-26s %s\n" "$profile" "$route"
          done
    fi
    ;;

  wrap)
    profile="${1:?Usage: proxy-ctl wrap <profile> -- <command> [args...]}"
    shift || true
    if [ "${1:-}" = "--" ]; then
      shift
    fi
    if [ "$#" -eq 0 ]; then
      echo "Usage: proxy-ctl wrap <profile> -- <command> [args...]"
      exit 1
    fi

    _ensure_app_routing
    route="$(_profile_route "$profile")"
    if [ -z "$route" ] || [ "$route" = "null" ]; then
      echo "Unknown perAppRouting profile: $profile"
      exit 1
    fi

    case "$route" in
      direct)
        exec "$@"
        ;;
      proxychains)
        if [ "$PER_APP_ROUTING_PROXYCHAINS_ENABLED" != "1" ]; then
          echo "Profile '$profile' uses route=proxychains, but perAppRouting.proxychains.enable is false."
          exit 1
        fi
        exec proxychains4 $PROXYCHAINS_QUIET_ARG -f "$PROXYCHAINS_CONFIG" "$@"
        ;;
      tun)
        _wrap_slice "proxy-suite-per-app-tun" "$PER_APP_ROUTING_TUN_ENABLED" \
          "Profile '$profile' uses route=tun, but singBox.tun.perApp.enable is false." \
          "proxy-suite-per-app-tun.service" "$@"
        ;;
      tproxy)
        _check_no_global_proxy tproxy
        _wrap_slice "proxy-suite-per-app-tproxy" "$PER_APP_ROUTING_TPROXY_ENABLED" \
          "Profile '$profile' uses route=tproxy, but singBox.tproxy.perApp.enable is false." \
          "proxy-suite-per-app-tproxy.service" "$@"
        ;;
      zapret)
        _check_no_global_proxy zapret
        _wrap_slice "proxy-suite-per-app-zapret" "$PER_APP_ROUTING_ZAPRET_ENABLED" \
          "Profile '$profile' uses route=zapret, but zapret.perApp.enable or zapret.enable is false." \
          "proxy-suite-per-app-zapret.service" "$@"
        ;;
      *)
        echo "Route backend '$route' is not implemented in this build."
        exit 1
        ;;
    esac
    ;;

  subscription)
    subcmd="${1:-list}"
    shift || true
    case "$subcmd" in
      list)
        CACHE_DIR="/var/lib/proxy-suite/subscriptions"
        if [ ${#SUB_TAGS[@]} -eq 0 ]; then
          echo "No subscriptions configured."
        else
          printf "  %-30s %-22s %s\n" "TAG" "LAST UPDATED" "PROXIES"
          for t in "${SUB_TAGS[@]}"; do
            cache="$CACHE_DIR/$t.json"
            if [ -f "$cache" ]; then
              age=$(date -r "$cache" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
              count=$(jq 'length' "$cache" 2>/dev/null || echo "?")
            else
              age="(no cache)"
              count="-"
            fi
            printf "  %-30s %-22s %s\n" "$t" "$age" "$count"
          done
        fi
        ;;
      update)
        systemctl start proxy-suite-subscription-update
        echo "Subscription update triggered. Follow with: proxy-ctl logs proxy-suite-subscription-update"
        ;;
      *)
        echo "Usage: proxy-ctl subscription list|update"; exit 1 ;;
    esac
    ;;

  *)
    _usage 1
    ;;
esac
