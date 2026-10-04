proxy_ctl=@proxyCtl@

mkdir -p ap zap
jq -n '{domains:{"spotify.com":{exit:"community-de",host:"open.spotify.com",at:0}}}' > ap/state.json
printf 'nyt.com\n' > zap/zapret-hosts-auto.txt
printf 'discord.com\n' > zap/zapret-hosts-user.txt
printf 'ok.ru\n' > zap/zapret-hosts-user-exclude.txt

run() {
  env AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$PWD/ap" \
    ZAPRET_AUTO_ENABLED=1 ZAPRET_STATE_DIR="$PWD/zap" \
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
grep -q 'sing-box config is not readable' where

verdict discord.com '-> direct, with the zapret bypass'
verdict nyt.com '-> direct, with the zapret bypass'
# Excluded is not bypassed: it must not read as a zapret2 verdict.
verdict ok.ru '-> nothing runtime matches it'
verdict example.org '-> nothing runtime matches it'

# A URL is accepted where a hostname is.
verdict https://open.spotify.com/track/x '^  domain *open.spotify.com$'

! python3 "$proxy_ctl" where 2>/dev/null

touch "$out"
