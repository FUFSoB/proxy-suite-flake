# Adds one reading of XRay's per-user counters ($q, taken with -reset) to the
# daily totals: {days: {"YYYY-MM-DD": {"<email>": {up, down}}}, at}.
#
# A counter is named user>>>EMAIL>>>traffic>>>uplink|downlink, and a user's
# email is their name. Its value may come as a string, and a counter still at
# zero comes without one. Down is what the user received, up what they sent.
# The last 366 days are kept.
reduce ($q.stat // [])[] as $s (.;
  ($s.name | split(">>>")) as $n
  | if ($n | length) == 4 and $n[0] == "user" then
      .days[$day][$n[1]][if $n[3] == "uplink" then "up" else "down" end] += (($s.value // 0) | tonumber)
    else . end)
| .at = $now
| .days = ((.days // {}) | with_entries(select(.key >= ($now - 366 * 86400 | strftime("%Y-%m-%d")))))
