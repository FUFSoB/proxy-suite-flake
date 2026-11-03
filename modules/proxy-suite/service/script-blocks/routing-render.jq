# routing.d/rules.json, as userControl's group wrote it (slurped: one document, else none), to
# the rules root applies: each field checked, anything else dropped, a name once. Sorted in
# match order (priority, then name). \z, not $, ends each pattern: $ matches before a final
# newline too.
def strs: if type == "array" then [.[] | strings] else [] end;
def domain: ascii_downcase | ltrimstr(".") | select(test("^[a-z0-9_-]+(\\.[a-z0-9_-]+)*\\z") and length <= 253);
# Addresses as Go's netip parses them, which both backends do: one the backend refuses would
# fail its whole start. No leading zeros, no zone.
def v4: test("^(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}\\z") and all(split(".")[]; tonumber <= 255);
def v6_groups:
  split("::") as $parts
  | ($parts | length) as $n
  | [$parts[] | select(. != "") | split(":")[]] as $groups
  | $n <= 2 and ($groups | all(test("^[0-9a-f]{1,4}\\z")))
    and (if $n == 2 then ($groups | length) <= 7 else ($groups | length) == 8 end);
# An IPv4 tail (::ffff:192.0.2.1) counts as two groups.
def v6:
  test("^[0-9a-f:.]+\\z") and test(":")
  and (if test("\\.") then
         [match("^(.*:)([0-9.]+)\\z").captures[].string] as $m
         | ($m | length) == 2 and ($m[1] | v4) and ($m[0] + "0:0" | v6_groups)
       else v6_groups end);
def prefix($max): test("^(0|[1-9][0-9]{0,2})\\z") and tonumber <= $max;
# A bare address is its own /32 or /128.
def cidr:
  ascii_downcase | split("/") as $s
  | ($s | length) as $n
  | if $n > 2 then empty
    elif ($s[0] | v4) then (if $n == 1 then $s[0] + "/32" elif ($s[1] | prefix(32)) then . else empty end)
    elif ($s[0] | v6) then (if $n == 1 then $s[0] + "/128" elif ($s[1] | prefix(128)) then . else empty end)
    else empty end;
# geosite-NAME.srs, geosite:NAME: "geolocation-!cn" and "google@cn" among them, never a path.
def geo: select(test("^[A-Za-z0-9!@._-]{1,64}\\z") and (startswith(".") | not));
# keyword:WORD, as XRay spells it: a part of a name.
def keyword: ascii_downcase | select(test("^[a-z0-9_.-]{1,64}\\z"));
# regexp:PATTERN, which both backends hand to Go's regexp (RE2): none of what it lacks
# (lookaround, backreferences, atomic or possessive groups, conditionals, comments), no control
# character, and one that compiles. One the backend refused would fail its whole start.
def regex:
  select(length >= 1 and length <= 256
    and (explode | all(. >= 32 and . != 127))
    and (test("\\(\\?[=!<>(#PCRk]|\\\\[1-9kgG]|[*+?}]\\+") | not)
    and (. as $r | (try ("" | test($r)) catch "bad") != "bad"));
def tag: select(test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\z"));

(if length == 1 then .[0] else null end)
| [(.rules? // []) | if type == "array" then .[] else empty end
 | objects
 | select((.name | type) == "string" and (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\z")))
 | select((.target | type) == "string" and (.target | length) >= 1 and (.target | length) <= 128 and (.target | test("[[:cntrl:]]") | not))
 | {
     name,
     target,
     priority: (if (.priority | type) == "number" then (.priority | floor | if . < -1000000 then -1000000 elif . > 1000000 then 1000000 else . end) else 50 end),
     disabled: (.disabled == true),
     domains: ([.domains | strs[] | domain] | unique),
     fullDomains: ([.fullDomains | strs[] | domain] | unique),
     keywords: ([.keywords | strs[] | keyword] | unique),
     regexps: ([.regexps | strs[] | regex] | unique),
     ips: ([.ips | strs[] | cidr] | unique),
     geosites: ([.geosites | strs[] | geo] | unique),
     geoips: ([.geoips | strs[] | geo] | unique),
     ruleSets: ([.ruleSets | strs[] | tag] | unique),
     # Autonomous system numbers, as asn:N: whole numbers in range, no more than 64 of them.
     asns: ([(.asns | if type == "array" then .[] else empty end)
             | numbers | select(. >= 1 and . <= 4294967295 and . == floor)] | unique | .[:64])
   }]
| reduce .[] as $r ([]; if any(.[]; .name == $r.name) then . else . + [$r] end)
| sort_by(.priority, .name)
