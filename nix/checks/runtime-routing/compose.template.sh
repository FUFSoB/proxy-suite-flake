# Runtime routing rules through the real generated programs: the start script's convert and
# compose steps, then the backend filter, over a spool with good and bad entries; the result
# through the backend's own check. Paths are read out of the start script, as it runs them.
set -eu
export HOME=$PWD

# $1 start script: the store paths it hands jq.
paths() {
  START=$1
  FILTER=$(grep -o 'BACKEND_JQ_FILTER=[^ ]*' "$START" | head -n 1 | cut -d= -f2)
  CONFIG=$(grep -o '"/nix/store/[a-z0-9]*-proxy-suite-core" > "$RUNTIME_DIR/config.json"' "$START" | grep -o '/nix/store/[a-z0-9]*-proxy-suite-core')
  BUCKETS=$(grep -o 'routing-compose.jq "/nix/store/[^"]*' "$START" | grep -o '/nix/store/.*')
  CONVERT=$(grep -o '/nix/store/[^ ]*routing-convert.jq' "$START" | head -n 1)
  COMPOSE=$(grep -o '/nix/store/[^ ]*routing-compose.jq' "$START" | head -n 1)
  GEOSITE_DIR=$(grep -o -- '--arg geosite_dir [^ ]*' "$START" | head -n 1 | cut -d' ' -f3)
  GEOIP_DIR=$(grep -o -- '--arg geoip_dir [^ ]*' "$START" | head -n 1 | cut -d' ' -f3)
  URLTEST=$(grep -o -- '--argjson urltest [a-z]*' "$START" | head -n 1 | cut -d' ' -f3)
  BACKEND=$(grep -o -- '--arg backend [a-z-]*' "$START" | head -n 1 | cut -d' ' -f3)
  for v in FILTER CONFIG BUCKETS CONVERT COMPOSE GEOSITE_DIR GEOIP_DIR URLTEST BACKEND; do
    if [ -z "$(eval "printf %s \"\$$v\"")" ]; then
      echo "no $v in $START" >&2
      exit 1
    fi
  done
}

# The spool as a member might leave it: a name twice, a path for a name, junk in the lists.
cat > spool.json <<'JSON'
{"rules": [
  {"name": "bank", "target": "direct", "priority": 50, "domains": [".Bank.Example", "bad domain"],
   "ips": ["192.0.2.1", "nope"], "geosites": ["category-gov-ru", "../x"]},
  {"name": "bank", "target": "proxy"},
  {"name": "../evil", "target": "proxy"},
  {"name": "ads", "target": "block", "priority": 10, "domains": ["ads2.example"]},
  {"name": "work", "target": "primary", "priority": 450, "domains": ["work.example"],
   "ips": ["198.51.100.0/24", "999.1.1.1", "198.51.100.1/33", "010.0.0.1", "1::2::3"]},
  {"name": "gone", "target": "removed-outbound", "domains": ["x.example"]},
  {"name": "nogeo", "target": "proxy", "geosites": ["no-such-list"]},
  {"name": "empty", "target": "proxy", "priority": 250},
  {"name": "off", "target": "proxy", "disabled": true, "domains": ["off.example"]}
]}
JSON
# The render script root runs, as the start script calls it, into ./routing.
RENDER=$(grep -A1 "^RUNTIME_ROUTING_SKIPPED='\[\]'" @singBoxStart@ | tail -n 1)
mkdir spool
cp spool.json spool/rules.json
mkdir -p routing/rs
echo '{}' > routing/rs/old.json
"$RENDER" "$PWD/spool" "$PWD/routing"
cp routing/rules.json rendered.json
jq -e '
  map(.name) == ["ads", "bank", "gone", "nogeo", "off", "empty", "work"]
  and (.[] | select(.name == "bank") | .domains == ["bank.example"] and .ips == ["192.0.2.1/32"]
       and .geosites == ["category-gov-ru"] and .target == "direct")
