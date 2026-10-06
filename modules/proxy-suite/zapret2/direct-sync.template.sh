# $1: zapret2's state directory, $2: the directory to write the two rule-sets to; $3, the
# checks': a dump to read in place of systemd-resolved's cache.
# direct.json: the hosts zapret2 handles, so the proxy sends them direct and zapret2 sees
#   them: the pinned ones, and the learned ones once a strategy got through for them
#   (detect.lua's "works"), unless learned from transfers cut short ("stalls"); a learned
#   site zapret2 cannot fix keeps the proxy's route.
# proxy.json: what zapret2 cannot fix, for the proxy to carry: sites every strategy failed
#   for ("unfixable": all of a site's TCP, or only its QUIC), and addresses that leave
#   connections unanswered ("blocked").
# names.tsv: "address<TAB>names" of each address blocked outright, for proxy-ctl: no
#   connection to it got far enough to name its site, but the lookups before them did. The
#   names systemd-resolved's cache has it under, a CNAME followed back to the name asked
#   for; read once, as its verdict lands, while the cache still holds them ("" for none).
# The last verdict per name and protocol wins ("retry", "reachable" and "works" clear one).
# Rewritten only when they change: sing-box reloads them on every rename.
set -euo pipefail
export PATH=@path@
dir=$1
out=$2
cache=${3:-}

# The zapret scope's group writes these: never through a symlink it left (to a file only
# root may read, which would land in the world-readable rule-sets), nor into a FIFO.
lists() {
  local f
  for f in "$@"; do
    [ -r "$f" ] && dd if="$f" iflag=nofollow,nonblock status=none 2>/dev/null
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
# The zapret scope can write them, and an entry sing-box cannot take (999.1.1.1, ::/0,
# fe80::1%eth0) would fail the rule-set and the proxy with it: only an address or a name.
hosts='def octet: "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  def ipv4: test("^(" + octet + "\\.){3}" + octet + "$");
  def ipv6: test("^[0-9a-f:]+$") and test(":::") == false
    and (split("::") | length) <= 2
    and (split(":") | map(select(. != "")) | length <= 8 and all(length <= 4))
    and (test("::") or (split(":") | length) == 8)
    and test("^:[^:]|[^:]:$") == false;
  # Two labels at least: a bare "com" would send the whole TLD past the proxy.
  def hostname: test("^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)+$")
    and test("^[0-9.]+$") == false and length <= 253;
  def valid: ipv4 or ipv6 or hostname;
  def hosts: split("\n") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase | ltrimstr("^"))
    | map(select(. != "" and (startswith("#") | not) and valid));
  def ip: test("^[0-9.]+$|:");
  def cidr: map(. + (if test(":") then "/128" else "/32" end));
  # A name and a site key cover each other either way round: www.notion.so and notion.so.
  def covers($b): . as $a | $a == $b or ($a | endswith("." + $b)) or ($b | endswith("." + $a));
  # "kind<TAB>name<TAB>proto<TAB>...", the last per name and proto.
  # The zapret scope'"'"'s group can write the file: only names a rule can take.
  def verdicts: split("\n") | map(split("\t") | select(length >= 3 and (.[1] | test("^[a-z0-9.-]+$|^[0-9a-f:.]+$") and valid)))
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

names='def blocked: verdicts | named("blocked"; "ip") | unique;
  def known: split("\n") | map(split("\t") | select(length == 2) | {key: .[0], value: .[1]}) | from_entries;
  # resolvectl show-cache: "name IN A address", "alias IN CNAME name".
  def records: split("\n")
    | map(capture("^\\s*(?<name>\\S+)\\s+IN\\s+(?<type>A|AAAA|CNAME)\\s+(?<data>\\S+)\\s*$")
      | .name |= (ascii_downcase | rtrimstr(".")) | .data |= (ascii_downcase | rtrimstr(".")));
  def aliased($aliases): . as $s | ($s + [$aliases[] | select(.data | IN($s[])) | .name] | unique)
    | if . == $s then . else aliased($aliases) end;
  # The names asked for: those no other name of the chain is an alias for.
  def asked($aliases): . as $all | map(select(. as $n | any($aliases[]; .data == $n and (.name | IN($all[]))) | not));'

# The resolver is asked only for an address it has not been asked about yet.
missing=$(jq -n -r --rawfile verdicts <(lists "$dir/verdicts.tsv") --rawfile known <(lists "$out/names.tsv") \
  "$hosts$names"'($verdicts | blocked) - ($known | known | keys) | .[]')
dump() {
  if [ -z "$missing" ]; then
    true
  elif [ -n "$cache" ]; then
    lists "$cache"
  else
    timeout 2 resolvectl show-cache 2>/dev/null || true
  fi
}

jq -n -r --rawfile verdicts <(lists "$dir/verdicts.tsv") --rawfile known <(lists "$out/names.tsv") \
  --rawfile cache <(dump) "$hosts$names"'
  ($known | known) as $known
  | ($cache | records) as $records
  | ($records | map(select(.type == "CNAME"))) as $aliases
  | $verdicts | blocked | .[] as $ip
  | "\($ip)\t\($known[$ip] // ([$records[] | select(.type != "CNAME" and .data == $ip) | .name] | unique
      | aliased($aliases) | asked($aliases) | map(select(hostname)) | .[:4] | join(",")))"
' >"$out/names.tsv.tmp"
write "$out/names.tsv"
