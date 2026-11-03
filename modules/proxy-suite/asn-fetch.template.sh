set -uo pipefail
proxy=(--proxy socks5h://@proxyHost@:@proxyPort@)
# The listener's login as curl config on a pipe (-K): argv is readable by every local user.
proxy_login() {
  :
  @proxyLogin@
}
dir=@asnDir@
failed=0
changed=false

# What one system announces, from the ipverse asn-ip dataset: its prefixes as a sing-box
# source rule set (address lists only, checked as backends parse them, capped), and who it is.
convert='def v4: test("^[0-9]{1,3}([.][0-9]{1,3}){3}/[0-9]{1,2}\\z");
  def v6: test("^[0-9a-fA-F:]+/[0-9]{1,3}\\z");
  select((.asn | tostring) == $n)
  | ([(.prefixes.ipv4 // [])[] | strings | select(v4)]
     + [(.prefixes.ipv6 // [])[] | strings | select(v6)] | unique | .[:$max]) as $cidrs
  | {version: 2, rules: (if $cidrs == [] then [] else [{ip_cidr: $cidrs}] end)}'
about='{asn: (.asn | tonumber? // null),
  handle: ((.metadata.handle // "") | tostring | gsub("[^ -~]"; "") | .[:64]),
  description: ((.metadata.description // "") | tostring | gsub("[[:cntrl:]]"; "") | .[:128]),
  prefixes: $count,
  fetchedAt: now | floor}'

# A list replaces the old one only once sing-box has read it back, so a bad download never
# reaches a backend; one that fails keeps what was there, and sing-box reloads a changed file.
fetch() {
  local n=$1 raw set meta
  raw=$(@coreutils@/bin/mktemp "$dir/.asn-$n.XXXXXX") || { failed=1; return; }
  set=$(@coreutils@/bin/mktemp "$dir/.asn-$n.XXXXXX") || { rm -f "$raw"; failed=1; return; }
  meta=$(@coreutils@/bin/mktemp "$dir/.asn-$n.XXXXXX") || { rm -f "$raw" "$set"; failed=1; return; }
  # --proto-redir: a redirect to http would let the path pick the addresses.
  if @curl@ --fail --silent --show-error --location --proto-redir =https --max-time 60 --max-filesize 32M \
      "${proxy[@]}" -K <(proxy_login) --output "$raw" "@baseUrl@/$n/aggregated.json" &&
    @jq@ -c --arg n "$n" --argjson max @maxPrefixes@ "$convert" "$raw" > "$set" && [ -s "$set" ] &&
    @singBox@ rule-set compile --output /dev/null "$set" 2>/dev/null &&
    @jq@ -c --argjson count "$(@jq@ '[.rules[].ip_cidr[]] | length' "$set")" "$about" "$raw" > "$meta"; then
    chmod 0644 "$set" "$meta"
    if @diffutils@/bin/cmp -s "$set" "$dir/asn-$n.json"; then
      rm -f "$set"
    else
      mv -f "$set" "$dir/asn-$n.json"
      changed=true
    fi
    mv -f "$meta" "$dir/asn-$n.meta"
    echo "AS$n: $(@jq@ -r '.prefixes' "$dir/asn-$n.meta") prefixes"
  else
    rm -f "$set" "$meta"
    echo "AS$n: not updated; keeping the list it has" >&2
    failed=1
  fi
  rm -f "$raw"
}

# The configuration's systems and the runtime rules' (routing-render.jq checked those).
wanted=$({
  printf '%s\n' @declaredAsns@
  @jq@ -r '[.[] | select(.disabled | not) | (.asns // [])[]] | unique[]' @routingRules@ 2>/dev/null || true
} | @coreutils@/bin/sort -un)
for n in $wanted; do
  [[ $n =~ ^[0-9]+$ ]] && fetch "$n"
done
# For the XRay backend, which reads them at start: restart it (applyScript, as root).
if [ "$changed" = true ]; then
  : > "$dir/.changed"
fi
exit "$failed"
