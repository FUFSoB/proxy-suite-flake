mkdir obd
export RUNTIME_DIR="$PWD" OUTBOUND_SOURCES_JSON='{}'
# No group here: `g` names members that are not running, so it blocks, with a warning.
export OUTBOUNDS_JSON='[{"tag":"x"}]'
@grouped@ 2> err
grep -q "group 'g': member 'b' is not available" err
grep -q "group 'g' has no available member" err
jq -e '.top == ["x", "g"] and .groups.g.members == ["block"]' outbounds.json > /dev/null

# With its members: they leave the top level, the group takes their place and order.
export OUTBOUNDS_JSON='[{"tag":"x"},{"tag":"a"},{"tag":"b"}]'
@grouped@
jq -e '.top == ["x", "g"] and .groups.g.members == ["b", "a"] and .groups.g.strategy == "failover"' outbounds.json > /dev/null
# A group pin, a runtime group, and a runtime priority putting it first.
mkdir group-pins
echo a > group-pins/g
echo '{"outbounds": ["x"], "strategy": "urltest"}' > obd/h.group
echo '{"h": 1}' > obd/priority.json
_proxy_suite_read_source() { cat -- "$1"; }
export -f _proxy_suite_read_source
@grouped@
jq -e '.top == ["h", "g"] and .groups.g.pinned == "a" and .groups.h.runtime and .priority.h == 1' outbounds.json > /dev/null
# The spool is group-writable: a runtime group inside itself, one that is not a group, and
# one taking a reserved name are left out, and the start goes on without them.
echo '{"outbounds": ["h3"]}' > obd/h2.group
echo '{"outbounds": ["h2"]}' > obd/h3.group
echo '{"outbounds": ["x"], "interval": {"s": 1}}' > obd/h4.group
echo '{"outbounds": ["x"]}' > obd/proxy.group
@grouped@ 2> err
grep -q "ignoring runtime group 'h2': it contains itself" err
grep -q "ignoring runtime group 'h3': it contains itself" err
grep -q "ignoring runtime group 'h4': not a valid group" err
grep -q "ignoring runtime group 'proxy': reserved or invalid name" err
jq -e '.groups | (has("h2") or has("h3") or has("h4") or has("proxy")) | not' outbounds.json > /dev/null
jq -e '.groups.h.runtime' outbounds.json > /dev/null
rm -r obd/h.group obd/h2.group obd/h3.group obd/h4.group obd/proxy.group obd/priority.json group-pins

export OUTBOUNDS_JSON='[{"tag":"a"},{"tag":"b"},{"tag":"ex"}]'

# A marker takes its outbound out of selection and drops a pin on it; stale markers do nothing.
touch obd/a.disabled obd/gone.disabled
echo a > pinned
@selection@ 2> err
grep -q "pinned outbound 'a' is disabled" err
jq -e '.pinned == "" and .disabled == ["a"] and .excluded == ["a", "ex"]' outbounds.json > /dev/null

# With nothing left to select and no pin the start fails, saying how out.
touch obd/b.disabled
! @selection@ 2> err
grep -q "outbounds enable" err
# A pin on one still enabled carries it.
echo ex > pinned
@selection@
jq -e '.pinned == "ex" and .disabled == ["a", "b"]' outbounds.json > /dev/null
touch "$out"
