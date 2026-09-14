# Renders every per-exit autoProxy rule-set file from the learned state.
#
# Shared by the socks start script and the prober. The start script needs it
# because sing-box refuses to start when a local rule-set path is missing, so
# every file it will be told about must exist first; the prober needs it to
# publish what it learns, which sing-box then picks up without a restart.
{ pkgs }:

pkgs.writeShellScript "proxy-suite-autoproxy" ''
  set -euo pipefail
  # $1 - probe-exits.json (index -> tag -> path), $2 - state.json
  export PATH=${pkgs.lib.makeBinPath [
    pkgs.coreutils
    pkgs.jq
  ]}

  jq -c '.[]' "$1" | while IFS= read -r exit; do
    tag=$(jq -r '.tag' <<<"$exit")
    path=$(jq -r '.path' <<<"$exit")
    # Written aside and renamed into place: sing-box reloads on rename (as well
    # as on in-place writes), and it never reads a half-written file.
    jq -c --arg t "$tag" '
      [(.domains // {}) | to_entries[] | select(.value.exit == $t) | .key] as $d
      | {version: 1, rules: (if ($d | length) > 0 then [{domain_suffix: $d}] else [] end)}
    ' "$2" > "$path.tmp"
    mv -f "$path.tmp" "$path"
  done
''
