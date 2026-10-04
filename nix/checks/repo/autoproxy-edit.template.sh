edit() { jq -c --arg op "$1" --arg d "$2" -f @editJq@ <<<"$3"; }
s='{
  "domains": {"last.fm": {"exit": "a", "host": "www.last.fm"}, "pximg.net": {"exit": "b", "host": "i.pximg.net"}},
  "hosts": {"www.last.fm": {"domain": "last.fm"}, "cdn.last.fm": {"domain": "last.fm"}, "i.pximg.net": {"domain": "pximg.net"}},
  "backlog": {"api.last.fm": {"domain": "last.fm", "hits": 3}, "x.test": {"domain": "x.test", "hits": 1}},
  "slowWant": {"last.fm": 1}, "slowSkip": {"pximg.net": 1},
  "exits": {
    "a": {"asn": "AS1", "strikes": {"last.fm": {"why": "refused", "at": 1}, "sekai.test": {"why": "slow", "at": 2}}, "bad": true,
          "badBy": ["last.fm refused", "sekai.test slow"]},
    "b": {"asn": "AS2"}
  },
  "egress": "203.0.113.1", "lastRun": 5
}'

# Forget: every trace of the one domain, and a strike it made no longer counts.
f="$(edit forget last.fm "$s")"
jq -e '(.domains | keys) == ["pximg.net"]' <<<"$f" > /dev/null
jq -e '(.hosts | keys) == ["i.pximg.net"] and (.backlog | keys) == ["x.test"]' <<<"$f" > /dev/null
jq -e '.slowWant == {} and .slowSkip == {"pximg.net": 1}' <<<"$f" > /dev/null
jq -e '.exits.a | .asn == "AS1" and (.bad | not) and .badBy == ["sekai.test slow"]' <<<"$f" > /dev/null
jq -e '.exits.b == {"asn": "AS2"}' <<<"$f" > /dev/null
# A domain it never knew changes nothing.
jq -e --argjson s "$s" '. == $s' <<<"$(edit forget nope.test "$s")" > /dev/null

# Clear: every route and verdict; the exits, backlog and egress stay.
c="$(edit clear "" "$s")"
jq -e '.domains == {} and .hosts == {} and (has("slowWant") | not) and (has("slowSkip") | not)' <<<"$c" > /dev/null
jq -e '.exits.a | .asn == "AS1" and .strikes == {} and (.bad | not) and .badBy == []' <<<"$c" > /dev/null
jq -e '(.backlog | keys) == ["api.last.fm", "x.test"] and .egress == "203.0.113.1" and .lastRun == 5' <<<"$c" > /dev/null
touch "$out"
