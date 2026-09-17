# One `proxy-ctl proxy auto forget|clear` request, applied under the prober's lock.
# $op "forget": domain $d goes back to direct, and every verdict and strike about it
# goes too, so the next time it is dialled it is probed from scratch.
# $op "clear": the same for every domain. What each exit is (ip, asn), the backlog
# and the egress address stay: they are about the exits and the clients, not a verdict.
def rebad:
  (.strikes // {}) as $s
  | . + {bad: (($s | length) >= 2),
         badBy: ($s | to_entries | sort_by(.value.at) | map("\(.key) \(.value.why)"))};

if $op == "clear" then
  .domains = {}
  | .hosts = {}
  | del(.slowWant, .slowSkip)
  | .exits = ((.exits // {}) | map_values(.strikes = {} | rebad))
elif $op == "forget" then
  .domains = ((.domains // {}) | del(.[$d]))
  | .hosts = ((.hosts // {}) | with_entries(select(.value.domain != $d)))
  | .backlog = ((.backlog // {}) | with_entries(select(.value.domain != $d)))
  | if .slowWant then .slowWant |= del(.[$d]) else . end
  | if .slowSkip then .slowSkip |= del(.[$d]) else . end
  | .exits = ((.exits // {}) | map_values(if .strikes then (.strikes |= del(.[$d]) | rebad) else . end))
else . end