' rendered.json > /dev/null
# A rule set per rule, domains and addresses for routing, domains alone for lookups; an address
# the backends would refuse (and with it the whole start) is dropped.
jq -e '.rules == [{domain_suffix: ["work.example"]}, {ip_cidr: ["198.51.100.0/24"]}]' routing/rs/work.json > /dev/null
jq -e '.rules == [{domain_suffix: ["work.example"]}]' routing/dns/work.json > /dev/null
jq -e '.rules == []' routing/rs/empty.json > /dev/null
# What restarts the backends: everything but the domains and addresses of enabled rules.
jq -e --slurpfile r rendered.json '. == ($r[0] | map(select(.disabled | not) | del(.domains, .ips)))' routing/structure > /dev/null
# A rule gone: its rule set stays until apply sweeps, once the backends restarted.
[ -e routing/rs/old.json ]
"$RENDER" --sweep "$PWD/spool" "$PWD/routing"
[ ! -e routing/rs/old.json ] && [ -e routing/rs/work.json ]
# Only a change is renamed in: sing-box reloads a rule set on every new file.
before=$(stat -c %i routing/rs/work.json)
"$RENDER" "$PWD/spool" "$PWD/routing"
[ "$(stat -c %i routing/rs/work.json)" = "$before" ]
# A member's symlink, what is not JSON, an empty file or two documents are no rule at all, and
# no failure.
mkdir bad-link bad-json bad-empty bad-two
ln -s "$PWD/spool/rules.json" bad-link/rules.json
echo 'not json' > bad-json/rules.json
: > bad-empty/rules.json
cat spool.json spool.json > bad-two/rules.json
for spool in bad-link bad-json bad-empty bad-two; do
  "$RENDER" "$PWD/$spool" "$PWD/out-$spool"
  jq -e '. == []' "out-$spool/rules.json" > /dev/null
done

# $1 start script, $2 mode ("": none), $3 the outbounds the start script would add, $4 out.
compose() {
  paths "$1"
  MODE=$2 OBS=$3 OUT=$4
  MISSING=$(jq -r '[.[] | select(.disabled | not) | (.geosites[] | "geosite-" + .), (.geoips[] | "geoip-" + .)] | unique[]' rendered.json \
    | while read -r geo; do
        case "$geo" in
          geosite-*) [ -e "$GEOSITE_DIR/$geo.srs" ] || printf '%s\n' "$geo" ;;
          *) [ -e "$GEOIP_DIR/$geo.srs" ] || printf '%s\n' "$geo" ;;
        esac
      done | jq -R . | jq -cs .)
  TAGS=$(jq -c --argjson obs "$OBS" '[($obs[]?, .outbounds[]?) | .tag? | strings] | unique' "$CONFIG")
  jq -c --arg backend "$BACKEND" --slurpfile tags <(echo "$TAGS") --argjson rule_sets '[]' \
    --slurpfile missing_geo <(echo "$MISSING") --arg dir "$PWD/routing" --arg geosite_dir "$GEOSITE_DIR" \
    --arg geoip_dir "$GEOIP_DIR" --argjson urltest "$URLTEST" -f "$CONVERT" rendered.json > converted.json
  jq -c --arg mode "${MODE:-blacklist}" --slurpfile runtime <(jq -c .sections converted.json) -f "$COMPOSE" "$BUCKETS" > composed.json
  FINAL=proxy DNS_FINAL=remote CLEAR=false
  case "$MODE" in
    whitelist) FINAL=direct DNS_FINAL=local ;;
    all-proxy) CLEAR=true ;;
    all-bypass) FINAL=direct DNS_FINAL=local CLEAR=true ;;
  esac
  jq --slurpfile obs <(echo "$OBS") --slurpfile probe_inbounds <(echo '[]') --slurpfile probe_pin_rules <(echo '[]') \
    --slurpfile autoproxy_rule_sets <(echo '[]') --slurpfile autoproxy_rules <(echo '[]') \
    --argjson auth_enabled false --arg user "" --arg password "" \
    --argjson route_enabled "${ENABLED:-true}" --slurpfile route_rules <(jq -c .rules composed.json) \
    --slurpfile route_dns <(jq -c .dns composed.json) --argjson static_dns_count "$(jq .staticDnsCount composed.json)" \
    --slurpfile user_rule_sets <(jq -c .rule_sets converted.json) \
    --arg route_final "$FINAL" --arg dns_final "$DNS_FINAL" --argjson clear_dns_rules "$CLEAR" \
    --arg xray_loglevel "" --arg xray_single_proxy_tag "" --slurpfile xray_selectable <(echo '[]') \
    --argjson xray_tun_dns_runtime false --argjson host_addresses '[]' \
    -f "$FILTER" "$CONFIG" > "$OUT"
}

