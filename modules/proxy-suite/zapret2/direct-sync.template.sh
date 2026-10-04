# $1: zapret2's state directory, $2: the rule-set to write. The hosts zapret2 pins and
# learns, less the excluded ones, as a sing-box source rule-set the proxy sends direct.
# Rewritten only when it changes: sing-box reloads it on every rename.
set -euo pipefail
export PATH=@path@
dir=$1
out=$2

lists() {
  local f
  for f in "$@"; do
    [ -r "$f" ] && cat "$f"
  done
  true
}

lists "$dir/zapret-hosts-user.txt" "$dir/zapret-hosts-auto.txt" \
  | jq -R -n -c --rawfile excluded <(lists "$dir/zapret-hosts-user-exclude.txt") '
      # nfqws hostlists: one host per line, "#" comments, "^" for the name alone.
      def hosts: map(gsub("^\\s+|\\s+$"; "") | ascii_downcase | ltrimstr("^"))
        | map(select(. != "" and (startswith("#") | not)));
      ($excluded | split("\n") | hosts) as $excluded
      | ([inputs] | hosts | unique) - $excluded
      | map(select(test("^[0-9.]+$|:"))) as $ips
      | {version: 1, rules: (
          [(. - $ips) | select(length > 0) | {domain_suffix: .}]
          + [$ips | select(length > 0)
              | {ip_cidr: map(. + (if test(":") then "/128" else "/32" end))}])}
    ' >"$out.tmp"

if cmp -s "$out.tmp" "$out"; then
  rm "$out.tmp"
else
  chmod 644 "$out.tmp"
  mv "$out.tmp" "$out"
fi
