. @config@
set -f
printf '%s\n' $NFQWS2_OPT | awk '
  function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
  # Numeric from the start: an unset s indexes the first section as "", not 0.
  BEGIN { s = 0 }
  $0 == "--new" { s++; next }
  /^--template=/ { tpl[substr($0, 12)] = s; istpl[s] = 1; next }
  /^--import=/ { imp[s] = substr($0, 10); next }
  /^--lua-desync=/ {
    fn[s]++
    spec = substr($0, 14)
    if (spec ~ /^circular(:|$)/) {
      circ[s] = fn[s]
      if (match(spec, /:key=[^:]+/)) key[s] = substr(spec, RSTART + 5, RLENGTH - 5)
    } else if (match(spec, /:strategy=[0-9]+/)) {
      n = substr(spec, RSTART + 10, RLENGTH - 10)
      spec = substr(spec, 1, RSTART - 1) substr(spec, RSTART + RLENGTH)
      if (!((s, n) in strat)) order[s] = order[s] " " n
      strat[s, n] = ((s, n) in strat ? strat[s, n] "," : "") js(spec)
    }
  }
  END {
    printf "{"
    for (i = 0; i <= s; i++) {
      if (istpl[i]) continue
      p++
      if (!(i in circ)) continue
      k = (i in key) ? key[i] : "circular_" p "_" circ[i]
      src = (i in imp && imp[i] in tpl) ? tpl[imp[i]] : ""
      printf "%s%s:{", (out++ ? "," : ""), js(k)
      m = 0
      for (pass = 0; pass < 2; pass++) {
        j = pass ? src : i
        if (j == "") continue
        c = split(order[j], ns, " ")
        for (x = 1; x <= c; x++) printf "%s%s:[%s]", (m++ ? "," : ""), js(ns[x]), strat[j, ns[x]]
      }
      printf "}"
    }
    print "}"
  }' >"$out"
