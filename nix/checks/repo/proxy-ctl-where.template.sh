proxy_ctl=@proxyCtl@

mkdir -p ap zap direct
jq -n '{domains:{"spotify.com":{exit:"community-de",host:"open.spotify.com",at:0}}}' > ap/state.json
printf 'nyt.com\n' > zap/zapret-hosts-auto.txt
printf 'discord.com\n' > zap/zapret-hosts-user.txt
printf 'ok.ru\n' > zap/zapret-hosts-user-exclude.txt
# The strategy source's own sites, as root's direct-sync writes them.
printf 'youtube.com\nok.ru\n' > direct/sites.txt

run() {
  env AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$PWD/ap" \
    ZAPRET_AUTO_ENABLED=1 ZAPRET_STATE_DIR="$PWD/zap" ZAPRET_DIRECT_DIR="$PWD/direct" \
    python3 "$proxy_ctl" where "$@"
}

# Piping into `grep -q` would race the script against SIGPIPE.
verdict() {
  run "$1" > where
  grep -q -- "$2" where
}

# Both stores key on an apex, so a subdomain has to match its parent.
verdict open.spotify.com '-> proxied via community-de'
grep -q 'autoProxy .*routed via community-de' where
# What proxy-ctl cannot see has to be said out loud.
grep -q 'proxy config is not readable' where

verdict discord.com '-> direct, with the zapret bypass'
verdict nyt.com '-> direct, with the zapret bypass'
# A source's site is zapret2's from the start: neither learned nor pinned.
verdict www.youtube.com '-> direct, with the zapret bypass'
grep -q "zapret .*strategy source's list (youtube.com)" where
# Excluded is not bypassed: it must not read as a zapret2 verdict.
verdict ok.ru '-> nothing runtime matches it'
verdict example.org '-> nothing runtime matches it'

# A URL is accepted where a hostname is.
verdict https://open.spotify.com/track/x '^  domain *open.spotify.com$'

! python3 "$proxy_ctl" where 2>/dev/null

touch "$out"
