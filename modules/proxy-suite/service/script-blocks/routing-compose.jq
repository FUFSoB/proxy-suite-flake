# The route for a mode, from the configuration's rule buckets (routeModeRulesFile) and the
# runtime rules' sections (routing-convert.jq): every section at its priority, a runtime one
# ahead of the configuration's at the same number, the common rules first. $mode drops what it
# leaves to the final outbound: all-proxy every direct list, all-bypass all but the blocks.
# Out: the route rules, the DNS mirror in the same order, and how long the configuration's
# own mirror is (the stretch of dns.rules this replaces).
def keep: if $mode == "all-proxy" then .cat != "direct"
  elif $mode == "all-bypass" then .cat == "block" or .cat == "safety"
  else true end;

.common as $common
| ([.custom[] | {prio: 100, cat: .category, rules: .entries, dns: (.dns // [])}]
   + [{prio: 200, cat: "proxy", rules: .proxyPrimary, dns: (.dns.proxyPrimary // [])},
      {prio: 300, cat: "block", rules: .block, dns: []},
      {prio: 400, cat: "direct", rules: .direct, dns: (.dns.direct // [])},
      {prio: 400, cat: "safety", rules: .safetyDirect, dns: []},
      {prio: 500, cat: "proxy", rules: .proxyGeo, dns: (.dns.proxyGeo // [])}]) as $static
# sort_by is stable: runtime sections, already in their order, first among equals.
| ($runtime[0] + $static | sort_by(.prio) | map(select(keep))) as $sections
| {
    rules: ($common + ([$sections[].rules[]])),
    dns: [$sections[].dns[]],
    staticDnsCount: ([$static[].dns | length] | add // 0)
  }
