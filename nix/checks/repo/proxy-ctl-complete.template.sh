proxy_ctl=@proxyCtl@

printf '%s\n' '["home","work"]' > awg.json
jq -n '[{name:"torrent",route:"direct"}]' > profiles.json
jq -n '{tags:["own-vps","community-de"],sources:{"own-vps":"proxy.outbounds"}}' > inventory.json

run() {
  env AWG_PROFILES_FILE="$PWD/awg.json" \
    PER_APP_ROUTING_PROFILES_FILE="$PWD/profiles.json" \
    OUTBOUND_INVENTORY_FILE="$PWD/inventory.json" \
    python3 "$proxy_ctl" __complete "$@"
}

# Every group the help lists must complete, or the table has drifted.
python3 "$proxy_ctl" help | awk '/^  [a-z]/ { print $1 }' | sort -u > groups
run | cut -f1 > top
while read -r group; do
  grep -qx "$group" top || { echo "help lists $group, completion does not" >&2; exit 1; }
done < groups

# Piping into `grep -q` would race the script against SIGPIPE.
has() {
  local want="$1"
  shift
  run "$@" | cut -f1 > words
  grep -qx -- "$want" words
}

has outbounds proxy
has all-bypass proxy mode
has exclude zapret auto
has proxy-suite-awg-work logs
has work awg on
has add awg
has rm awg
has torrent apps run
has unpin proxy
has newnym tor
has --onion inbounds link
has community-de proxy pin

# Flags, and completion past the first of several arguments.
has --delay proxy outbounds test
has community-de proxy outbounds test own-vps
has --download proxy outbounds test own-vps --ping
has own-vps proxy auto probe example.com --via
has community-de proxy outbounds add hop https://example.com --detour
# chain takes the outbound to copy, then the hop it dials through.
has community-de proxy outbounds chain own-vps
has outbound inbounds stats --by
# Unreadable state loses the values, not the flags.
has --qr inbounds sub

# Candidates carry a description after a tab.
run proxy pin > words
grep -qx "$(printf 'own-vps\tproxy.outbounds')" words

# A shell completing must never die, however unreadable the state is.
run inbounds link > /dev/null
env AWG_PROFILES_FILE=/nonexistent python3 "$proxy_ctl" __complete awg on

# A candidate is whatever a group member named a file: never shell code to whoever completes.
mkdir -p fake
printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'ok-tag' '\$(touch pwned)' '\`touch pwned\`'" > fake/proxy-ctl
chmod +x fake/proxy-ctl
PATH="$PWD/fake:$PATH" bash -c 'source @bashCompletion@; COMP_WORDS=(proxy-ctl proxy outbounds rm ""); COMP_CWORD=4; _proxy_ctl; printf "%s\n" "${COMPREPLY[@]}"' > completed
[ ! -e pwned ] || { echo "bash completion ran a candidate" >&2; exit 1; }
grep -qx ok-tag completed
mkdir -p spool
touch 'spool/$(touch pwned).url' spool/fine.url
env RUNTIME_OUTBOUNDS_DIR="$PWD/spool" python3 "$proxy_ctl" __complete proxy outbounds rm | cut -f1 > words
! grep -q 'pwned' words || { echo "__complete offered shell code" >&2; exit 1; }

# Every shell's completion file at least parses.
bash -n @bashCompletion@
@zsh@/bin/zsh -n @zshCompletion@
HOME="$TMPDIR" @fish@/bin/fish --no-execute @fishCompletion@

touch "$out"
