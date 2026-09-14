{
  pkgs,
  rg,
  generatedOptionsDoc,
  generatedReadmeDoc,
  readmeDocSource,
  trayModuleSource,
  tgWsProxyModuleSource,
  controlModuleSource,
}:

{
  no-secrets = pkgs.runCommand "proxy-suite-no-secrets-check" { } ''
    repo_root=${../../.}
    if ${rg} --pcre2 -n -I -H -S \
      -e '-----BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----' \
      -e 'ghp_[A-Za-z0-9]{36}' \
      -e 'github_pat_[A-Za-z0-9_]{20,}' \
      -e 'glpat-[A-Za-z0-9_-]{20,}' \
      -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'AIza[0-9A-Za-z_-]{35}' \
      -e 'sk-(proj-)?[A-Za-z0-9_-]{20,}' \
      "$repo_root"; then
      echo "secret-like content detected in source tree" >&2
      exit 1
    fi
    touch "$out"
  '';

  options-doc =
    pkgs.runCommand "proxy-suite-options-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; }
      ''
        diff -ru ${../../docs/options} ${generatedOptionsDoc}
        touch "$out"
      '';

  readme-doc =
    pkgs.runCommand "proxy-suite-readme-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; }
      ''
        diff -u ${../../README.md} ${generatedReadmeDoc}
        touch "$out"
      '';

  proxy-ctl-subscription-list =
    pkgs.runCommand "proxy-suite-proxy-ctl-subscription-list-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gawk
          pkgs.jq
        ];
      }
      ''
        proxy_ctl="$TMPDIR/proxy-ctl"
        cat ${../../pkgs/proxy-ctl-lib.sh} ${../../pkgs/proxy-ctl.sh} > "$proxy_ctl"
        chmod +x "$proxy_ctl"

        mkdir -p cache
        printf '%s\n' '["plain","hybrid","bad"]' > tags.json
        printf '%s\n' '[{},{}]' > cache/plain.json
        printf '%s\n' '{"singBox":[{},{}],"xray":[{}]}' > cache/hybrid.json
        printf '%s\n' '{"singBox":[{}]}' > cache/bad.json

        env \
          SUB_TAGS_FILE="$PWD/tags.json" \
          SUB_CACHE_DIR="$PWD/cache" \
          CLASH_API="http://127.0.0.1:9090" \
          SELECTION="first" \
          PER_APP_ROUTING_ENABLED="0" \
          PER_APP_ROUTING_PROXYCHAINS_ENABLED="0" \
          PER_APP_ROUTING_TUN_ENABLED="0" \
          PER_APP_ROUTING_TPROXY_ENABLED="0" \
          PER_APP_ROUTING_ZAPRET_ENABLED="0" \
          PER_APP_ROUTING_PROFILES_FILE="$PWD/profiles.json" \
          PROXYCHAINS_CONFIG="$PWD/proxychains.conf" \
          PROXYCHAINS_QUIET_ARG="" \
          ROUTE_MODE_STATE_FILE="$PWD/route-mode" \
          DEFAULT_ROUTE_MODE="blacklist" \
          bash "$proxy_ctl" proxy subs list > output
        # The old spelling still dispatches.
        env SUB_TAGS_FILE="$PWD/tags.json" SUB_CACHE_DIR="$PWD/cache" \
          bash "$proxy_ctl" subscription list | cmp - output

        awk '$1 == "plain" { found = 1; if ($NF != "2") exit 1 } END { exit found ? 0 : 1 }' output
        awk '$1 == "hybrid" { found = 1; if ($NF != "3") exit 1 } END { exit found ? 0 : 1 }' output
        awk '$1 == "bad" { found = 1; if ($NF != "?") exit 1 } END { exit found ? 0 : 1 }' output

        touch "$out"
      '';

  proxy-ctl-outbounds =
    pkgs.runCommand "proxy-suite-proxy-ctl-outbounds-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        proxy_ctl="$TMPDIR/proxy-ctl"
        cat ${../../pkgs/proxy-ctl-lib.sh} ${../../pkgs/proxy-ctl.sh} > "$proxy_ctl"
        chmod +x "$proxy_ctl"

        # systemd is not in the sandbox. The reload stub stands in for the start
        # script, which is what actually republishes the inventory.
        mkdir -p stub
        {
          printf '%s\n' '#!/bin/sh'
          printf '%s\n' 'if [ "$1" = start ] && [ "$2" = proxy-suite-outbound-reload.service ]; then'
          printf '%s\n' '  ls "$RUNTIME_OUTBOUNDS_DIR" > "$OUTBOUND_INVENTORY_FILE.spool"'
          printf '%s\n' '  jq --rawfile spool "$OUTBOUND_INVENTORY_FILE.spool" '"'"'($spool | split("\n") | map(select(endswith(".url")) | rtrimstr(".url"))) as $new | .tags = (.tags + $new | unique) | .sources = reduce $new[] as $t (.sources; .[$t] = "runtime")'"'"' "$OUTBOUND_INVENTORY_FILE" > "$OUTBOUND_INVENTORY_FILE.tmp"'
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
                pinned:"community-de", selection:"urltest"}' > inventory.json

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
            PER_APP_ROUTING_ENABLED="0" \
            PER_APP_ROUTING_PROXYCHAINS_ENABLED="0" \
            PER_APP_ROUTING_TUN_ENABLED="0" \
            PER_APP_ROUTING_TPROXY_ENABLED="0" \
            PER_APP_ROUTING_ZAPRET_ENABLED="0" \
            PER_APP_ROUTING_PROFILES_FILE="$PWD/profiles.json" \
            PROXYCHAINS_CONFIG="$PWD/proxychains.conf" \
            PROXYCHAINS_QUIET_ARG="" \
            ROUTE_MODE_STATE_FILE="$PWD/route-mode" \
            DEFAULT_ROUTE_MODE="blacklist" \
            bash "$proxy_ctl" "$@"
        }

        # Listing works from the inventory alone, with no Clash API answering.
        run proxy outbounds > listing
        grep -q 'Selection: urltest' listing
        grep -q 'Pinned:    community-de' listing
        grep -q '\*community-de' listing
        grep -q 'own-vps  *static' listing
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

        # Subscriptions use the same spool machinery, verified by cache file.
        printf '%s\n' '[{},{}]' > cache/extra.json
        run proxy subs add extra https://example.com/sub | grep -q 'Added subscription: extra (2 proxies)'
        run proxy subs list > subs
        grep -q 'community .* static' subs
        grep -q 'extra .* runtime' subs

        # A spool entry the backend refused is reported, not silently accepted.
        run proxy subs add rejected https://example.com/sub > rejected 2>&1 && exit 1
        grep -q 'did not come up' rejected

        # Pinning goes through the unit, including "auto".
        run proxy select community-de | grep -q 'Pinned: community-de'
        run proxy select auto | grep -q 'Selecting automatically again'
        # Without a terminal and without a tag there is nothing to pick from.
        ! run proxy select </dev/null 2>/dev/null

        touch "$out"
      '';

  proxy-ctl-zapret-auto =
    pkgs.runCommand "proxy-suite-proxy-ctl-zapret-auto-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
        ];
      }
      ''
        proxy_ctl="$TMPDIR/proxy-ctl"
        cat ${../../pkgs/proxy-ctl-lib.sh} ${../../pkgs/proxy-ctl.sh} > "$proxy_ctl"

        state="$PWD/state"
        mkdir -p "$state"
        printf 'blocked.example\nother.example\n' > "$state/zapret-hosts-auto.txt"
        : > "$state/zapret-hosts-user.txt"
        : > "$state/zapret-hosts-user-exclude.txt"

        run() {
          env ZAPRET_AUTO_ENABLED=1 ZAPRET_STATE_DIR="$state" bash "$proxy_ctl" zapret auto "$@"
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
        cutoff=$(env ZAPRET_CUTOFF_ENABLED=1 ZAPRET_STATE_DIR="$state" bash "$proxy_ctl" zapret cutoff)
        printf '%s\n' "$cutoff" | grep -q 'from AS12389$'
        printf '%s\n' "$cutoff" | grep -qx 'Cutoff:  2 network(s)'
        printf '%s\n' "$cutoff" | grep -qE '^  AS24940 +300\.ya\.ru$'
        printf '%s\n' "$cutoff" | grep -qE '^  AS14061 +no name - proxy fallback$'

        # Without the zapret2 engine there is nothing to inspect.
        ! env ZAPRET_AUTO_ENABLED=0 ZAPRET_STATE_DIR="$state" bash "$proxy_ctl" zapret auto list

        touch "$out"
      '';

  proxy-ctl-complete =
    pkgs.runCommand "proxy-suite-proxy-ctl-complete-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        proxy_ctl="$TMPDIR/proxy-ctl"
        cat ${../../pkgs/proxy-ctl-lib.sh} ${../../pkgs/proxy-ctl.sh} > "$proxy_ctl"

        printf '%s\n' '["home","work"]' > awg.json
        jq -n '[{name:"torrent",route:"direct"}]' > profiles.json
        jq -n '{tags:["own-vps","community-de"]}' > inventory.json

        run() {
          env AWG_PROFILES_FILE="$PWD/awg.json" \
            PER_APP_ROUTING_PROFILES_FILE="$PWD/profiles.json" \
            OUTBOUND_INVENTORY_FILE="$PWD/inventory.json" \
            bash "$proxy_ctl" __complete "$@"
        }

        # Every group the help lists must complete, or the table has drifted.
        bash "$proxy_ctl" help | awk '/^  [a-z]/ { print $1 }' | sort -u > groups
        run > top
        while read -r group; do
          grep -qx "$group" top || { echo "help lists $group, completion does not" >&2; exit 1; }
        done < groups

        # Piping into `grep -q` would race the script against SIGPIPE.
        has() {
          local want="$1"
          shift
          run "$@" > words
          grep -qx "$want" words
        }

        has outbounds proxy
        has all-bypass proxy mode
        has exclude zapret auto
        has proxy-suite-awg-work logs
        has work awg on
        has torrent apps run
        has auto proxy select
        has community-de proxy select

        # A shell completing must never die, however unreadable the state is.
        run inbounds link | cmp - /dev/null
        env AWG_PROFILES_FILE=/nonexistent bash "$proxy_ctl" __complete awg on

        touch "$out"
      '';

  proxy-ctl-where =
    pkgs.runCommand "proxy-suite-proxy-ctl-where-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        proxy_ctl="$TMPDIR/proxy-ctl"
        cat ${../../pkgs/proxy-ctl-lib.sh} ${../../pkgs/proxy-ctl.sh} > "$proxy_ctl"

        mkdir -p ap zap
        jq -n '{domains:{"spotify.com":{exit:"community-de",host:"open.spotify.com",at:0}}}' > ap/state.json
        printf 'nyt.com\n' > zap/zapret-hosts-auto.txt
        printf 'discord.com\n' > zap/zapret-hosts-user.txt
        printf 'ok.ru\n' > zap/zapret-hosts-user-exclude.txt

        run() {
          env AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$PWD/ap" \
            ZAPRET_AUTO_ENABLED=1 ZAPRET_STATE_DIR="$PWD/zap" \
            bash "$proxy_ctl" where "$@"
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
        grep -q 'proxy.routing.rules are not visible' where

        verdict discord.com '-> direct, with the zapret2 bypass'
        verdict nyt.com '-> direct, with the zapret2 bypass'
        # Excluded is not bypassed: it must not read as a zapret2 verdict.
        verdict ok.ru '-> nothing runtime matches it'
        verdict example.org '-> nothing runtime matches it'

        # A URL is accepted where a hostname is.
        verdict https://open.spotify.com/track/x '^  domain *open.spotify.com$'

        ! bash "$proxy_ctl" where 2>/dev/null

        touch "$out"
      '';

  # The verdict table, fed tuples measured on a real censored network.
  proxy-ctl-proxy-probe =
    pkgs.runCommand "proxy-suite-proxy-ctl-proxy-probe-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        cat > "$TMPDIR/test.sh" <<'EOF'
        set -euo pipefail
        . ${../../pkgs/proxy-ctl-lib.sh}

        expect() {
          local want="$1" direct="$2" via="$3" got
          got="$(_probe_verdict "$direct" "$via")"
          if [ "$got" != "$want" ]; then
            echo "FAIL: expected $want, got $got" >&2
            echo "  direct=$direct" >&2
            echo "  proxy =$via" >&2
            exit 1
          fi
        }

        # Origin refuses direct, accepts the proxy: chatgpt.com/robots.txt.
        expect destination '0|0.146175|403|6633|' '0|0.230116|200|4302|'

        # The same through a redirect: claude.ai/robots.txt.
        expect destination \
          '0|0.141625|302|143|https://claude.com/app-unavailable-in-region' \
          '0|0.181276|200|281|'

        # TLS never completed: censorship, zapret's job.
        expect censor '35|0.000000|000|0|' '0|0.119348|200|6258|'

        # Handshake, then silence: the post-handshake throttle.
        expect censor '0|0.125029|000|0|' '0|0.143772|200|32881|'

        # Direct works. Nothing to do, whoever else also works.
        expect ok '0|0.099546|200|2678|' '0|0.146822|200|2678|'

        # robots.txt legitimately absent is not a failure.
        expect ok '0|0.161330|404|559|' '0|0.214667|404|559|'

        # An ordinary redirect must not read as a block.
        expect ok \
          '0|0.10|301|0|https://www.example.com/robots.txt' \
          '0|0.20|301|0|https://www.example.com/robots.txt'

        # Refused everywhere: not an egress problem.
        expect both-fail '0|0.10|403|100|' '0|0.20|403|100|'

        # Nothing reaches it at all - a dead name, not a blocked one.
        expect unreachable '6|0.000000|000|0|' '35|0.000000|000|0|'

        # --- redirect chains ---
        # spotify.com: the block is four same-site hops in.
        curl() {
          local url
          for url; do :; done
          echo x >> "$TMPDIR/curl-calls"
          case "$url" in
            https://spotify.test/) printf '0|0.1|301|0|https://www.spotify.test/' ;;
            https://www.spotify.test/) printf '0|0.1|301|0|https://open.spotify.test/' ;;
            https://open.spotify.test/) printf '0|0.1|302|93|https://accounts.spotify.test/login' ;;
            https://accounts.spotify.test/login)
              printf '0|0.1|301|0|https://www.spotify.test/int/why-not-available/' ;;
            https://redir.test/) printf '0|0.1|301|0|https://elsewhere.example/' ;;
            https://loop.test/) printf '0|0.1|301|0|https://loop.test/' ;;
            *) printf '0|0.1|200|10|' ;;
          esac
        }
        test "$(_probe_exit_verdict "$(_probe_fetch spotify.test / --noproxy '*')")" = blocked
        # Leaving the site ends the walk.
        test "$(_probe_exit_verdict "$(_probe_fetch redir.test / --noproxy '*')")" = ok
        # A redirect loop inside the site still stops.
        : > "$TMPDIR/curl-calls"
        _probe_fetch loop.test / --noproxy '*' > /dev/null
        test "$(wc -l < "$TMPDIR/curl-calls")" -le 6
        unset -f curl

        # --- which path decides: the apex, robots.txt only breaks ties ---
        _svc_active() { return 0; }
        # No listener index: only this host and the local proxy.
        PROBE_EXITS_FILE=/nonexistent

        # A curl that cannot start is an error, not a dead site.
        ! (PROBE_CURL=/nonexistent cmd_proxy_probe --json x.test) 2> "$TMPDIR/curl-err"
        grep -q 'Cannot run /nonexistent' "$TMPDIR/curl-err"

        probe_with() {
          # $1 apex-direct $2 apex-proxy $3 robots-direct $4 robots-proxy
          _probe_fetch() {
            case "$2" in
              /) [ "$3" = --noproxy ] && printf '%s' "$APEX_DIRECT" || printf '%s' "$APEX_PROXY" ;;
              *) [ "$3" = --noproxy ] && printf '%s' "$ROBOTS_DIRECT" || printf '%s' "$ROBOTS_PROXY" ;;
            esac
          }
          APEX_DIRECT="$1" APEX_PROXY="$2" ROBOTS_DIRECT="$3" ROBOTS_PROXY="$4" \
            cmd_proxy_probe --json example.test
        }

        # last.fm: apex geo-blocked, robots.txt served everywhere.
        out="$(probe_with '0|0.11|403|424|' '0|0.17|200|59809|' '0|0.11|200|400|' '0|0.17|200|400|')"
        grep -q '"verdict":"destination"' <<<"$out"
        grep -q '"url":"https://example.test/"' <<<"$out"

        # chatgpt.com: apex 403 everywhere, robots.txt separates.
        out="$(probe_with '0|0.14|403|6633|' '0|0.23|403|8442|' '0|0.14|403|6633|' '0|0.23|200|4302|')"
        grep -q '"verdict":"destination"' <<<"$out"
        grep -q '"url":"https://example.test/robots.txt"' <<<"$out"

        # A working apex is never second-guessed by the fallback path.
        # set -e: proxy-ctl runs under it, and $() does not inherit it.
        out="$(set -e; probe_with '0|0.10|200|500|' '0|0.20|200|500|' '0|0.10|403|10|' '0|0.20|200|10|')"
        grep -q '"verdict":"ok"' <<<"$out"

        # --- walking more than two exits ---
        # Direct and the first proxy share a WAF; only the third exit gets through.
        printf '%s' '[{"i":0,"tag":"direct","port":18540},
          {"i":1,"tag":"fi","port":18541},{"i":2,"tag":"de","port":18542}]' \
          > "$TMPDIR/exits.json"
        PROBE_EXITS_FILE="$TMPDIR/exits.json"
        _probe_fetch() {
          # every exit, direct included, goes through its pinned listener
          case "$4" in
            *:18540 | *:18541) printf '0|0.10|403|919|' ;;
            *:18542) printf '0|0.10|200|500|' ;;
          esac
        }
        out="$(cmd_proxy_probe --json sekai.test)"
        jq -e '.verdict == "destination" and .exit == "de"' <<<"$out" > /dev/null

        # --keep-going tries every exit but keeps the first that worked.
        out="$(cmd_proxy_probe --json --keep-going --exits de,fi sekai.test)"
        jq -e '.exit == "de" and [.exits[].tag] == ["direct", "de", "fi", "direct", "de", "fi"]' \
          <<<"$out" > /dev/null

        # --exits restricts and orders the walk; direct is always tried first.
        out="$(cmd_proxy_probe --json --exits de sekai.test)"
        jq -e '[.exits[].tag] == ["direct", "de"]' <<<"$out" > /dev/null

        # An empty list probes direct only (every exit shares one network).
        out="$(cmd_proxy_probe --json --exits "" sekai.test)"
        jq -e '([.exits[].tag] | unique) == ["direct"] and .exit == null' <<<"$out" > /dev/null

        # --via: can this exit carry what direct reaches?
        out="$(cmd_proxy_probe --json --via de sekai.test)"
        jq -e '.verdict == "ok" and ([.exits[].tag] | unique) == ["de", "direct"]' <<<"$out" > /dev/null
        out="$(cmd_proxy_probe --json --via fi sekai.test)"
        jq -e '.verdict == "blocked"' <<<"$out" > /dev/null
        ! (cmd_proxy_probe --json --via nowhere sekai.test) 2> /dev/null
        # A given path is probed as is, for that probe only.
        out="$(cmd_proxy_probe --json --via de sekai.test/robots.txt)"
        jq -e '.url == "https://sekai.test/robots.txt" and ([.exits[].path] | unique) == ["/robots.txt"]' \
          <<<"$out" > /dev/null
        out="$(cmd_proxy_probe --json --via fi sekai.test)"
        jq -e '([.exits[].path] | unique) == ["/", "/robots.txt"]' <<<"$out" > /dev/null

        # Refused a front page direct gets: not a stand-in (www.reddit.com).
        _probe_fetch() {
          case "$4:$2" in
            *:18541:/) printf '0|0.10|403|190240|' ;;
            *) printf '0|0.10|200|500|' ;;
          esac
        }
        out="$(cmd_proxy_probe --json --via fi geo.test)"
        jq -e '.verdict == "blocked"' <<<"$out" > /dev/null
        # i.pximg.net: the front page is 400 everywhere, so robots.txt decides.
        _probe_fetch() {
          case "$2" in
            /) printf '0|0.10|400|0|' ;;
            *) printf '0|0.10|200|43|' ;;
          esac
        }
        out="$(cmd_proxy_probe --json --via fi cdn.test)"
        jq -e '.verdict == "ok"' <<<"$out" > /dev/null

        # --- proxy-ctl proxy auto learn ---
        learn_dir="$TMPDIR/learn"
        mkdir -p "$learn_dir"
        systemctl() {
          # stands in for the requests-only run
          printf '%s' '{"domains":{"last.fm":{"verdict":"destination","exit":"primary","host":"www.last.fm"}},
            "hosts":{"www.last.fm":{"domain":"last.fm","verdict":"destination","exit":"primary"}}}' \
            > "$learn_dir/state.json"
        }
        ! (AUTOPROXY_ENABLED=0 cmd_proxy_learn www.last.fm) 2> /dev/null
        # It lands in a root-owned file and then in a URL: hostnames only.
        ! (AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$learn_dir" cmd_proxy_learn 'x;rm -rf /') 2> /dev/null
        ! (AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$learn_dir" cmd_proxy_learn '-evil.test/path') 2> /dev/null
        out="$(AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$learn_dir" cmd_proxy_learn www.last.fm)"
        test "$(cat "$learn_dir/requests")" = www.last.fm
        grep -q 'last.fm: destination - routed via primary' <<<"$out"

        # A verdict that routes nothing is kept for its host and reported.
        systemctl() {
          printf '%s' '{"domains":{},
            "hosts":{"api.example.test":{"domain":"example.test","verdict":"ok","exit":null}}}' \
            > "$learn_dir/state.json"
        }
        out="$(AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$learn_dir" cmd_proxy_learn api.example.test)"
        grep -q 'api.example.test: ok - nothing to route' <<<"$out"

        # A failed run is reported in plain words, and the request is not lost.
        systemctl() { return 1; }
        : > "$learn_dir/requests"
        ! (AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$learn_dir" cmd_proxy_learn www.last.fm) 2> "$TMPDIR/learn-err"
        grep -q 'still queued' "$TMPDIR/learn-err"
        grep -qx www.last.fm "$learn_dir/requests"

        # --- queue and learned ----------------------------------------------
        systemctl() { return 0; }
        printf '%s' '{"domains":{"spotify.com":{"verdict":"destination","exit":"primary","host":"www.spotify.com","at":0}},
          "hosts":{"www.spotify.com":{"domain":"spotify.com","verdict":"destination","exit":"primary"},
                   "gew1-spclient.spotify.com":{"domain":"spotify.com","verdict":"ok","exit":null}},
          "backlog":{"a.example":{"domain":"example","hits":2},"b.example":{"domain":"example","hits":9}}}' \
          > "$learn_dir/state.json"
        q="$(AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$learn_dir" cmd_proxy_queue)"
        grep -qx '  www.last.fm' <<<"$q"
        # Most-dialled first.
        test "$(grep -oE '[ab]\.example' <<<"$q" | head -n 1)" = b.example
        l="$(AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$learn_dir" cmd_proxy_learned)"
        grep -q 'spotify.com .*-> primary' <<<"$l"
        grep -q 'ok=1' <<<"$l"
        # An unreadable state directory asks for sudo.
        chmod 000 "$learn_dir"
        ! (AUTOPROXY_ENABLED=1 AUTOPROXY_STATE_DIR="$learn_dir" cmd_proxy_queue) 2> "$TMPDIR/q-err"
        chmod 755 "$learn_dir"
        grep -q 'enable userControl, or run with sudo' "$TMPDIR/q-err"
        EOF
        bash "$TMPDIR/test.sh"
        touch "$out"
      '';

  # autoProxy slowness routing: sampler and judge.
  autoproxy-slowness =
    pkgs.runCommand "proxy-suite-autoproxy-slowness-check"
      { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        sample=${../../modules/proxy-suite/autoproxy-slow-sample.jq}
        judge=${../../modules/proxy-suite/autoproxy-slow-judge.jq}

        # A steady crawl, a burst, probe traffic, and a tiny flow.
        res="$(jq -n -c '[range(0; 11) as $t | {connections: [
            {id: "a", metadata: {host: "i.pximg.net", type: "mixed/mixed-in"}, chains: ["direct"], download: ($t * 50000)},
            {id: "b", metadata: {host: "audio.example", type: "mixed/mixed-in"}, chains: ["direct"], download: (if $t >= 5 then 2000000 else 0 end)},
            {id: "c", metadata: {host: "probe.example", type: "mixed/probe-in-0"}, chains: ["direct"], download: ($t * 50000)},
            {id: "d", metadata: {host: "tiny.example", type: "mixed/mixed-in"}, chains: ["direct"], download: ($t * 1000)},
            {id: "e", metadata: {host: "far.example", type: "mixed/mixed-in"}, chains: ["primary", "proxy"], download: ($t * 50000)}
          ]}][]' | jq -s -r --argjson min 307200 --argjson below 153600 -f "$sample")"
        printf '%s\n' "$res"
        test "$(wc -l <<<"$res")" = 3
        grep -qx "$(printf 'i.pximg.net\tdirect\tslow\t50000')" <<<"$res"
        grep -qx "$(printf 'audio.example\tdirect\tfast\t2000000')" <<<"$res"
        # chains[0] is the exit that carried it, not the selector.
        grep -qx "$(printf 'far.example\tprimary\tslow\t50000')" <<<"$res"

        j() {
          jq -c --argjson o "$1" --argjson now 1000 --argjson ttl 100 --argjson hits 3 -f "$judge" <<<"$2"
        }
        slow='[{"d":"pximg.net","h":"i.pximg.net","exit":"direct","slow":true,"peak":50000}]'
        onExitSlow='[{"d":"pximg.net","h":"i.pximg.net","exit":"primary","slow":true,"peak":1}]'
        onExitFast='[{"d":"pximg.net","h":"i.pximg.net","exit":"primary","slow":false,"peak":900000}]'
        s='{"domains":{},"hosts":{"x.twimg.com":{"verdict":"censor"}},"exits":{},"backlog":{}}'

        # Three crawls within a day make the domain owed an exit; two do not.
        s="$(j "$slow" "$s")"; s="$(j "$slow" "$s")"
        jq -e '.slowWant == {}' <<<"$s" > /dev/null
        s="$(j "$slow" "$s")"
        jq -e '.slowWant["pximg.net"] == {host: "i.pximg.net", tried: []}' <<<"$s" > /dev/null

        # Left to zapret: never moved, however slow.
        z='[{"d":"twimg.com","h":"x.twimg.com","exit":"direct","slow":true,"peak":1}]'
        t="$(j "$z" "$s")"; t="$(j "$z" "$t")"; t="$(j "$z" "$t")"
        jq -e '.slowWant["twimg.com"] == null' <<<"$t" > /dev/null

        # Once routed -- the prober picks the exit -- judged on that exit alone.
        r='{"domains":{"pximg.net":{"verdict":"slow","exit":"primary","host":"i.pximg.net","at":0,"tried":["primary"]}},
          "hosts":{},"exits":{},"backlog":{}}'
        # Fast there: kept, and a strike against it forgotten.
        k="$(j "$onExitSlow" "$r")"; k="$(j "$onExitFast" "$k")"
        jq -e '.domains["pximg.net"] | .bad == 0 and .at == 1000' <<<"$k" > /dev/null
        # Crawling there too, twice: owed the next exit, the ones tried remembered.
        u="$(j "$onExitSlow" "$r")"; u="$(j "$onExitSlow" "$u")"
        jq -e '.domains["pximg.net"] == null and .slowWant["pximg.net"].tried == ["primary"]' <<<"$u" > /dev/null

        # Every exit failed it: left direct until slowSkip expires, however slow.
        w='{"domains":{},"hosts":{},"exits":{},"backlog":{},"slowSkip":{"pximg.net":1100}}'
        w="$(j "$slow" "$w")"; w="$(j "$slow" "$w")"; w="$(j "$slow" "$w")"
        jq -e '.slowWant == {} and .slowSkip["pximg.net"] == 1100' <<<"$w" > /dev/null

        touch "$out"
      '';

  # Per-user inbound traffic: collection and `proxy-ctl inbounds stats`.
  inbound-stats =
    pkgs.runCommand "proxy-suite-inbound-stats-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        add=${../../modules/proxy-suite/inbound-stats-add.jq}
        now=1789135690 # 2026-09-11
        a() { jq -c --argjson q "$1" --arg day 2026-09-11 --argjson now "$now" -f "$add" <<<"$2"; }

        # XRay gives values as strings and leaves a zero counter without one.
        r='{"stat":[{"name":"user>>>fufsob>>>traffic>>>downlink","value":"3000000"},
          {"name":"user>>>fufsob>>>traffic>>>uplink","value":"2000"},
          {"name":"user>>>phone>>>traffic>>>uplink"}]}'
        s="$(a "$r" '{}')"
        s="$(a "$r" "$s")"
        jq -e '.days["2026-09-11"].fufsob == {down: 6000000, up: 4000}
          and .days["2026-09-11"].phone.up == 0 and .at == 1789135690' <<<"$s" > /dev/null
        # Nothing counted since the last reading: nothing changes.
        jq -e --argjson s "$s" '.days == $s.days' <<<"$(a '{}' "$s")" > /dev/null
        # Days more than a year old are let go.
        old="$(jq -c '.days["2024-01-01"] = {fufsob: {up: 1}}' <<<"$s")"
        jq -e '.days["2024-01-01"] == null' <<<"$(a '{}' "$old")" > /dev/null

        jq -c '.days["2026-09-10"] = {fufsob: {down: 1073741824, up: 1048576}}' <<<"$s" > "$TMPDIR/stats.json"
        cat > "$TMPDIR/test.sh" <<'EOF'
        set -euo pipefail
        . ${../../pkgs/proxy-ctl-lib.sh}
        id() { echo 1000; }
        date() { echo 2026-09-10; }
        export INBOUNDS_STATS_FILE="$TMPDIR/stats.json"
        out="$(_inbound_stats 2)"
        printf '%s\n' "$out"
        # Newest day first, sizes readable, then totals over the period.
        test "$(grep -oE '^  2026-09-1[01]' <<<"$out" | head -n 1)" = "  2026-09-11"
        grep -qE '^  2026-09-11 +fufsob +5\.7 MiB +4 KiB$' <<<"$out"
        grep -qE '^  2026-09-11 +phone +0 B +0 B$' <<<"$out"
        grep -qE '^  2026-09-10 +fufsob +1\.0 GiB +1\.0 MiB$' <<<"$out"
        grep -qE '^  fufsob +1\.0 GiB +1\.0 MiB$' <<<"$out"
        ! (_inbound_stats 0) 2> /dev/null
        # Nothing collected yet says so, rather than printing an empty table.
        ! (INBOUNDS_STATS_FILE="$TMPDIR/none.json" _inbound_stats 7) 2> "$TMPDIR/err"
        grep -q 'No traffic recorded yet' "$TMPDIR/err"

        # --- proxy-ctl inbounds sub -----------------------------------------
        printf '%s' '[{"user":"fufsob","token":"aaa"},{"user":"teri","token":"bbb"}]' > "$TMPDIR/subs.json"
        export INBOUNDS_SUBS_FILE="$TMPDIR/subs.json"
        test "$(INBOUNDS_SUB_BASE_URL=https://vpn.example/sub/ _inbound_subscriptions teri)" = https://vpn.example/sub/bbb
        # Without a user: names only, never a token.
        out="$(INBOUNDS_SUB_BASE_URL=https://vpn.example/sub _inbound_subscriptions 2> /dev/null)"
        test "$(wc -l <<<"$out")" = 2
        ! grep -qE 'aaa|bbb' <<<"$out"
        ! (_inbound_subscriptions nobody) 2> /dev/null
        # Without a base URL: the file path, and no QR code.
        test "$(INBOUNDS_SUB_BASE_URL= _inbound_subscriptions fufsob 2> /dev/null)" = "$TMPDIR/subs/aaa"
        ! (INBOUNDS_SUB_BASE_URL= _inbound_subscriptions fufsob --qr) 2> /dev/null
        EOF
        bash "$TMPDIR/test.sh"
        touch "$out"
      '';

  proxy-ctl-amneziawg =
    pkgs.runCommand "proxy-suite-proxy-ctl-amneziawg-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        proxy_ctl="$TMPDIR/proxy-ctl"
        cat ${../../pkgs/proxy-ctl-lib.sh} ${../../pkgs/proxy-ctl.sh} > "$proxy_ctl"
        chmod +x "$proxy_ctl"

        mkdir -p bin
        cat > bin/systemctl <<'SH'
        #!${pkgs.bash}/bin/bash
        case "$1" in
          cat) exit 0 ;;
          is-active)
            if [ "''${3:-''${2:-}}" = "proxy-suite-awg-home" ] || [ "''${2:-}" = "proxy-suite-awg-home" ]; then
              if [ "''${2:-}" != "--quiet" ]; then
                echo active
              fi
              exit 0
            fi
            if [ "''${2:-}" != "--quiet" ]; then
              echo inactive
            fi
            exit 3
            ;;
          start|stop|restart)
            printf '%s %s\n' "$1" "$2" >> "$SYSTEMCTL_LOG"
            ;;
        esac
        SH
        chmod +x bin/systemctl

        printf '%s\n' '["home","work"]' > awg-profiles.json
        export PATH="$PWD/bin:$PATH"
        export SYSTEMCTL_LOG="$PWD/systemctl.log"
        export AWG_PROFILES_FILE="$PWD/awg-profiles.json"

        bash "$proxy_ctl" awg list > list-output
        grep -q 'home.*active' list-output
        grep -q 'work.*inactive' list-output
        bash "$proxy_ctl" awg on work
        bash "$proxy_ctl" awg off home
        bash "$proxy_ctl" awg restart home
        grep -q '^start proxy-suite-awg-work$' "$SYSTEMCTL_LOG"
        grep -q '^stop proxy-suite-awg-home$' "$SYSTEMCTL_LOG"
        grep -q '^restart proxy-suite-awg-home$' "$SYSTEMCTL_LOG"

        if bash "$proxy_ctl" awg on missing 2> error-output; then
          exit 1
        fi
        grep -q 'Unknown AmneziaWG profile' error-output
        touch "$out"
      '';

  readme-doc-source = builtins.seq (
    assert !(pkgs.lib.hasInfix "environment.systemPackages" readmeDocSource);
    assert !(pkgs.lib.hasInfix "packageByPattern" readmeDocSource);
    true
  ) (pkgs.writeText "proxy-suite-readme-doc-source-check" "ok");

  package-source = builtins.seq (
    assert !(pkgs.lib.hasInfix "../../pkgs/proxy-suite-tray.nix" trayModuleSource);
    assert !(pkgs.lib.hasInfix "../../pkgs/tg-ws-proxy.nix" tgWsProxyModuleSource);
    assert !(pkgs.lib.hasInfix "../../../pkgs/proxy-ctl.nix" controlModuleSource);
    true
  ) (pkgs.writeText "proxy-suite-package-source-check" "ok");
}
