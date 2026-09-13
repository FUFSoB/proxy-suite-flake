set -euo pipefail

PROXYCHAINS_QUIET_ARG="${PROXYCHAINS_QUIET_ARG:-}"
SUB_TAGS=()
AWG_PROFILES=()
if [ -f "${SUB_TAGS_FILE:-}" ]; then
  mapfile -t SUB_TAGS < <(jq -r '.[]' "$SUB_TAGS_FILE")
fi
if [ -f "${AWG_PROFILES_FILE:-}" ]; then
  mapfile -t AWG_PROFILES < <(jq -r '.[]' "$AWG_PROFILES_FILE")
fi

# Old spellings: still accepted, not in the help.
case "${1:-}" in
  tun | tproxy | outbounds | select) set -- proxy "$@" ;;
  route-mode) shift; set -- proxy mode "$@" ;;
  subscription) shift; set -- proxy subs "$@" ;;
  wrap) shift; set -- apps run "$@" ;;
esac

cmd="${1:-status}"
shift || true

case "$cmd" in
  help | -h | --help) _help ;;
  status) cmd_status "$@" ;;
  restart) cmd_restart ;;
  logs)
    if [ "$#" -gt 0 ]; then exec journalctl -fu "$@"; fi
    # journalctl takes unit globs, so the default needs no unit list of its own.
    exec journalctl -f -u 'proxy-suite-*' -u zapret-discord-youtube
    ;;
  proxy) cmd_proxy "$@" ;;
  zapret) cmd_zapret "$@" ;;
  awg) cmd_awg "$@" ;;
  ssh) _toggle proxy-suite-ssh-proxy ssh "$@" ;;
  apps) cmd_apps "$@" ;;
  inbounds) cmd_inbounds "$@" ;;
  where) cmd_where "$@" ;;
  __complete) cmd_complete "$@" ;;
  *)
    _help >&2
    exit 1
    ;;
esac