# --- sing-box --------------------------------------------------------------------------------
SB_OBS='[{"type":"selector","tag":"proxy","outbounds":["primary"]},{"type":"http","tag":"primary","server":"proxy.example.com","server_port":8080}]'
compose @singBoxStart@ "" "$SB_OBS" none.json
# Left out, and why: an outbound that is gone, a geosite this host does not have.
jq -e 'map(.name) == ["gone", "nogeo"] and (.[0].why | test("removed-outbound"))' <(jq -c .skipped converted.json) > /dev/null
jq -e '
  [.route.rules[] | (.rule_set[0]? // .domain_suffix[0]? // .action // (.ip_is_private | tostring))] as $order
  | def at($x): $order | index($x);
  # Runtime ads (10) and bank (50) ahead of the configuration'"'"'s rules (100), empty (250) after
  # its proxy lists (200), work (450) after the direct ones (400); disabled off nowhere.
  at("user:ads") < at("user:bank") and at("user:bank") < at("custom.example")
  and at("proxied.example") < at("user:empty") and at("user:empty") < at("blocked.example")
  and at("true") < at("user:work") and at("user:off") == null and at("user:gone") == null
  # The rule sets, each once: geodata the configuration has too is not declared twice.
  and ([.route.rule_set[].tag] | length == (unique | length))
  and ([.route.rule_set[] | select(.tag == "user:bank" or .tag == "user-dns:bank")] | length == 2)
  and any(.route.rule_set[]; .tag == "geosite-category-gov-ru")
  # Lookups follow: bank locally, ahead of the configuration'"'"'s; a block rule none.
  and ([.dns.rules[] | .rule_set[0]? // .domain_suffix[0]?] as $dns
       | ($dns | index("user-dns:bank")) < ($dns | index("custom.example"))
         and ($dns | index("user-dns:ads")) == null and ($dns | index("user-dns:work")) != null)
  and (.dns.rules[] | select(.rule_set[0]? == "user-dns:bank") | .server) == "local"
' none.json > /dev/null
@singBox@ check -c none.json
# Composed with no runtime rule, the route is the configuration's own, lookups too.
cp rendered.json full.json
echo '[]' > rendered.json
compose @singBoxStart@ "" "$SB_OBS" composed-default.json
ENABLED=false compose @singBoxStart@ "" "$SB_OBS" static.json
jq -e --slurpfile static static.json '.route == $static[0].route and .dns == $static[0].dns' composed-default.json > /dev/null
cp full.json rendered.json
for mode in whitelist all-proxy all-bypass; do
  compose @singBoxStart@ "$mode" "$SB_OBS" "$mode.json"
  @singBox@ check -c "$mode.json"
done
# all-proxy keeps no direct list, all-bypass nothing but the blocks.
jq -e '[.route.rules[].rule_set[0]?] | index("user:bank") == null and index("user:work") != null' all-proxy.json > /dev/null
jq -e '[.route.rules[].rule_set[0]?] | index("user:ads") != null and index("user:work") == null' all-bypass.json > /dev/null

# --- xray ------------------------------------------------------------------------------------
jq 'map(.ruleSets = [])' full.json > rendered.json
compose @xrayStart@ "" '[{"protocol":"freedom","tag":"primary"}]' xray.json
jq -e '
  [.routing.rules[].ruleTag] as $tags
  | ($tags | index("user:bank")) < ($tags | index("user:work"))
  and ($tags | index("user:work:ip")) == ($tags | index("user:work")) + 1
  and ($tags | index("dns-remote-bridge")) != null
' xray.json > /dev/null
XRAY_LOCATION_ASSET=@xrayAssets@ @xray@ run -test -c xray.json

# --- the inbounds' guard ---------------------------------------------------------------------
# A runtime direct rule above the configuration's gets a guard of its own, for what it matches;
# the guard proper stays before the configuration's first direct rule.
echo '{"inbounds":[],"outbounds":[],"dns":{"rules":[]},"route":{"final":"proxy","rules":[
  {"action":"sniff"},{"rule_set":["user:bank"],"outbound":"direct"},
  {"domain_suffix":["proxied.example"],"outbound":"proxy"},{"domain_suffix":["ru"],"outbound":"direct"}]}}' |
  jq --slurpfile obs <(echo '[]') --argjson auth_enabled false --arg user "" --arg password "" \
    --argjson route_enabled false --slurpfile route_rules <(echo '[]') \
    --arg route_final proxy --arg dns_final remote --argjson clear_dns_rules false \
    --slurpfile probe_inbounds <(echo '[]') --slurpfile autoproxy_rule_sets <(echo '[]') \
    --slurpfile autoproxy_rules <(echo '[]') --slurpfile probe_pin_rules <(echo '[]') \
    -f @guardFilter@ > guard.json
jq -e '
  .route.rules as $r
  | ($r | map(.type? == "logical" and .action == "resolve" and .rules[-1].rule_set == ["user:bank"]) | index(true)) as $scoped
  | ($r | map(.rule_set? == ["user:bank"]) | index(true)) as $bank
  | ($r | map(.inbound? == ["mixed-in"] and .action == "resolve") | index(true)) as $guard
  | ($r | map(.domain_suffix? == ["proxied.example"]) | index(true)) as $proxied
  | ($r | map(.domain_suffix? == ["ru"]) | index(true)) as $ru
  | $scoped < $bank and $proxied < $guard and $guard < $ru
' guard.json > /dev/null
touch "$out"
