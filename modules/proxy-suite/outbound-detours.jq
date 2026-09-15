# Chains outbounds through their detour hop: {outbounds, xray} -> {outbounds, xray, errors}.
#
# $d is {outbounds: {tag: hop}, subscriptions: {sub tag: hop}}; $sources maps every
# outbound tag to where it came from ("sub:<tag>" for a subscription entry). $kind is
# the backend: sing-box sets detour, XRay sockopt.dialerProxy. In hybrid, .xray holds the
# sidecar's outbounds, each also standing in .outbounds as a loopback SOCKS hop: a
# sing-box outbound may chain through either, a sidecar one only through another
# sidecar one, since the sidecar cannot dial through sing-box.
def dialer($h): .streamSettings.sockopt.dialerProxy = $h;

([.outbounds[].tag]) as $tags
| ([(.xray // [])[].tag]) as $xtags
| ($sources | to_entries | map(
    .key as $t
    | ($d.outbounds[$t]
       // (if .value | startswith("sub:") then $d.subscriptions[.value[4:]] else null end))
    | select(. != null)
    | {key: $t, value: .}
  ) | from_entries) as $hops
| .errors = (
    [$hops | to_entries[] | select(.value as $v | $tags | index([$v]) | not)
     | "outbound '\(.key)' chains through '\(.value)', which is not an outbound"]
    + [$hops | keys[] as $t
       | select([limit($hops | length + 1; $t | recurse($hops[.] // empty))][1:] | any(. == $t))
       | "outbound '\($t)' chains back to itself"]
    + (if $kind == "hybrid" then
        [$hops | to_entries[]
         | select((.key as $t | $xtags | index([$t])) and (.value as $v | $xtags | index([$v]) | not))
         | "outbound '\(.key)' runs on XRay and can only chain through another XRay outbound, not '\(.value)'"]
       else [] end)
  )
| if .errors != [] then .
  elif $kind == "xray" then
    .outbounds |= map(if $hops[.tag] then dialer($hops[.tag]) else . end)
  elif $kind == "hybrid" then
    .xray |= map(if $hops[.tag] then dialer($hops[.tag]) else . end)
    | .outbounds |= map(.tag as $t | if $hops[$t] and ($xtags | index([$t]) | not) then .detour = $hops[$t] else . end)
  else
    .outbounds |= map(if $hops[.tag] then .detour = $hops[.tag] else . end)
  end
