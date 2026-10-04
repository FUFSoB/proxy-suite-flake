# $1: zapret2's state directory, $2: the directory to write the two rule-sets to.
# direct.json: the hosts zapret2 handles, so the proxy sends them direct and zapret2 sees
#   them: the pinned ones, and the learned ones once a strategy got through for them
#   (detect.lua's "works"), unless learned from transfers cut short ("stalls"); a learned
#   site zapret2 cannot fix keeps the proxy's route.
# proxy.json: what zapret2 cannot fix, for the proxy to carry: sites every strategy failed
#   for ("unfixable": all of a site's TCP, or only its QUIC), and addresses that leave
#   connections unanswered ("blocked").
# The last verdict per name and protocol wins ("retry", "reachable" and "works" clear one).
# Rewritten only when they change: sing-box reloads them on every rename.
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

write() {
  if cmp -s "$1.tmp" "$1"; then
    rm "$1.tmp"
  else
    chmod 644 "$1.tmp"
    mv "$1.tmp" "$1"
  fi
}

# nfqws hostlists: one host per line, "#" comments, "^" for the name alone.
hosts='def hosts: split("\n") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase | ltrimstr("^"))
  | map(select(. != "" and (startswith("#") | not)));
  def ip: test("^[0-9.]+$|:");
  def cidr: map(. + (if test(":") then "/128" else "/32" end));
  # A name and a site key cover each other either way round: www.notion.so and notion.so.
  def covers($b): . as $a | $a == $b or ($a | endswith("." + $b)) or ($b | endswith("." + $a));
  # "kind<TAB>name<TAB>proto<TAB>...", the last per name and proto.
  # The zapret scope'"'"'s group can write the file: only names a rule can take.
  def verdicts: split("\n") | map(split("\t") | select(length >= 3 and (.[1] | test("^[a-z0-9.-]+$|^[0-9a-f:.]+$"))))
    | reduce .[] as $v ({}; .[$v[1] + "\t" + $v[2]] = $v[0])
    | to_entries | map({name: (.key | split("\t")[0]), proto: (.key | split("\t")[1]), kind: .value});
  def named($kind; $proto): map(select(.kind == $kind and .proto == $proto) | .name);'

jq -n -c \
  --rawfile user <(lists "$dir/zapret-hosts-user.txt") \
  --rawfile auto <(lists "$dir/zapret-hosts-auto.txt") \
  --rawfile excluded <(lists "$dir/zapret-hosts-user-exclude.txt") \
  --rawfile verdicts <(lists "$dir/verdicts.tsv") \
  "$hosts"'
  ($verdicts | verdicts) as $v
  | ($v | named("works"; "tcp")) as $works
  # Learned from a transfer cut short: success is judged on the first 4 KB, which the
  # cutoff lets through, so "works" proves nothing for it.
  | ($v | named("stalls"; "cutoff")) as $stalls
  | ($excluded | hosts) as $excluded
  | (($user | hosts) + ($auto | hosts | map(. as $h
      | select(any($works[]; . as $w | $h | covers($w)) and (any($stalls[]; . as $s | $h | covers($s)) | not)))))
  | unique - $excluded
  | map(select(ip)) as $ips
  | {version: 1, rules: (
      [(. - $ips) | select(length > 0) | {domain_suffix: .}]
      + [$ips | select(length > 0) | {ip_cidr: cidr}])}
' >"$out/direct.json.tmp"
write "$out/direct.json"

jq -n -c --rawfile verdicts <(lists "$dir/verdicts.tsv") "$hosts"'
  ($verdicts | verdicts) as $v
  # A site keyed by its address (no name seen) goes by address.
  | ($v | named("unfixable"; "tcp")) as $tcp
  | ($v | named("unfixable"; "udp")) as $udp
  | {version: 1, rules: (
      [$tcp | map(select(ip | not)) | select(length > 0) | {domain_suffix: .}]
      + [$udp | map(select(ip | not)) | select(length > 0) | {network: ["udp"], port: [443], domain_suffix: .}]
      + [$udp | map(select(ip)) | select(length > 0) | {network: ["udp"], port: [443], ip_cidr: cidr}]
      + [($v | named("blocked"; "ip")) + ($tcp | map(select(ip))) | select(length > 0) | {ip_cidr: cidr}])}
' >"$out/proxy.json.tmp"
write "$out/proxy.json"
