f=@detoursJq@
d() { jq -c -f "$f" --argjson d "$1" --argjson sources "$2" --arg kind "$3" <<<"$4"; }

# sing-box: a declared outbound and every entry of a subscription.
r="$(d '{"outbounds":{"de":"ru"},"subscriptions":{"s":"warp"}}' '{"ru":"static","de":"static","s-a":"sub:s","warp":"warp"}' sing-box \
  '{"outbounds":[{"tag":"ru"},{"tag":"de"},{"tag":"s-a"},{"tag":"warp"}],"xray":[]}')"
jq -e '.errors == [] and ([.outbounds[] | .detour] == [null, "ru", "warp", null])' <<<"$r" > /dev/null
# XRay: dialerProxy, next to what sockopt already had.
r="$(d '{"outbounds":{"de":"ru"},"subscriptions":{}}' '{"ru":"static","de":"static"}' xray \
  '{"outbounds":[{"tag":"ru"},{"tag":"de","streamSettings":{"sockopt":{"mark":1}}}],"xray":[]}')"
jq -e '.outbounds[1].streamSettings.sockopt == {mark: 1, dialerProxy: "ru"}' <<<"$r" > /dev/null
# Hybrid: sidecar outbounds chain in the sidecar, sing-box ones through anything.
r="$(d '{"outbounds":{"x1":"x2","sb":"x1"},"subscriptions":{}}' '{"x1":"static","x2":"static","sb":"static"}' hybrid \
  '{"outbounds":[{"tag":"x1"},{"tag":"x2"},{"tag":"sb"}],"xray":[{"tag":"x1"},{"tag":"x2"}]}')"
jq -e '.errors == [] and .xray[0].streamSettings.sockopt.dialerProxy == "x2"
  and .outbounds[0].detour == null and .outbounds[2].detour == "x1"' <<<"$r" > /dev/null
r="$(d '{"outbounds":{"x1":"sb"},"subscriptions":{}}' '{"x1":"static","sb":"static"}' hybrid \
  '{"outbounds":[{"tag":"x1"},{"tag":"sb"}],"xray":[{"tag":"x1"}]}')"
jq -e '[.errors[].message] == ["outbound '"'x1'"' runs on XRay and can only chain through another XRay outbound, not '"'sb'"'"]' <<<"$r" > /dev/null
# A missing hop and a loop are errors, and nothing is rewritten.
r="$(d '{"outbounds":{"a":"b","b":"a","c":"gone"},"subscriptions":{}}' '{"a":"static","b":"static","c":"static"}' sing-box \
  '{"outbounds":[{"tag":"a"},{"tag":"b"},{"tag":"c"}],"xray":[]}')"
jq -e '(.errors | length) == 3 and all(.outbounds[]; .detour == null)' <<<"$r" > /dev/null

touch "$out"
