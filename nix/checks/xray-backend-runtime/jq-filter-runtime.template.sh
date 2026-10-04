OBS='[{"protocol":"freedom","tag":"proxy-suite-ob-primary"},
  {"protocol":"vless","tag":"proxy-suite-ob-edge","settings":{"vnext":[{"address":"edge.example.com","port":443}]}},
  {"protocol":"trojan","tag":"proxy-suite-ob-ip","settings":{"servers":[{"address":"203.0.113.1","port":443}]}}]'

check_runtime() {
  local name="$1"
  local input="$2"
  local output="$TMPDIR/$name.json"

  jq \
    --slurpfile obs <(printf "%s" "$OBS") \
    --argjson auth_enabled false \
    --arg user "" \
    --arg password "" \
    --argjson route_enabled true \
    --argjson route_rules '[]' \
    --arg route_final "proxy" \
    --arg dns_final "remote" \
    --argjson clear_dns_rules false \
    --arg xray_loglevel "" \
    --arg xray_single_proxy_tag "proxy-suite-ob-primary" \
    --argjson xray_tun_dns_runtime true \
    -f @jqFilter@ \
    "$input" > "$output"

  jq -e \
    '
      type == "object"
      and (.dns.servers | length) >= 3
      and .dns.servers[0].tag == "fakedns"
      and ([.routing.rules[] | select((.ruleTag? // "") == "dns-hijack")] | length) == 1
      and ([.routing.rules[] | select((.ruleTag? // "") == "dns-upstream-direct")] | length) == 1
      and ([.routing.rules[] | select((.ruleTag? // "") == "dns-upstream-remote")] | length) == 1
      and ([.dns.servers[] | select(.domains?)] == [.dns.servers[] | select(.tag == "local" and (has("domains") | not))
            | . + {domains: ["full:edge.example.com"], skipFallback: true}])
      and ([.outbounds[] | select(.streamSettings.sockopt.interface?)] | length) == 0
      and ([.outbounds[] | select(.protocol == "freedom" or .tag == "proxy-suite-ob-primary") | .streamSettings.sockopt.domainStrategy] | all(. == "UseIPv4v6"))
      and ([.outbounds[] | select(.protocol == "dns") | .streamSettings.sockopt.domainStrategy?] | all(. == null))
      and ([.inbounds[] | select(.tag == "tun-in") | .settings | has("dns") or has("autoOutboundsInterface")] | any | not)
      and ((.routing | has("balancers")) | not)
      and ((has("observatory")) | not)
    ' "$output" >/dev/null
}

check_runtime global @tunConfig@
check_runtime per-app @perAppTunConfig@
touch "$out"
