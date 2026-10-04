def sing_box_preserved_rules:
  [.route.rules[]
   | select(((.action? // "") == "hijack-dns")
     and (((.inbound? // []) | index("xray-dns-in")) != null))];
# perAppRouting.via's pin rules, which no route mode replaces.
def is_pin: ((.outbound? // "") | type) == "string" and ((.outbound? // "") | startswith("proxy-suite-pin-"));
([.route.rules[]? | select(is_pin)]) as $pin_rules
| .outbounds = ($obs[0] + .outbounds)
  | if $auth_enabled then
      (.inbounds[] | select(.type == "mixed" and .tag == "mixed-in") | .users) = [{username:$user,password:$password}]
    else . end
  | if $route_enabled then
      .route.rules = (sing_box_preserved_rules + $route_rules)
      | .route.final = $route_final
      | .dns.final = $dns_final
      | if $clear_dns_rules then
          .dns.rules = .dns.rules[:@userDnsRuleCount@]
            + [.dns.rules[@userDnsRuleCount@:][] | select(.server? == "fakeip" or .domain_suffix? == ["onion"])]
        else . end
    else . end
  # autoProxy rules, after the route-mode replace so no mode drops them: pins first
  # (they only match their own listener), learned rules last before final, so
  # explicit rules win. All [] when off.
  | .inbounds += $probe_inbounds
  # The loopback probe and test listeners reach every exit: with listener.auth, the
  # same login, or any local user would get past it through them.
  | if $auth_enabled then
      (.inbounds[] | select(.type == "mixed" and (.tag == "proxy-suite-test-in" or (.tag | startswith("probe-in-")))) | .users)
        = [{username:$user,password:$password}]
    else . end
  | .route.rule_set = ((.route.rule_set // []) + $autoproxy_rule_sets)
  | .route.rules = ($probe_pin_rules + .route.rules + $autoproxy_rules)
  # Pins after the common hijack-dns and sniff rules, so a pinned app's lookups are answered
  # as any other's, and before every rule that picks an outbound.
  | .route.rules |= [.[] | select(is_pin | not)]
  | (.route.rules | map((.action? // "") == "sniff") | index(true)) as $sniff
  | .route.rules = (if $sniff == null then $pin_rules + .route.rules
      else .route.rules[:$sniff + 1] + $pin_rules + .route.rules[$sniff + 1:] end)
  # Each pin's selector takes any outbound, block first: a slot nobody switched blocks.
  | ([.outbounds[].tag | select(startswith("proxy-suite-pin-") | not)]) as $tags
  | .outbounds |= map(if .type == "selector" and (.tag | startswith("proxy-suite-pin-"))
      then .outbounds = (["block"] + ($tags - ["block"])) | .default = "block" else . end)
