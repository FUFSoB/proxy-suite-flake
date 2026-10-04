def xray_proxy_rule_target($single_tag):
  if $single_tag != "" then
    {outboundTag:$single_tag}
  else
    {balancerTag:"proxy"}
  end;
def xray_rewrite_proxy_rule($single_tag):
  # "proxy" is a balancer in urltest and no outbound at all in "first": either way, the one exit.
  if $single_tag != "" and ((.balancerTag? // .outboundTag? // "") == "proxy") then
    .outboundTag = $single_tag | del(.balancerTag)
  else
    .
  end;
def xray_preserved_rules:
  [.routing.rules[]
   | select((.ruleTag? // "") | . == "dns-hijack" or . == "dns-upstream-direct" or . == "dns-upstream-remote")];
def xray_final_rule($tag; $single_tag):
  if $tag == "proxy" and "@selectionMode@" == "urltest" then
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
# Names of proxy servers, which XRay's DNS resolves once a dial has a domainStrategy.
def xray_server_names:
  [.outbounds[].settings
   | (.vnext[]?.address, .servers[]?.address, .address?)
   | strings | select(test("^[0-9.]+$|:|^localhost$") | not)]
  | unique;
# A copy of "local" answering only for them: routed direct by its tag, so looking up a
# proxy server never waits on that proxy.
def xray_pin_server_names:
  xray_server_names as $names
  | if $names == [] then .
    else .dns.servers += [.dns.servers[] | select((.tag? // "") == "local")
                          | . + {domains: ($names | map("full:" + .)), skipFallback: true}]
    end;
.outbounds = ($obs[0] + .outbounds)
  | if $xray_loglevel == "" then . else .log.loglevel = $xray_loglevel end
  | if $auth_enabled then
      (.inbounds[] | select(.protocol == "socks" and .tag == "mixed-in") | .settings.auth) = "password"
      | (.inbounds[] | select(.protocol == "socks" and .tag == "mixed-in") | .settings.accounts) = [{user:$user,pass:$password}]
    else . end
  | .dns.servers = xray_dns_server_order($dns_final)
  | xray_pin_server_names
  | if $xray_tun_dns_runtime then
      # Without a domainStrategy a dial resolves through the system resolver, whose upstream
      # queries the TUN answers with fake IPs and TProxy sends through the proxy being
      # dialed. XRay's own DNS client skips fakedns.
      .outbounds |= map(
          if .protocol == "blackhole" or .protocol == "dns" or .protocol == "loopback" then .
          else .streamSettings.sockopt.domainStrategy //= "UseIPv4v6" end)
    else . end
  | if $route_enabled then
      .routing.rules = (xray_preserved_rules + $route_rules + [xray_final_rule($route_final; $xray_single_proxy_tag)])
    else . end
  # The balancer's prefix would take in proxy.selectionExclude and disabled outbounds
  # too: name the rest instead. Disabling is a runtime decision, so always.
  # ponytail: selectors are prefixes still, so "de" also takes in an excluded "de-hop";
  # rename one of them if that matters.
  | if $ARGS.named.xray_selectable == null then . else
      ($ARGS.named.xray_selectable | map("proxy-suite-ob-" + .)) as $candidates
      | if .routing.balancers then .routing.balancers |= map(.selector = $candidates) else . end
      | if .observatory then .observatory.subjectSelector = $candidates else . end
    end
  | if $xray_single_proxy_tag == "" then
      .
    else
      .routing.rules |= map(xray_rewrite_proxy_rule($xray_single_proxy_tag))
      | del(.routing.balancers)
      | del(.observatory)
    end
