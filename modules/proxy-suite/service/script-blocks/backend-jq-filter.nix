{
  lib,
  pureXrayEnabled,
  selectionMode,
  proxyInboundsGuardPrivate,
  userDnsRules ? [ ],
  selectionExclude ? [ ],
}:

if pureXrayEnabled then
  ''
    def xray_proxy_rule_target($single_tag):
      if $single_tag != "" then
        {outboundTag:$single_tag}
      else
        {balancerTag:"proxy"}
      end;
    def xray_rewrite_proxy_rule($single_tag):
      if $single_tag != "" and (.balancerTag? // "") == "proxy" then
        .outboundTag = $single_tag | del(.balancerTag)
      else
        .
      end;
    def xray_preserved_rules:
      [.routing.rules[]
       | select(((.ruleTag? // "") == "dns-hijack") or ((.ruleTag? // "") == "dns-upstream-direct"))];
    def xray_final_rule($tag; $single_tag):
      if $tag == "proxy" and "${selectionMode}" == "urltest" then
        {type:"field",network:"tcp,udp",ruleTag:"final-default"} + xray_proxy_rule_target($single_tag)
      else
        {type:"field",network:"tcp,udp",ruleTag:"final-default",outboundTag:$tag}
      end;
    def xray_dns_server_order($dns_final):
      if $dns_final == "" then
        .dns.servers
      else
        ([.dns.servers[] | select((.tag? // "") == "fakedns")]
         + [.dns.servers[] | select((.tag? // "") == $dns_final)]
         + [.dns.servers[] | select((.tag? // "") != "fakedns" and (.tag? // "") != $dns_final)])
      end;
    .outbounds = ($obs + .outbounds)
      | if $xray_loglevel == "" then . else .log.loglevel = $xray_loglevel end
      | if $auth_enabled then
          (.inbounds[] | select(.protocol == "socks" and .tag == "mixed-in") | .settings.auth) = "password"
          | (.inbounds[] | select(.protocol == "socks" and .tag == "mixed-in") | .settings.accounts) = [{user:$user,pass:$password}]
        else . end
      | if $xray_tun_dns_runtime then
          .dns.servers = xray_dns_server_order($dns_final)
          # Without a domainStrategy a dial resolves through the system resolver, which under
          # the TUN (resolved's upstream queries included) hands out fake IPs. XRay's own DNS
          # client skips fakedns.
          | .outbounds |= map(
              if .protocol == "blackhole" or .protocol == "dns" or .protocol == "loopback" then .
              else .streamSettings.sockopt.domainStrategy //= "UseIPv4v6" end)
        else . end
      | if $route_enabled then
          .routing.rules = (xray_preserved_rules + $route_rules + [xray_final_rule($route_final; $xray_single_proxy_tag)])
        else . end
      ${lib.optionalString (selectionExclude != [ ]) ''
        # The balancer's prefix would take in proxy.selectionExclude too: name the rest instead.
        # ponytail: selectors are prefixes still, so "de" also takes in an excluded "de-hop";
        # rename one of them if that matters.
        | ($xray_selectable | map("proxy-suite-ob-" + .)) as $candidates
        | if .routing.balancers then .routing.balancers |= map(.selector = $candidates) else . end
        | if .observatory then .observatory.subjectSelector = $candidates else . end
      ''}
      | if $xray_single_proxy_tag == "" then
          .
        else
          .routing.rules |= map(xray_rewrite_proxy_rule($xray_single_proxy_tag))
          | del(.routing.balancers)
          | del(.observatory)
        end
  ''
else
  ''
    def sing_box_preserved_rules:
      [.route.rules[]
       | select(((.action? // "") == "hijack-dns")
         and (((.inbound? // []) | index("xray-dns-in")) != null))];
    .outbounds = ($obs + .outbounds)
      | if $auth_enabled then
          (.inbounds[] | select(.type == "mixed" and .tag == "mixed-in") | .users) = [{username:$user,password:$password}]
        else . end
      | if $route_enabled then
          .route.rules = (sing_box_preserved_rules + $route_rules)
          | .route.final = $route_final
          | .dns.final = $dns_final
          | if $clear_dns_rules then
              .dns.rules = .dns.rules[:${toString (builtins.length userDnsRules)}]
                + [.dns.rules[${toString (builtins.length userDnsRules)}:][] | select(.server? == "fakeip")]
            else . end
        else . end
      # autoProxy rules, after the route-mode replace so no mode drops them: pins first
      # (they only match their own listener), learned rules last before final, so
      # explicit rules win. All [] when off.
      | .inbounds += $probe_inbounds
      | .route.rule_set = ((.route.rule_set // []) + $autoproxy_rule_sets)
      | .route.rules = ($probe_pin_rules + .route.rules + $autoproxy_rules)
  ''
  + lib.optionalString proxyInboundsGuardPrivate ''
    # inbounds.routing.blockPrivate, enforced here because the listener passes names unresolved.
    # Just before the first direct rule (or last, for a direct final), so names that the
    # proxy rules above take stay unresolved and none reaches a direct dial unchecked. Local
    # mixed-in clients lose names that resolve private.
    | [{inbound: ["mixed-in"], action: "resolve"},
       {inbound: ["mixed-in"], ip_is_private: true, action: "reject"}] as $guard
    | (.route.rules | map((.outbound? // "") == "direct") | index(true)) as $first_direct
    | if $first_direct != null then
        .route.rules = .route.rules[:$first_direct] + $guard + .route.rules[$first_direct:]
      elif (.route.final // "direct") == "direct" then
        .route.rules += $guard
      else . end
  ''
