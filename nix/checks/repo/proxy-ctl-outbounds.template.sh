proxy_ctl=@proxyCtl@

# systemd is not in the sandbox. The reload stub stands in for the start
# script, which is what actually republishes the inventory.
mkdir -p stub
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'if [ "$1" = start ] && [ "$2" = proxy-suite-outbound-reload.service ]; then'
  printf '%s\n' '  ls "$RUNTIME_OUTBOUNDS_DIR" > "$OUTBOUND_INVENTORY_FILE.spool"'
  printf '%s\n' '  jq --rawfile spool "$OUTBOUND_INVENTORY_FILE.spool" '"'"'($spool | split("\n") | map(select(endswith(".url") or endswith(".json")) | sub("\\.(url|json)$"; ""))) as $new | .tags = (.tags + $new | unique) | .sources = reduce $new[] as $t (.sources; .[$t] = "runtime")'"'"' "$OUTBOUND_INVENTORY_FILE" > "$OUTBOUND_INVENTORY_FILE.tmp"'
  printf '%s\n' '  mv "$OUTBOUND_INVENTORY_FILE.tmp" "$OUTBOUND_INVENTORY_FILE"'
  printf '%s\n' '  jq --rawfile spool "$OUTBOUND_INVENTORY_FILE.spool" '"'"'.disabled = ($spool | split("\n") | map(select(endswith(".disabled")) | sub("\\.disabled$"; ""))) | .excluded = (.excluded + .disabled | unique)'"'"' "$OUTBOUND_INVENTORY_FILE" > "$OUTBOUND_INVENTORY_FILE.tmp"'
  printf '%s\n' '  mv "$OUTBOUND_INVENTORY_FILE.tmp" "$OUTBOUND_INVENTORY_FILE"'
  printf '%s\n' 'fi'
  printf '%s\n' 'exit 0'
} > stub/systemctl
printf '#!/bin/sh\nprintf %%s "$2"\n' > stub/systemd-escape
chmod +x stub/systemctl stub/systemd-escape
export PATH="$PWD/stub:$PATH"

mkdir -p obd subd cache
printf '%s\n' '["community"]' > tags.json
jq -n '{tags:["own-vps","community-de"],
        sources:{"own-vps":"static","community-de":"sub:community"},
        pinned:"community-de", selection:"urltest",
        detours:{"community-de":"own-vps"}, excluded:["own-vps"]}' > inventory.json

run() {
  env \
    SUB_TAGS_FILE="$PWD/tags.json" \
    SUB_CACHE_DIR="$PWD/cache" \
    OUTBOUND_INVENTORY_FILE="$PWD/inventory.json" \
    RUNTIME_OUTBOUNDS_DIR="$PWD/obd" \
    RUNTIME_SUBS_DIR="$PWD/subd" \
    USER_CONTROL_GROUP="proxy-suite" \
    CLASH_API="http://127.0.0.1:1" \
    SELECTION="urltest" \
    @perAppRoutingOff@            python3 "$proxy_ctl" "$@"
}

# Listing works from the inventory alone, with no Clash API answering.
run proxy outbounds > listing
grep -q 'Selection: urltest' listing
grep -q 'Pinned:    community-de' listing
grep -q '\*community-de' listing
grep -q 'own-vps  *static' listing
# What each one chains through, and what selection leaves alone.
grep -q 'community-de  *sub:community, via own-vps$' listing
grep -q 'own-vps  *static, never picked$' listing
# The old spelling still dispatches.
run outbounds | cmp - listing

# Reserved and malformed tags are refused before anything is written.
for bad in proxy direct block "has space" "-leading"; do
  if run proxy outbounds add "$bad" http://example.com:1 2>/dev/null; then
    echo "accepted invalid tag: $bad" >&2
    exit 1
  fi
done
# Tags that already exist are refused too, declared or not.
! run proxy outbounds add own-vps http://example.com:1 2>/dev/null
! run proxy subs add community https://example.com/sub 2>/dev/null
# A URL with whitespace is refused.
! run proxy outbounds add ok-tag "http://example.com:1 x" 2>/dev/null
# Nothing above touched the spool.
[ -z "$(ls -A obd)" ]

