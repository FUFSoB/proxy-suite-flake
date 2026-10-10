# routing.d/rules.json, as userControl's group wrote it (slurped: one document, else none), to
# the rules root applies: each field checked, anything else dropped, a name once. Sorted in
# match order (priority, then name).
def strs: if type == "array" then [.[] | strings] else [] end;
def domain: ascii_downcase | ltrimstr(".") | select(test("^[a-z0-9_-]+(\\.[a-z0-9_-]+)*$") and length <= 253);
# Addresses as Go's netip parses them, which both backends do: one the backend refuses would
# fail its whole start. No leading zeros, no zone.
def v4: test("^(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}$") and all(split(".")[]; tonumber <= 255);
def v6_groups:
  split("::") as $parts
  | ($parts | length) as $n
  | [$parts[] | select(. != "") | split(":")[]] as $groups
  | $n <= 2 and ($groups | all(test("^[0-9a-f]{1,4}$")))
    and (if $n == 2 then ($groups | length) <= 7 else ($groups | length) == 8 end);
# An IPv4 tail (::ffff:192.0.2.1) counts as two groups.
def v6:
  test("^[0-9a-f:.]+$") and test(":")
  and (if test("\\.") then
         [match("^(.*:)([0-9.]+)$").captures[].string] as $m
         | ($m | length) == 2 and ($m[1] | v4) and ($m[0] + "0:0" | v6_groups)
       else v6_groups end);
def prefix($max): test("^(0|[1-9][0-9]{0,2})$") and tonumber <= $max;
# A bare address is its own /32 or /128.
def cidr:
  ascii_downcase | split("/") as $s
  | ($s | length) as $n
  | if $n > 2 then empty
    elif ($s[0] | v4) then (if $n == 1 then $s[0] + "/32" elif ($s[1] | prefix(32)) then . else empty end)
    elif ($s[0] | v6) then (if $n == 1 then $s[0] + "/128" elif ($s[1] | prefix(128)) then . else empty end)
    else empty end;
# geosite-NAME.srs, geosite:NAME: "geolocation-!cn" and "google@cn" among them, never a path.
def geo: select(test("^[A-Za-z0-9!@._-]{1,64}$") and (startswith(".") | not));
def tag: select(test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"));

(if length == 1 then .[0] else null end)
| [(.rules? // []) | if type == "array" then .[] else empty end
 | objects
 | select((.name | type) == "string" and (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")))
 | select((.target | type) == "string" and (.target | length) >= 1 and (.target | length) <= 128 and (.target | test("[[:cntrl:]]") | not))
 | {
     name,
     target,
     priority: (if (.priority | type) == "number" then (.priority | floor | if . < -1000000 then -1000000 elif . > 1000000 then 1000000 else . end) else 50 end),
     disabled: (.disabled == true),
     domains: ([.domains | strs[] | domain] | unique),
     ips: ([.ips | strs[] | cidr] | unique),
     geosites: ([.geosites | strs[] | geo] | unique),
     geoips: ([.geoips | strs[] | geo] | unique),
     ruleSets: ([.ruleSets | strs[] | tag] | unique)
   }]
| reduce .[] as $r ([]; if any(.[]; .name == $r.name) then . else . + [$r] end)
| sort_by(.priority, .name)
