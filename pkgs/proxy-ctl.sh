set -euo pipefail

# Wrapped binary provides runtime config through env vars.
SUB_TAGS_FILE="${SUB_TAGS_FILE:-}"
PROXYCHAINS_QUIET_ARG="${PROXYCHAINS_QUIET_ARG:-}"
SUB_TAGS=()

if [ -n "$SUB_TAGS_FILE" ] && [ -f "$SUB_TAGS_FILE" ]; then
  mapfile -t SUB_TAGS < <(jq -r '.[]' "$SUB_TAGS_FILE")
fi

cmd="${1:-status}"
shift || true

case "$cmd" in
  help)
    _usage 0
    ;;

  status)
    cmd_status "$@"
    ;;

  proxy)
    cmd_proxy "$@"
    ;;

  tproxy)
    cmd_mode_toggle proxy-suite-tproxy on "${1:-}"
    ;;

  tun)
    cmd_mode_toggle proxy-suite-tun on "${1:-}"
    ;;

  zapret)
    cmd_zapret "$@"
    ;;

  restart)
    cmd_restart
    ;;

  logs)
    svc="${1:-proxy-suite-socks}"
    shift || true
    exec journalctl -fu "$svc" "$@"
    ;;

  outbounds)
    cmd_outbounds
    ;;

  select)
    cmd_select "$@"
    ;;

  apps)
    cmd_apps
    ;;

  wrap)
    cmd_wrap "$@"
    ;;

  subscription)
    cmd_subscription "$@"
    ;;

  *)
    _usage 1
    ;;
esac
