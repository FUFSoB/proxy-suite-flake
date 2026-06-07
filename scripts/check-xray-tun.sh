#!/usr/bin/env bash
set -euo pipefail

PROXY_CTL="${PROXY_CTL:-proxy-ctl}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
JOURNALCTL="${JOURNALCTL:-journalctl}"
IP_BIN="${IP_BIN:-ip}"
NFT_BIN="${NFT_BIN:-nft}"
CURL_BIN="${CURL_BIN:-curl}"
TARGET_URL="${TARGET_URL:-https://whatismyipaddress.com/}"
PER_APP_TUN_PROFILE="${PER_APP_TUN_PROFILE:-tun}"
PER_APP_TPROXY_PROFILE="${PER_APP_TPROXY_PROFILE:-tproxy}"
XRAY_LOGLEVEL_FILE="${XRAY_LOGLEVEL_FILE:-/run/proxy-suite/xray-loglevel}"
ROUTE_MODE_FILE="${ROUTE_MODE_FILE:-/run/proxy-suite/route-mode}"

usage() {
  cat <<'EOF'
Usage: check-xray-tun.sh [output-dir]

Runs four native XRay regression probes:
  - global TUN
  - per-app TUN
  - global TProxy
  - per-app TProxy

The script toggles proxy-suite modes while it runs and writes captures under the
chosen output directory.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

capture_cmd() {
  local output="$1"
  local status=0
  shift

  if "$@" >"$output" 2>&1; then
    return 0
  else
    status=$?
  fi

  {
    echo
    echo "[exit=$status] $*"
  } >>"$output"
}

capture_path() {
  local source="$1"
  local target="$2"

  if [ -e "$source" ]; then
    cp -a "$source" "$target"
  else
    printf 'missing: %s\n' "$source" >"$target"
  fi
}

service_active() {
  "$SYSTEMCTL" is-active --quiet "$1"
}

set_global_mode() {
  local mode="$1"

  case "$mode" in
    tun)
      "$PROXY_CTL" proxy on
      "$PROXY_CTL" tproxy off || true
      "$PROXY_CTL" tun on
      ;;
    tproxy)
      "$PROXY_CTL" proxy on
      "$PROXY_CTL" tun off || true
      "$PROXY_CTL" tproxy on
      ;;
    off)
      "$PROXY_CTL" tun off || true
      "$PROXY_CTL" tproxy off || true
      ;;
    *)
      echo "unsupported global mode: $mode" >&2
      exit 1
      ;;
  esac
}

capture_state() {
  local probe_dir="$1"
  local since="$2"
  local config_path="$3"
  shift 3
  local services=("$@")

  capture_path "$config_path" "$probe_dir/config.json"
  capture_path "$ROUTE_MODE_FILE" "$probe_dir/route-mode.txt"
  capture_path "$XRAY_LOGLEVEL_FILE" "$probe_dir/xray-loglevel.txt"

  capture_cmd "$probe_dir/ip-rule.txt" "$IP_BIN" rule show
  capture_cmd "$probe_dir/ip-route-all.txt" "$IP_BIN" -4 route show table all
  capture_cmd "$probe_dir/ip-addr.txt" "$IP_BIN" -4 addr show
  capture_cmd "$probe_dir/nft-ruleset.txt" "$NFT_BIN" list ruleset

  for svc in "${services[@]}"; do
    capture_cmd "$probe_dir/journal-${svc}.log" "$JOURNALCTL" -u "$svc" --since "$since" --no-pager
  done
}

run_global_probe() {
  local mode="$1"
  local probe_dir="$OUTPUT_DIR/$mode"
  local config_path="$2"
  shift 2
  local services=("$@")
  local since=""
  local curl_status=0

  mkdir -p "$probe_dir"

  set_global_mode "${mode#global-}"
  sleep 2
  since="$(date --iso-8601=seconds)"
  if "$CURL_BIN" -4 -L -sS --max-time 20 -D "$probe_dir/headers.txt" -o "$probe_dir/body.html" "$TARGET_URL" >"$probe_dir/stdout.txt" 2>"$probe_dir/stderr.txt"; then
    :
  else
    curl_status=$?
  fi
  printf '%s\n' "$curl_status" >"$probe_dir/curl-exit-code.txt"
  capture_state "$probe_dir" "$since" "$config_path" "${services[@]}"
  set_global_mode off
}

