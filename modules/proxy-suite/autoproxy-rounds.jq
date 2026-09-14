# Probe order of the exits after direct, from probe-exits.json with the state
# slurped as $s. Round 1: one exit per network (AS). Round 2, only walked when
# round 1 all refused: the rest. Bad exits (autoproxy-strike.jq) never take
# a network's round-1 place and go last.
[.[1:][] | {tag, asn: ($s[0].exits[.tag].asn // ""), bad: ($s[0].exits[.tag].bad == true)}]
| (map(select(.bad | not)) + map(select(.bad))) as $ordered
| reduce $ordered[] as $e ({seen: {}, r1: [], r2: []};
    if $e.bad then .r2 += [$e.tag]
    elif $e.asn == "" or (.seen[$e.asn] | not)
    then .r1 += [$e.tag] | .seen[$e.asn] = true
    else .r2 += [$e.tag] end)
| {r1: (.r1 | join(",")), r2: (.r2 | join(",")), ordered: ($ordered | map(.tag))}
