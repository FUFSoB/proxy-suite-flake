# Slurped Clash API /connections snapshots, a second apart, in; per host and exit that
# moved at least $min bytes: host<TAB>exit<TAB>slow|fast<TAB>peak. Slow never beat
# $below in any second (paced streams burst, so they read fast). Probe listeners are
# skipped; chains[0] is the carrying exit.
[.[] | [(.connections // [])[]
  | select((.metadata.type // "") | test("/probe-in-") | not)
  | {id, host: (.metadata.host // ""), exit: (.chains[0] // ""), d: .download}]]
| . as $s
| [range(1; length) as $i
   | ($s[$i - 1] | map({key: .id, value: .d}) | from_entries) as $p
   | $s[$i][] | select($p[.id] != null)
   | {id, host, exit, delta: (.d - $p[.id])}]
| group_by(.id)
| map({host: .[0].host, exit: .[0].exit, total: (map(.delta) | add), peak: (map(.delta) | max)})
| map(select(.host != "" and .exit != "" and .total >= $min))
# One line per host and exit; its best connection decides.
| group_by(.host + "\t" + .exit)
| map(max_by(.peak))[]
| "\(.host)\t\(.exit)\t\(if .peak < $below then "slow" else "fast" end)\t\(.peak)"
