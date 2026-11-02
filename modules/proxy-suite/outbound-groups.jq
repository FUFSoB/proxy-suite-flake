# Outbound groups, resolved at start: subscription entries and runtime outbounds only exist then.
#
# Input: {tags: [outbound tags, in build order], sources: {tag: source label}, detours: {tag: the
# outbound or group it chains through}}.
# Args: $groups {name: {outbounds, subscriptions, match, strategy, failback, interval}},
# $priority {tag: n}, $disabled [tags], $pins {group: member}, $url, $interval, $tolerance,
# $watched: whether proxy-suite-outbound-groups drives this instance's failover groups through
# its Clash API. Without it (the TUN instances) a failover group is sing-box's own urltest.
#
# Output: {groups: {name: {strategy, failback, interval, members, listed, pinned}}, outbounds: [the
# sing-box group outbounds], top: [what the top level picks among, in order], loops: [groups
# inside themselves], warnings, errors}.
# Errors mean the config cannot be built (a group inside itself); warnings are dropped members
# and pins.

def glob_regex: "^" + (gsub("(?<c>[.+^$()\\[\\]{}|\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "\\z";

(.tags) as $tags
| (.sources // {}) as $sources
| (.detours // {}) as $hops
| ($groups | keys_unsorted) as $names
| ($tags | to_entries | map({key: .value, value: .key}) | from_entries) as $position

# Members as configured: the explicit list in its order, then the rest by priority, then build
# order. A member that names nothing running is dropped with a warning: a subscription entry or
# a runtime outbound may be gone, and that must not stop the proxy.
| (reduce $names[] as $g ({members: {}, warnings: []};
    ($groups[$g]) as $cfg
    | [($cfg.outbounds // [])[] | select(. != $g)] as $explicit
    | ($explicit | map(select(. as $t | ($tags | index([$t])) == null and ($names | index([$t])) == null))) as $missing
    | ([$tags[] | . as $t
        | select(($cfg.subscriptions // []) | any(. as $s | $sources[$t] == ("sub:" + $s)))]
       + [($tags + $names)[] | . as $t | select($t != $g)
          | select(($cfg.match // []) | any(. as $p | $t | test($p | glob_regex)))]) as $pulled
    | ($pulled | unique | map(select(. as $t | $explicit | index([$t]) | not))
       | sort_by([$priority[.] // 1000000000, $position[.] // 1000000000, .])) as $rest
    | .members[$g] = ([$explicit[] | select(. as $t | $missing | index([$t]) | not)] + $rest)
    | .warnings += [$missing[] | "group '\($g)': member '\(.)' is not available; leaving it out"]
  )) as $resolved

# A group a chain goes through (a detour names it, or the hop's own detour, on down) cannot pick
# a member that dials back through it - itself, a group it holds, or what one of those chains
# through: sing-box refuses that loop, so the member is left out of the group. A loop of
# groups alone is left to $loops.
| def closure(f): {seen: (map({key: ., value: true}) | from_entries), next: .}
    | until(.next == []; .seen as $s
        | ([.next[] | f[]] | unique | map(select($s[.] | not))) as $n
        | .seen += ($n | map({key: ., value: true}) | from_entries) | .next = $n)
    | .seen;
  ([$hops[]] | unique | map({key: ., value: ([.] | closure([$hops[.] // empty] + ($resolved.members[.] // [])))})
   | from_entries) as $beyond
| ([$hops[] | limit($hops | length + 1; recurse($hops[.] // empty)) | select(. as $t | $names | index([$t]))]
   | unique) as $chained
| (reduce $names[] as $g ({members: {}, warnings: []};
    [$resolved.members[$g][] | select(($chained | index([$g]))
       and ([[.] | closure($resolved.members[.] // []) | keys[] | $hops[.] // empty]
            | any(.[]; $beyond[.][$g] == true)))] as $out
    | .members[$g] = ($resolved.members[$g] - $out)
    | .warnings += [$out[] | "group '\($g)': member '\(.)' chains through it; leaving it out"]
  )) as $unchained
| $unchained.members as $members

# A group inside itself, however deep, has no member to end on.
| def reach($g; $seen):
    [$members[$g][] | select(. as $m | $names | index([$m]))] as $sub
    | $sub + [$sub[] | . as $m | select($seen | index([$m]) | not) | reach($m; $seen + [$m])[]];
  [$names[] as $g | select(reach($g; [$g]) | index([$g])) | $g] as $loops

# Where a group sits when nothing sets its priority: where its first member would have.
| def spot($g; $seen):
    [$members[$g][] | . as $m | if ($names | index([$m])) and ($seen | index([$m]) | not) then spot($m; $seen + [$m])
                      else $position[.] end | select(. != null)] | min;
  ($names | map({key: ., value: (spot(.; [.]) // 1000000000)}) | from_entries) as $spots

| ([$members[]] | add // [] | unique) as $grouped
| ([$tags[], $names[]] | map(select(. as $t | $grouped | index([$t]) | not))
   | sort_by([$priority[.] // 1000000000, ($position[.] // $spots[.] // 1000000000)])) as $top

| (reduce $names[] as $g ({groups: {}, outbounds: [], warnings: []};
    ($groups[$g]) as $cfg
    | ($members[$g]) as $all
    | [$all[] | select(. as $t | $disabled | index([$t]) | not)] as $usable
    | ($pins[$g] // "") as $pin
    | (if $pin == "" then ""
       elif ($all | index([$pin])) == null then "unknown"
       elif ($disabled | index([$pin])) then "disabled"
       else $pin end) as $pinned
    | .warnings += (if $pinned == "unknown" then ["group '\($g)': pinned member '\($pin)' is not in it; picking automatically"]
                    elif $pinned == "disabled" then ["group '\($g)': pinned member '\($pin)' is disabled; picking automatically"]
                    else [] end)
    | (if $pinned == "unknown" or $pinned == "disabled" then "" else $pinned end) as $pinned
    # With nothing to pick, the group blocks rather than disappear: rules naming it must not
    # fall through to direct.
    | .warnings += (if $usable == [] then ["group '\($g)' has no available member; it blocks until one is"] else [] end)
    | (if $all == [] then ["block"] else $all end) as $all
    | (if $usable == [] then ["block"] else $usable end) as $usable
    # What the selector holds: its default among them, block when every member is disabled.
    | ($all + ($usable - $all)) as $picks
    | ($cfg.interval // (if $cfg.strategy == "urltest" then $interval else "30s" end)) as $every
    # listed: the members the group names itself, which the front ends edit; members adds those
    # its subscriptions and patterns pull in.
    | .groups[$g] = {strategy: $cfg.strategy, failback: ($cfg.failback != false), interval: $every,
                     members: $all, listed: [($cfg.outbounds // [])[] | select(. != $g)],
                     pinned: $pinned, runtime: ($cfg.runtime // false)}
    | .outbounds += [
        if ($cfg.strategy == "urltest" or ($cfg.strategy == "failover" and ($watched | not))) and $pinned == "" then
          {type: "urltest", tag: $g, outbounds: $usable, url: $url, interval: $every, tolerance: $tolerance}
        else
          # A pin holds any strategy, as the top-level pin does: a selector the Clash API switches.
          {type: "selector", tag: $g, outbounds: $picks,
           default: (if $pinned != "" then $pinned else $usable[0] end)}
          + (if $cfg.strategy == "failover" then {interrupt_exist_connections: true} else {} end)
        end]
  )) as $built

| {groups: $built.groups,
   # Inner groups first: sing-box wants an outbound defined before a group names it.
   outbounds: ($built.outbounds | sort_by(.tag as $t | [$names[] | select(reach(.; [.]) | index([$t]))] | -length)),
   top: $top,
   warnings: ($resolved.warnings + $unchained.warnings + $built.warnings),
   # The start script drops a runtime group in a loop and tries again; a declared one is fatal.
   loops: $loops,
   errors: [$loops[] | "group '\(.)' contains itself"]}