# Removing something that was never added says so.
! run proxy outbounds rm nope 2>/dev/null

# A good add lands in the spool group-readable, not world-readable.
run proxy outbounds add spool-one http://example.com:1 | grep -q 'Added outbound: spool-one'
[ "$(cat obd/spool-one.url)" = "http://example.com:1" ]
[ "$(stat -c %a obd/spool-one.url)" = "640" ]
run proxy outbounds | grep -q 'spool-one  *runtime'
# Adding it twice is refused.
! run proxy outbounds add spool-one http://example.com:1 2>/dev/null
run proxy outbounds rm spool-one | grep -q 'Removed outbound: spool-one'
[ ! -e obd/spool-one.url ]

# --detour leaves the hop next to the entry, and only names an outbound that exists.
! run proxy outbounds add bad-hop http://example.com:1 --detour nope 2>/dev/null
[ ! -e obd/bad-hop.url ]
run proxy outbounds add chained http://example.com:1 --detour own-vps | grep -q 'Added outbound: chained'
[ "$(cat obd/chained.detour)" = own-vps ]
run proxy outbounds rm chained > /dev/null
[ ! -e obd/chained.detour ]
# A hop left behind does not chain a later entry of the same name.
echo own-vps > obd/unchained.detour
run proxy outbounds add unchained http://example.com:1 > /dev/null
[ ! -e obd/unchained.detour ]
run proxy outbounds rm unchained > /dev/null

# JSON, as `link --json` prints it, lands as <tag>.json without its own tag; stdin too.
run proxy outbounds add from-json '{"type":"trojan","tag":"x","server":"t.test","server_port":443,"password":"p"}' \
  | grep -q 'Added outbound: from-json'
[ "$(jq -r 'has("tag"), .server' obd/from-json.json | paste -sd,)" = "false,t.test" ]
printf '%s' '{"protocol":"vless","settings":{}}' | run proxy outbounds add from-stdin - | grep -q 'Added outbound: from-stdin'
! run proxy outbounds add from-json '{"type":"trojan"}' 2>/dev/null
! run proxy outbounds add bad-json '{"server":"t.test"}' 2>/dev/null
! run proxy outbounds add bad-json '{nope' 2>/dev/null
[ ! -e obd/bad-json.json ]
run proxy outbounds rm from-json | grep -q 'Removed outbound: from-json'
[ ! -e obd/from-json.json ]

# Without a tag one is made from the link; a tag after the link is a mix-up.
run proxy outbounds add 'vless://u@de.example.net:443#DE%201' > named
grep -q 'Tag: DE-1 (none given' named
grep -q 'Added outbound: DE-1' named
! run proxy outbounds add http://example.com:1 x 2>/dev/null
run proxy outbounds rm DE-1 > /dev/null

# Disabling leaves a marker the start script reads; a pin refuses it until enabled.
run proxy outbounds disable own-vps | grep -q 'Disabled: own-vps'
[ -e obd/own-vps.disabled ]
run proxy outbounds | grep -q -- '-own-vps  *static, disabled$'
! run proxy pin own-vps 2>/dev/null
run proxy outbounds enable own-vps | grep -q 'Enabled: own-vps'
[ ! -e obd/own-vps.disabled ]

# Subscriptions use the same spool machinery, verified by cache file.
printf '%s\n' '[{},{}]' > cache/extra.json
run proxy subs add extra https://example.com/sub | grep -q 'Added subscription: extra (2 proxies)'
run proxy subs list > subs
grep -q 'community .* static' subs
grep -q 'extra .* runtime' subs

# A spool entry the backend refused is reported, not silently accepted.
run proxy subs add rejected https://example.com/sub > rejected 2>&1 && exit 1
grep -q 'did not come up' rejected

# Pinning and unpinning go through their units.
run proxy pin community-de | grep -q 'Pinned: community-de'
run proxy unpin | grep -q 'Unpinned'
# Without a terminal and without a tag there is nothing to pick from.
! run proxy pin </dev/null 2>/dev/null

touch "$out"
