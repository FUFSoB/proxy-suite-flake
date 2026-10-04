set -euo pipefail
export PATH=@path@
state_dir=${AUTOPROXY_STATE_DIR:-@stateDir@}
index=${PROBE_EXITS_FILE:-@runtimeDir@/proxy-suite-socks/probe-exits.json}
@clashApiBlock@
if [ -z "$clash_api" ]; then
  echo "sing-box has no Clash API (selection = \"first\"?); nothing to sample"
  exit 0
fi
install -d -m @stateDirMode@ "$state_dir"

# Eleven snapshots a second apart: ten one-second deltas per connection.
lines=$(
  for i in $(seq 0 10); do
    [ "$i" -eq 0 ] || sleep 1
    curl -sS --noproxy '*' --max-time 1 -H @<(clash_auth_header) "http://$clash_api/connections" 2>/dev/null ||
      echo '{}'
  done | jq -s -r --argjson min @minBytes@ \
    --argjson below @slowBelowBytes@ -f @slowSampleJq@ || true
)
[ -z "$lines" ] || printf '%s\n' "$lines" >> "$state_dir/samples"
