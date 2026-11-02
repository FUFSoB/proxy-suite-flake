set -euo pipefail
# $1 - probe-exits.json (index -> tag -> path), $2 - state.json
export PATH=@path@

jq -c '.[]' "$1" | while IFS= read -r exit; do
  tag=$(jq -r '.tag' <<<"$exit")
  path=$(jq -r '.path' <<<"$exit")
  # sing-box, running as @serviceUser@, watches this directory to reload the
  # files: that takes read on it, not just the search the state dir grants.
  # Asserted on every render, since StateDirectory= re-owns the tree when the
  # units' Group= changes.
  install -d -m 0750 @groupArg@"$(dirname "$path")"
  # Written aside and renamed into place: sing-box reloads on rename (as well
  # as on in-place writes), and it never reads a half-written file.
  # autoProxy.exclude ($ex), applied here so routes learned before it named them go too: a
  # route under an excluded name is left out, and an excluded name under a route (which
  # covers a whole site) is cut out of it.
  jq -c --arg t "$tag" --argjson ex @excludeJson@ '
    def under($l): . as $n | any($l[]; . as $e | $n == $e or ($n | endswith("." + $e)));
    ($ex | map(ascii_downcase)) as $ex
    | [(.domains // {}) | to_entries[] | select(.value.exit == $t and (.key | under($ex) | not)) | .key] as $d
    | [$ex[] | select(under($d))] as $cut
    | {version: 1, rules: (if ($d | length) == 0 then []
        elif ($cut | length) == 0 then [{domain_suffix: $d}]
        else [{type: "logical", mode: "and",
               rules: [{domain_suffix: $d}, {domain_suffix: $cut, invert: true}]}] end)}
  ' "$2" > "$path.tmp"
  chmod 644 "$path.tmp"
  mv -f "$path.tmp" "$path"
done
