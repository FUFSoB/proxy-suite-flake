def sing_box_preserved_rules:
  [.route.rules[]
   | select(((.action? // "") == "hijack-dns")
     and (((.inbound? // []) | index("xray-dns-in")) != null))];
.outbounds = ($obs[0] + .outbounds)
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