make_wrapped_probe_script() {
  local probe_dir="$1"
  local script_path="$probe_dir/run-probe.sh"

  cat >"$script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
status=0
if ${CURL_BIN@Q} -4 -L -sS --max-time 20 -D ${probe_dir@Q}/headers.txt -o ${probe_dir@Q}/body.html ${TARGET_URL@Q} >${probe_dir@Q}/stdout.txt 2>${probe_dir@Q}/stderr.txt; then
  :
else
  status=\$?
fi
printf '%s\n' "\$status" >${probe_dir@Q}/curl-exit-code.txt
sleep 5
exit "\$status"
EOF
  chmod 755 "$script_path"
  printf '%s\n' "$script_path"
}

run_per_app_probe() {
  local mode="$1"
  local profile="$2"
  local config_path="$3"
  shift 3
  local services=("$@")
  local probe_dir="$OUTPUT_DIR/$mode"
  local probe_script=""
  local wrapped_pid=""
  local wrapped_status=0
  local since=""

  mkdir -p "$probe_dir"
  set_global_mode off
  "$PROXY_CTL" proxy on
  probe_script="$(make_wrapped_probe_script "$probe_dir")"
  since="$(date --iso-8601=seconds)"
  "$PROXY_CTL" wrap "$profile" -- "$probe_script" &
  wrapped_pid=$!
  sleep 2
  capture_state "$probe_dir" "$since" "$config_path" "${services[@]}"
  if wait "$wrapped_pid"; then
    :
  else
    wrapped_status=$?
  fi
  printf '%s\n' "$wrapped_status" >"$probe_dir/wrap-exit-code.txt"
}

restore_state() {
  if [ -n "${ORIG_XRAY_LOGLEVEL+x}" ]; then
    if [ -n "$ORIG_XRAY_LOGLEVEL" ]; then
      printf '%s\n' "$ORIG_XRAY_LOGLEVEL" >"$XRAY_LOGLEVEL_FILE"
    else
      rm -f "$XRAY_LOGLEVEL_FILE"
    fi
  fi

  if [ "$ORIG_TUN_ACTIVE" = 1 ]; then
    set_global_mode tun || true
  elif [ "$ORIG_TPROXY_ACTIVE" = 1 ]; then
    set_global_mode tproxy || true
  else
    set_global_mode off || true
    if [ "$ORIG_PROXY_ACTIVE" = 0 ]; then
      "$PROXY_CTL" proxy off || true
    fi
  fi
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

require_cmd "$PROXY_CTL"
require_cmd "$SYSTEMCTL"
require_cmd "$JOURNALCTL"
require_cmd "$IP_BIN"
require_cmd "$NFT_BIN"
require_cmd "$CURL_BIN"

OUTPUT_DIR="${1:-/tmp/proxy-suite-xray-tun-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"

ORIG_PROXY_ACTIVE=0
ORIG_TUN_ACTIVE=0
ORIG_TPROXY_ACTIVE=0
ORIG_XRAY_LOGLEVEL=""

if service_active proxy-suite-socks; then
  ORIG_PROXY_ACTIVE=1
fi
if service_active proxy-suite-tun; then
  ORIG_TUN_ACTIVE=1
fi
if service_active proxy-suite-tproxy; then
  ORIG_TPROXY_ACTIVE=1
fi
if [ -r "$XRAY_LOGLEVEL_FILE" ]; then
  ORIG_XRAY_LOGLEVEL="$(tr -d '\r\n' < "$XRAY_LOGLEVEL_FILE")"
fi

trap restore_state EXIT

printf 'info\n' >"$XRAY_LOGLEVEL_FILE"

run_global_probe global-tun /run/proxy-suite-tun/config.json proxy-suite-tun
run_per_app_probe per-app-tun "$PER_APP_TUN_PROFILE" /run/proxy-suite-per-app-tun/config.json proxy-suite-per-app-tun
run_global_probe global-tproxy /run/proxy-suite-socks/config.json proxy-suite-socks proxy-suite-tproxy
run_per_app_probe per-app-tproxy "$PER_APP_TPROXY_PROFILE" /run/proxy-suite-socks/config.json proxy-suite-socks proxy-suite-per-app-tproxy

printf '%s\n' "$OUTPUT_DIR"
