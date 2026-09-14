# Strikes against exits, which autoproxy-rounds.jq probes last once bad: domain $d
# refused $tags at $now, or crawled on them. $why is "wall:<page>" (a block page:
# the site's security layer refused the address while another egress got past),
# "refused" (the origin refused it while another egress got content) or "slow".
# A domain counts once per exit, for $ttl seconds. One wall makes an exit bad -
# it is the site's own verdict on the address; the guesses need two domains.
# Empty $tags only expires.
reduce $tags[] as $t (.; .exits[$t].strikes[$d] = {why: $why, at: $now})
| .exits |= map_values(
    ((.strikes // {}) | with_entries(select(.value.at + $ttl > $now))) as $s
    | . + {strikes: $s,
           bad: (($s | length) >= 2 or any($s[]; .why | startswith("wall:"))),
           badBy: ($s | to_entries | sort_by(.value.at) | map("\(.key) \(.value.why)"))})
