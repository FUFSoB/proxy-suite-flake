# Folds sampler observations ($o: [{d, h, exit, slow, peak}]) into the state. $hits
# crawls on direct within a day make a domain owed an exit (.slowWant); once routed it
# is judged on that exit only: a fast transfer keeps it, two slow ones move it to the
# next. Never moved: censor verdicts (zapret's) and .slowSkip domains.
.slowHits = ((.slowHits // {}) | with_entries(select(.value.first + 86400 > $now)))
| .slowWant = (.slowWant // {})
| reduce $o[] as $x (.;
    .domains[$x.d] as $r
    | if $r.verdict == "slow" then
        if $x.exit != $r.exit then .
        elif $x.slow then .domains[$x.d].bad = (($r.bad // 0) + 1)
        else .domains[$x.d] += {bad: 0, at: $now} end
      elif $r.exit != null or $x.exit != "direct" or ($x.slow | not)
        or .slowWant[$x.d] != null
        or ((.slowSkip[$x.d] // 0) > $now)
        or (.hosts[$x.h].verdict == "censor") then .
      else
        .slowHits[$x.h] = {n: ((.slowHits[$x.h].n // 0) + 1), first: (.slowHits[$x.h].first // $now)}
        | if .slowHits[$x.h].n >= $hits then
            .slowWant[$x.d] = {host: $x.h, tried: []} | del(.slowHits[$x.h])
          else . end
      end)
| ([.domains | to_entries[] | select(.value.verdict == "slow" and (.value.bad // 0) >= 2)]) as $moved
| reduce $moved[] as $e (.;
    del(.domains[$e.key])
    | .slowWant[$e.key] = {host: $e.value.host, tried: ($e.value.tried // [$e.value.exit])})
| .slowSkip = ((.slowSkip // {}) | with_entries(select(.value > $now)))
