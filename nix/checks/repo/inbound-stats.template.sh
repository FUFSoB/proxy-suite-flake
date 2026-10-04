add=@statsAddJq@
now=1789135690 # 2026-09-11
a() { jq -c --argjson q "$1" --argjson online "${3:-{\}}" --argjson awg "${4:-[]}" --arg day 2026-09-11 --argjson now "$now" -f "$add" <<<"$2"; }

# XRay gives values as strings and leaves a zero counter without one.
r='{"stat":[{"name":"user>>>fufsob>>>traffic>>>downlink","value":"3000000"},
  {"name":"user>>>fufsob>>>traffic>>>uplink","value":"2000"},
  {"name":"user>>>phone>>>traffic>>>uplink"},
  {"name":"inbound>>>vless-in>>>traffic>>>downlink","value":5},
  {"name":"outbound>>>direct>>>traffic>>>uplink","value":6}]}'
s="$(a "$r" '{}')"
s="$(a "$r" "$s")"
jq -e '.days["2026-09-11"] | .user.fufsob == {down: 6000000, up: 4000}
  and .user.phone.up == 0 and .inbound["vless-in"].down == 10 and .outbound.direct.up == 12' <<<"$s" > /dev/null
jq -e '.at == 1789135690' <<<"$s" > /dev/null
# Nothing counted since the last reading: nothing changes.
jq -e --argjson s "$s" '.days == $s.days' <<<"$(a '{}' "$s")" > /dev/null
# An online user's last seen time is kept, and never goes back.
o='{"users":[{"email":"phone","ips":[{"ip":"203.0.113.7","lastSeen":1789135000},{"ip":"203.0.113.8","lastSeen":1789135600}]}]}'
s="$(a '{}' "$s" "$o")"
jq -e '.seen.phone == 1789135600' <<<"$s" > /dev/null
s="$(a '{}' "$s" '{"users":[{"email":"phone","ips":[{"ip":"203.0.113.7","lastSeen":1}]}]}')"
jq -e '.seen.phone == 1789135600' <<<"$s" > /dev/null
# Days more than a year old are let go.
old="$(jq -c '.days["2024-01-01"] = {user: {fufsob: {up: 1}}}' <<<"$s")"
jq -e '.days["2024-01-01"] == null' <<<"$(a '{}' "$old")" > /dev/null

# AmneziaWG peers come with raw interface counters, of which only the growth is added.
p() { echo '[{"interface":"awgi-home","key":"K","tag":"home","user":"tablet","rx":'"$1"',"tx":'"$2"',"handshake":'"$3"',"endpoint":"203.0.113.9:4000"}]'; }
s="$(a '{}' "$s" '{}' "$(p 1000 5000 1789135500)")"
jq -e '.days["2026-09-11"].user.tablet == {up: 1000, down: 5000} and .seen.tablet == 1789135500
  and .awgPeers.tablet == {tag: "home", handshake: 1789135500, endpoint: "203.0.113.9:4000"}' <<<"$s" > /dev/null
s="$(a '{}' "$s" '{}' "$(p 1500 5200 1789135600)")"
jq -e '.days["2026-09-11"].user.tablet == {up: 1500, down: 5200} and .seen.tablet == 1789135600' <<<"$s" > /dev/null
# A counter below the last one restarted with its interface.
s="$(a '{}' "$s" '{}' "$(p 100 100 0)")"
jq -e '.days["2026-09-11"].user.tablet == {up: 1600, down: 5300} and .seen.tablet == 1789135600
  and .awgPeers == {}' <<<"$s" > /dev/null
# A peer gone from the listeners leaves no counters behind.
jq -e '.awgCounters == {}' <<<"$(a '{}' "$s")" > /dev/null

touch "$out"
