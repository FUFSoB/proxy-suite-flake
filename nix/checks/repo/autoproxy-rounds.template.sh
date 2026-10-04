echo '[{"tag":"direct"},{"tag":"a"},{"tag":"b"},{"tag":"a2"},{"tag":"b2"},{"tag":"c"}]' > index.json
echo '{"exits":{"a":{"asn":"AS1","bad":true},"b":{"asn":"AS2"},"a2":{"asn":"AS1"},
  "b2":{"asn":"AS2"},"c":{"asn":"AS3","bad":false}}}' > state.json
r="$(jq -c --slurpfile s state.json -f @roundsJq@ index.json)"
printf '%s\n' "$r"
# A refused a takes neither AS1's first place (a2 does) nor any place before b2.
jq -e '. == {r1: "b,a2,c", r2: "b2,a", ordered: ["b", "a2", "b2", "c", "a"]}' <<<"$r" > /dev/null

k() {
  jq -c --argjson tags "$1" --arg d "$2" --arg why "$3" --argjson now "$4" --argjson ttl 100 \
    -f @strikeJq@ <<<"$5"
}
s='{"exits":{"a":{"asn":"AS1"},"b":{}}}'
# One destination is not enough, however often it strikes.
s="$(k '["a"]' sekai.test refused 1000 "$s")"
s="$(k '["a","b"]' sekai.test refused 1010 "$s")"
jq -e '.exits.a.bad == false and .exits.a.asn == "AS1" and .exits.b.bad == false' <<<"$s" > /dev/null
# A second one is.
s="$(k '["a"]' pximg.net slow 1020 "$s")"
jq -e '.exits.a | .bad and .badBy == ["sekai.test refused", "pximg.net slow"]' <<<"$s" > /dev/null
jq -e '.exits.b.bad == false' <<<"$s" > /dev/null
# A TTL later the older strike has expired.
s="$(k '[]' "" "" 1115 "$s")"
jq -e '.exits.a | (.bad | not) and .badBy == ["pximg.net slow"]' <<<"$s" > /dev/null
# A block page may be a passing challenge: one is not enough either.
s="$(k '["b"]' colorfulpalette.org wall:aws-waf 1120 "$s")"
jq -e '.exits.b | (.bad | not) and .badBy == ["colorfulpalette.org wall:aws-waf"]' <<<"$s" > /dev/null
s="$(k '["b"]' fandom.com wall:cloudflare 1130 "$s")"
jq -e '.exits.b | .bad and .badBy == ["colorfulpalette.org wall:aws-waf", "fandom.com wall:cloudflare"]' <<<"$s" > /dev/null
touch "$out"
