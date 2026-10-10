# The rendered runtime routing rules (routing-render.jq) as the backend's: one section each,
# at the rule's priority, for routing-compose.jq to sort among the configuration's.
# A rule the backend would refuse (an outbound that is gone, a rule set this configuration does
# not declare) is left out and said why, so it never fails the whole start.
#
# $backend: sing-box or xray. $tags (slurped): every outbound tag the config will have.
# $rule_sets: the declared routing.ruleSets. $missing_geo (slurped): geosite-X/geoip-X with no
# .srs. $dir: where the
# rendered rule sets are. $geosite_dir/$geoip_dir: sing-box's geodata. $urltest: pure XRay's
# urltest, which prefixes every outbound and balances "proxy".
def builtin: . == "proxy" or . == "direct" or . == "block";
def category: if . == "direct" then "direct" elif . == "block" then "block" else "proxy" end;
def backend_tag: if $backend == "xray" and $urltest and (builtin | not) then "proxy-suite-ob-" + . else . end;
def xray_target: if . == "proxy" and $urltest then {balancerTag: "proxy"} else {outboundTag: backend_tag} end;
def local_set($tag; $path; $format): {type: "local", format: $format, tag: $tag, path: $path};
def why:
  if (.target | builtin | not) and ((.target | backend_tag) as $t | $tags[0] | index([$t]) | not) then
    "no outbound or group named \(.target)"
  elif $backend == "xray" and .ruleSets != [] then
    "rule sets need the sing-box or hybrid backend"
  elif (.ruleSets - $rule_sets) != [] then
    "no rule set named \((.ruleSets - $rule_sets) | join(", ")) in routing.ruleSets"
  elif ([.geosites[] | "geosite-" + .] + [.geoips[] | "geoip-" + .] | any(. as $g | $missing_geo[0] | index([$g]))) then
    "no such geosite or geoip: \([.geosites[] | "geosite-" + .] + [.geoips[] | "geoip-" + .] | map(select(. as $g | $missing_geo[0] | index([$g]))) | join(", "))"
  else null end;

[.[] | select(.disabled | not)] as $rules
| [$rules[] | why as $why | select($why != null) | {name, why: $why}] as $skipped
| [$rules[] | select(why == null)] as $ok
| {
    skipped: $skipped,
    sections: [$ok[] | . as $r | {
      prio: .priority,
      cat: (.target | category),
      name: .name,
      rules: (
        if $backend == "xray" then
          # XRay takes a ruleTag once.
          ({type: "field"} + (.target | xray_target)) as $base
          | ([.domains[] | "domain:" + .] + [.geosites[] | "geosite:" + .]) as $domain
          | (.ips + [.geoips[] | "geoip:" + .]) as $ip
          | (if $domain != [] then [$base + {ruleTag: ("user:" + $r.name), domain: $domain}] else [] end)
            + (if $ip != [] then [$base + {ruleTag: ("user:" + $r.name + ":ip"), ip: $ip}] else [] end)
        else
          # Always, its own rule set first even while empty: matches added later reach sing-box
          # by the file alone, no restart. The guards find a runtime rule by that first tag.
          [{rule_set: (["user:" + .name] + [.geosites[] | "geosite-" + .] + [.geoips[] | "geoip-" + .]
                       + [.ruleSets[] | "ruleset-" + .]),
            outbound: .target}]
        end),
      # As the configuration's lookups follow its routing (rules/sing-box.nix): names only.
      dns: (
        if $backend == "xray" or .target == "block" then []
        else [{rule_set: (["user-dns:" + .name] + [.geosites[] | "geosite-" + .]
                          + [.ruleSets[] | "ruleset-" + . + "-dns"]),
               server: (if .target == "direct" then "local" else "remote" end)}]
        end)
    }],
    rule_sets: (
      if $backend == "xray" then []
      else
        [$ok[] | local_set("user:" + .name; $dir + "/rs/" + .name + ".json"; "source"),
                 local_set("user-dns:" + .name; $dir + "/dns/" + .name + ".json"; "source")]
        + ([$ok[].geosites[]] | unique | map(local_set("geosite-" + .; $geosite_dir + "/geosite-" + . + ".srs"; "binary")))
        + ([$ok[].geoips[]] | unique | map(local_set("geoip-" + .; $geoip_dir + "/geoip-" + . + ".srs"; "binary")))
      end)
  }
