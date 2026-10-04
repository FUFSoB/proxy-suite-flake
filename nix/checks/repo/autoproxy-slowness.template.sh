sample=@slowSampleJq@
judge=@slowJudgeJq@

# A steady crawl, a burst, probe and outbound-test traffic, and a tiny flow.
res="$(jq -n -c '[range(0; 11) as $t | {connections: [
    {id: "a", metadata: {host: "i.pximg.net", type: "mixed/mixed-in"}, chains: ["direct"], download: ($t * 50000)},
    {id: "b", metadata: {host: "audio.example", type: "mixed/mixed-in"}, chains: ["direct"], download: (if $t >= 5 then 2000000 else 0 end)},
    {id: "c", metadata: {host: "probe.example", type: "mixed/probe-in-0"}, chains: ["direct"], download: ($t * 50000)},
    {id: "d", metadata: {host: "tiny.example", type: "mixed/mixed-in"}, chains: ["direct"], download: ($t * 1000)},
    {id: "e", metadata: {host: "far.example", type: "mixed/mixed-in"}, chains: ["primary", "proxy"], download: ($t * 50000)},
    {id: "f", metadata: {host: "speed.example", type: "mixed/proxy-suite-test-in"}, chains: ["primary", "proxy-suite-test"], download: ($t * 50000)}
  ]}][]' | jq -s -r --argjson min 307200 --argjson below 153600 -f "$sample")"
printf '%s\n' "$res"
test "$(wc -l <<<"$res")" = 3
grep -qx "$(printf 'i.pximg.net\tdirect\tslow\t50000')" <<<"$res"
grep -qx "$(printf 'audio.example\tdirect\tfast\t2000000')" <<<"$res"
# chains[0] is the exit that carried it, not the selector.
grep -qx "$(printf 'far.example\tprimary\tslow\t50000')" <<<"$res"

j() {
  jq -c --argjson o "$1" --argjson now 1000 --argjson ttl 100 --argjson hits 3 -f "$judge" <<<"$2"
}
slow='[{"d":"pximg.net","h":"i.pximg.net","exit":"direct","slow":true,"peak":50000}]'
onExitSlow='[{"d":"pximg.net","h":"i.pximg.net","exit":"primary","slow":true,"peak":1}]'
onExitFast='[{"d":"pximg.net","h":"i.pximg.net","exit":"primary","slow":false,"peak":900000}]'
s='{"domains":{},"hosts":{"x.twimg.com":{"verdict":"censor"}},"exits":{},"backlog":{}}'

# Three crawls within a day make the domain owed an exit; two do not.
s="$(j "$slow" "$s")"; s="$(j "$slow" "$s")"
jq -e '.slowWant == {}' <<<"$s" > /dev/null
s="$(j "$slow" "$s")"
jq -e '.slowWant["pximg.net"] == {host: "i.pximg.net", tried: []}' <<<"$s" > /dev/null

# Left to zapret: never moved, however slow.
z='[{"d":"twimg.com","h":"x.twimg.com","exit":"direct","slow":true,"peak":1}]'
t="$(j "$z" "$s")"; t="$(j "$z" "$t")"; t="$(j "$z" "$t")"
jq -e '.slowWant["twimg.com"] == null' <<<"$t" > /dev/null

# Once routed -- the prober picks the exit -- judged on that exit alone.
r='{"domains":{"pximg.net":{"verdict":"slow","exit":"primary","host":"i.pximg.net","at":0,"tried":["primary"]}},
  "hosts":{},"exits":{},"backlog":{}}'
# Fast there: kept, and a strike against it forgotten.
k="$(j "$onExitSlow" "$r")"; k="$(j "$onExitFast" "$k")"
jq -e '.domains["pximg.net"] | .bad == 0 and .at == 1000' <<<"$k" > /dev/null
# Crawling there too, twice: owed the next exit, the ones tried remembered.
u="$(j "$onExitSlow" "$r")"; u="$(j "$onExitSlow" "$u")"
jq -e '.domains["pximg.net"] == null and .slowWant["pximg.net"].tried == ["primary"]' <<<"$u" > /dev/null

# Every exit failed it: left direct until slowSkip expires, however slow.
w='{"domains":{},"hosts":{},"exits":{},"backlog":{},"slowSkip":{"pximg.net":1100}}'
w="$(j "$slow" "$w")"; w="$(j "$slow" "$w")"; w="$(j "$slow" "$w")"
jq -e '.slowWant == {} and .slowSkip["pximg.net"] == 1100' <<<"$w" > /dev/null

touch "$out"
