# Adds one reading of XRay's counters ($q, taken with -reset) to the daily totals:
# {days: {"YYYY-MM-DD": {user|inbound|outbound: {"<name>": {up, down}}}}, seen, at}.
#
# A counter is named user|inbound|outbound>>>NAME>>>traffic>>>uplink|downlink, and a
# user's email is their name. Its value may come as a string, and a counter still at
# zero comes without one. Up is what went out towards the destination, down what came
# back. $online is `statsonlineiplist -all`: each online user's last seen time is kept
# in .seen, so an offline user still shows when they were last connected. The last 366
# days are kept.
#
# $awg lists the AmneziaWG listeners' peers ({interface, key, tag, user, rx, tx, handshake,
# endpoint}) with raw interface counters: what grew since the last reading, kept in
# .awgCounters, is added to the user (a counter below the last one restarted with its
# interface). The newest handshake counts as seen, and .awgPeers keeps each user's latest.
reduce ($q.stat // [])[] as $s (.;
  ($s.name | split(">>>")) as $n
  | if ($n | length) == 4 and ($n[0] | IN("user", "inbound", "outbound")) and $n[2] == "traffic" then
      .days[$day][$n[0]][$n[1]][if $n[3] == "uplink" then "up" else "down" end] += (($s.value // 0) | tonumber)
    else . end)
| reduce ($online.users // [])[] as $u (.;
    .seen[$u.email] = ([.seen[$u.email] // 0, ($u.ips // [])[].lastSeen] | max))
| (.awgCounters // {}) as $last
| .awgCounters = {}
| .awgPeers = {}
| reduce ($awg // [])[] as $p (.;
    ($last[$p.interface][$p.key] // {rx: 0, tx: 0}) as $l
    | .days[$day].user[$p.user].up += (if $p.rx >= $l.rx then $p.rx - $l.rx else $p.rx end)
    | .days[$day].user[$p.user].down += (if $p.tx >= $l.tx then $p.tx - $l.tx else $p.tx end)
    | .awgCounters[$p.interface][$p.key] = {rx: $p.rx, tx: $p.tx}
    | if $p.handshake > 0 then
        .seen[$p.user] = ([.seen[$p.user] // 0, $p.handshake] | max)
        | if $p.handshake >= (.awgPeers[$p.user].handshake // 0) then
            .awgPeers[$p.user] = {tag: $p.tag, handshake: $p.handshake, endpoint: $p.endpoint}
          else . end
      else . end)
| .at = $now
| .days = ((.days // {}) | with_entries(select(.key >= ($now - 366 * 86400 | strftime("%Y-%m-%d")))))
