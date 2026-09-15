# Adds one reading of XRay's counters ($q, taken with -reset) to the daily totals:
# {days: {"YYYY-MM-DD": {user|inbound|outbound: {"<name>": {up, down}}}}, seen, at}.
#
# A counter is named user|inbound|outbound>>>NAME>>>traffic>>>uplink|downlink, and a
# user's email is their name. Its value may come as a string, and a counter still at
# zero comes without one. Up is what went out towards the destination, down what came
# back. $online is `statsonlineiplist -all`: each online user's last seen time is kept
# in .seen, so an offline user still shows when they were last connected. The last 366
# days are kept.
reduce ($q.stat // [])[] as $s (.;
  ($s.name | split(">>>")) as $n
  | if ($n | length) == 4 and ($n[0] | IN("user", "inbound", "outbound")) and $n[2] == "traffic" then
      .days[$day][$n[0]][$n[1]][if $n[3] == "uplink" then "up" else "down" end] += (($s.value // 0) | tonumber)
    else . end)
| reduce ($online.users // [])[] as $u (.;
    .seen[$u.email] = ([.seen[$u.email] // 0, ($u.ips // [])[].lastSeen] | max))
| .at = $now
| .days = ((.days // {}) | with_entries(select(.key >= ($now - 366 * 86400 | strftime("%Y-%m-%d")))))
