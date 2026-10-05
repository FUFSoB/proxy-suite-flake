set -euo pipefail
# The runner as the units run it, against scratch dirs: what members queue in the spool,
# and an install from before it, whose state dir the group wrote to.
mkdir -p state spool run stub
export AUTOPROXY_STATE_DIR=$PWD/state AUTOPROXY_SPOOL_DIR=$PWD/spool PROBE_EXITS_FILE=$PWD/run/probe-exits.json
printf 'secret.example\n' > secret
# Every probe reaches its destination through exit x; each host asked for is logged.
cat > stub/proxy-ctl <<'EOF'
#!/bin/sh
for a; do host=$a; done
echo "$host" >> "$PROBED"
echo '{"verdict":"destination","exit":"x","path":"/"}'
EOF
chmod +x stub/proxy-ctl
export PROBED=$PWD/probed

# --- the old layout: queues, and what a member could leave, in a 0771 state dir ---
echo '{"domains":{"gone.example":{"verdict":"destination","exit":"x","host":"gone.example","at":1}},
  "hosts":{},"exits":{"x":{"at":"a[$(touch pwned)]"}},"backlog":{}}' > state/state.json
printf 'old.example\n' > state/requests
printf 'forget gone.example\n' > state/edits.taking
# Root opens lock for writing, appends to samples and installs into rules/ by name.
ln -s "$PWD/secret" state/lock
ln -s "$PWD/secret" state/samples
ln -s "$PWD/run" state/rules
mkfifo state/fifo
chmod 0771 state

# No probe listeners yet: only the edits, which the old queue held.
timeout 60 @runner@ --requests-only > log
grep -q 'no probe listeners' log
test "$(stat -c %a state)" = 751
test -z "$(find state -mindepth 1 \( -type l -o -type p \))"
test "$(cat secret)" = secret.example
jq -e '.domains == {}' state/state.json > /dev/null
# The old requests wait in the spool, edits are applied and gone.
grep -qx old.example spool/requests.migrated.*
test -z "$(find spool -name 'edits*')"
test ! -e state/requests && test ! -e state/edits.taking

# --- what members queue now, and what one may leave in the spool besides ---
printf '[{"i":0,"tag":"direct","port":1,"path":"%s/state/rules/rs-0.json"},
  {"i":1,"tag":"x","port":2,"path":"%s/state/rules/rs-1.json"}]\n' "$PWD" "$PWD" > run/probe-exits.json
printf 'new.example\n' > spool/requests.2.1
ln -s "$PWD/secret" spool/requests.3.1
mkfifo spool/requests.4.1
mkdir spool/requests.5.1
printf 'half.example\n' > spool/.requests.6.1.tmp
timeout 60 @runner@ --requests-only > log

# Never through the link, never stuck on the FIFO, never the file still being written.
sort -u probed > probed.sorted
printf 'new.example\nold.example\n' | cmp - probed.sorted
test "$(cat secret)" = secret.example
# Only that one is left; what the run took is gone, whatever it was.
test "$(ls -A spool)" = .requests.6.1.tmp
jq -e '.domains | keys == ["new.example", "old.example"]' state/state.json > /dev/null
jq -e '.rules[0].domain_suffix | sort == ["new.example", "old.example"]' state/rules/rs-1.json > /dev/null
test "$(stat -c %a state/state.json)" = 640
# The exit's "at" from the old state ran nothing.
test ! -e pwned
touch "$out"
