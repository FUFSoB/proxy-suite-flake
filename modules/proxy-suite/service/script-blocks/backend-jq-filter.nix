{
  pureXrayEnabled,
  selectionMode,
}:

if pureXrayEnabled then
  ''
    def xray_bind_outbound($interface):
      if $interface == "" or .protocol == "blackhole" or .protocol == "dns" then
        .
      else
        .streamSettings = (.streamSettings // {})
        | .streamSettings.sockopt = (.streamSettings.sockopt // {})
        | if (.streamSettings.sockopt.interface? // "") == "" then
            .streamSettings.sockopt.interface = $interface
          else
            .
          end
      end;
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
    def xray_tun_dns_addresses($dns_final; $local_addr; $remote_addr):
      if $dns_final == "local" then
        [$local_addr, $remote_addr]
      elif $dns_final == "remote" then
        [$remote_addr, $local_addr]
      else
        [$remote_addr, $local_addr]
      end;
    .outbounds = (($obs + .outbounds) | map(xray_bind_outbound($xray_bind_interface)))
      | if $xray_loglevel == "" then . else .log.loglevel = $xray_loglevel end
      | if $auth_enabled then
          (.inbounds[] | select(.protocol == "socks" and .tag == "mixed-in") | .settings.auth) = "password"
          | (.inbounds[] | select(.protocol == "socks" and .tag == "mixed-in") | .settings.accounts) = [{user:$user,pass:$password}]
        else . end
      | if $xray_tun_dns_runtime then
          .dns.servers = xray_dns_server_order($dns_final)
          | if $dns_final == "" then
              .
            else
              (.inbounds[] | select(.protocol == "tun" and .tag == "tun-in") | .settings.dns) = xray_tun_dns_addresses($dns_final; $xray_dns_local_client; $xray_dns_remote_client)
            end
        else . end
      | if $route_enabled then
          .routing.rules = (xray_preserved_rules + $route_rules + [xray_final_rule($route_final; $xray_single_proxy_tag)])
        else . end
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
    .outbounds = $obs + .outbounds
      | if $auth_enabled then
          (.inbounds[] | select(.type == "mixed" and .tag == "mixed-in") | .users) = [{username:$user,password:$password}]
        else . end
      | if $route_enabled then
          .route.rules = (sing_box_preserved_rules + $route_rules)
          | .route.final = $route_final
          | .dns.final = $dns_final
          | if $clear_dns_rules then .dns.rules = [] else . end
        else . end
  ''
