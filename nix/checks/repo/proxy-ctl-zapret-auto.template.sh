proxy_ctl=@proxyCtl@

state="$PWD/state"
mkdir -p "$state"
printf 'blocked.example\nother.example\n' > "$state/zapret-hosts-auto.txt"
: > "$state/zapret-hosts-user.txt"
: > "$state/zapret-hosts-user-exclude.txt"

run() {
  env ZAPRET_AUTO_ENABLED=1 ZAPRET_STATE_DIR="$state" python3 "$proxy_ctl" zapret auto "$@"
}

run list | grep -qx blocked.example

# exclude must also blacklist, or the host is relearned.
run exclude blocked.example > /dev/null
! grep -qx blocked.example "$state/zapret-hosts-auto.txt"
grep -qx blocked.example "$state/zapret-hosts-user-exclude.txt"

# Pinning is idempotent, so repeated runs cannot grow the list.
run add pinned.example > /dev/null
run add pinned.example > /dev/null
test "$(grep -c -x pinned.example "$state/zapret-hosts-user.txt")" = 1

# unpin and include undo add and exclude.
run unpin pinned.example > /dev/null
! grep -qx pinned.example "$state/zapret-hosts-user.txt"
run include blocked.example > /dev/null
! grep -qx blocked.example "$state/zapret-hosts-user-exclude.txt"
run add pinned.example > /dev/null

# The lists stay readable by unprivileged proxy-ctl after a rewrite.
test "$(stat -c %a "$state/zapret-hosts-user.txt")" = 644

# Forgetting a host also drops the strategy remembered for its apex.
mkdir -p "$state/circular"
printf '# key\thost\tstrategy\tts\tmode\tsni\nrkn_tcp\tyoutube.com\t3\t1\tauto\t\nrkn_tcp\tother.example\t2\t1\tauto\t\nyt_tcp\tyoutube.com\t5\t1\tauto\t\n' > "$state/circular/state.tsv"
run forget www.youtube.com > /dev/null
! grep -q 'youtube.com' "$state/circular/state.tsv"
grep -q 'other.example' "$state/circular/state.tsv"
grep -q '^# key' "$state/circular/state.tsv"

run clear > /dev/null
run list | grep -q 'No hostnames learned'
test ! -s "$state/circular/state.tsv"

# The cutoff verdict names each cut-off network's way through.
mkdir -p "$state/cutoff"
printf '1789000000\n' > "$state/cutoff/ts"
printf 'AS12389\n' > "$state/cutoff/egress"
printf '24940\n14061\n' > "$state/cutoff/asn.txt"
printf '24940\t300.ya.ru\n' > "$state/cutoff/sni.txt"
cutoff=$(env ZAPRET_CUTOFF_ENABLED=1 ZAPRET_CUTOFF_DIR="$state/cutoff" python3 "$proxy_ctl" zapret cutoff)
printf '%s\n' "$cutoff" | grep -q 'from AS12389$'
printf '%s\n' "$cutoff" | grep -qx 'Cutoff:  2 network(s)'
printf '%s\n' "$cutoff" | grep -qE '^  AS24940 +300\.ya\.ru$'
printf '%s\n' "$cutoff" | grep -qE '^  AS14061 +no name - proxy fallback$'

# Without the zapret2 engine there is nothing to inspect.
! env ZAPRET_AUTO_ENABLED=0 ZAPRET_STATE_DIR="$state" python3 "$proxy_ctl" zapret auto list

touch "$out"
