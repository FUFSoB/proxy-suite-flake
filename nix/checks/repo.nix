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
          pkgs.python3
          pkgs.coreutils
          pkgs.gawk
          pkgs.jq
        ];
      }
      ''
        proxy_ctl=${../../pkgs/proxy-ctl/proxy_ctl.py}

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
          python3 "$proxy_ctl" proxy subs list > output
        # The old spelling still dispatches.
        env SUB_TAGS_FILE="$PWD/tags.json" SUB_CACHE_DIR="$PWD/cache" \
          python3 "$proxy_ctl" subscription list | cmp - output

        awk '$1 == "plain" { found = 1; if ($NF != "2") exit 1 } END { exit found ? 0 : 1 }' output
        awk '$1 == "hybrid" { found = 1; if ($NF != "3") exit 1 } END { exit found ? 0 : 1 }' output
        awk '$1 == "bad" { found = 1; if ($NF != "?") exit 1 } END { exit found ? 0 : 1 }' output

        touch "$out"
      '';

  proxy-ctl-outbounds =
    pkgs.runCommand "proxy-suite-proxy-ctl-outbounds-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        proxy_ctl=${../../pkgs/proxy-ctl/proxy_ctl.py}

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
            python3 "$proxy_ctl" "$@"
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
          pkgs.python3
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
        ];
      }
      ''
        proxy_ctl=${../../pkgs/proxy-ctl/proxy_ctl.py}

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
        cutoff=$(env ZAPRET_CUTOFF_ENABLED=1 ZAPRET_STATE_DIR="$state" python3 "$proxy_ctl" zapret cutoff)
        printf '%s\n' "$cutoff" | grep -q 'from AS12389$'
        printf '%s\n' "$cutoff" | grep -qx 'Cutoff:  2 network(s)'
        printf '%s\n' "$cutoff" | grep -qE '^  AS24940 +300\.ya\.ru$'
        printf '%s\n' "$cutoff" | grep -qE '^  AS14061 +no name - proxy fallback$'

        # Without the zapret2 engine there is nothing to inspect.
        ! env ZAPRET_AUTO_ENABLED=0 ZAPRET_STATE_DIR="$state" python3 "$proxy_ctl" zapret auto list

        touch "$out"
      '';

  proxy-ctl-complete =
    pkgs.runCommand "proxy-suite-proxy-ctl-complete-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        proxy_ctl=${../../pkgs/proxy-ctl/proxy_ctl.py}

        printf '%s\n' '["home","work"]' > awg.json
        jq -n '[{name:"torrent",route:"direct"}]' > profiles.json
        jq -n '{tags:["own-vps","community-de"]}' > inventory.json

        run() {
          env AWG_PROFILES_FILE="$PWD/awg.json" \
            PER_APP_ROUTING_PROFILES_FILE="$PWD/profiles.json" \
            OUTBOUND_INVENTORY_FILE="$PWD/inventory.json" \
            python3 "$proxy_ctl" __complete "$@"
        }

        # Every group the help lists must complete, or the table has drifted.
        python3 "$proxy_ctl" help | awk '/^  [a-z]/ { print $1 }' | sort -u > groups
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
        env AWG_PROFILES_FILE=/nonexistent python3 "$proxy_ctl" __complete awg on

        # Every shell's completion file at least parses.
        bash -n ${../../pkgs/proxy-ctl/completions/proxy-ctl.bash}
        ${pkgs.zsh}/bin/zsh -n ${../../pkgs/proxy-ctl/completions/_proxy-ctl}
        HOME="$TMPDIR" ${pkgs.fish}/bin/fish --no-execute ${../../pkgs/proxy-ctl/completions/proxy-ctl.fish}

        touch "$out"
      '';

  proxy-ctl-where =
    pkgs.runCommand "proxy-suite-proxy-ctl-where-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        proxy_ctl=${../../pkgs/proxy-ctl/proxy_ctl.py}

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
        grep -q 'proxy.routing.rules are not visible' where

        verdict discord.com '-> direct, with the zapret2 bypass'
        verdict nyt.com '-> direct, with the zapret2 bypass'
        # Excluded is not bypassed: it must not read as a zapret2 verdict.
        verdict ok.ru '-> nothing runtime matches it'
        verdict example.org '-> nothing runtime matches it'

        # A URL is accepted where a hostname is.
        verdict https://open.spotify.com/track/x '^  domain *open.spotify.com$'

        ! python3 "$proxy_ctl" where 2>/dev/null

        touch "$out"
      '';

  # proxy_ctl.py's function-level tests: the probe verdict table and exit walk,
  # autoProxy learn/queue, inbound stats and subscriptions, apps run.
  proxy-ctl-unit =
    pkgs.runCommand "proxy-suite-proxy-ctl-unit-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      export PYTHONDONTWRITEBYTECODE=1
      python ${../../pkgs/proxy-ctl}/test_proxy_ctl.py
      touch "$out"
    '';

  # autoProxy slowness routing: sampler and judge.
  autoproxy-slowness =
    pkgs.runCommand "proxy-suite-autoproxy-slowness-check"
      { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        sample=${../../modules/proxy-suite/autoproxy-slow-sample.jq}
        judge=${../../modules/proxy-suite/autoproxy-slow-judge.jq}

        # A steady crawl, a burst, probe and outbound-test traffic, and a tiny flow.
        res="$(jq -n -c '[range(0; 11) as $t | {connections: [
            {id: "a", metadata: {host: "i.pximg.net", type: "mixed/mixed-in"}, chains: ["direct"], download: ($t * 50000)},
            {id: "b", metadata: {host: "audio.example", type: "mixed/mixed-in"}, chains: ["direct"], download: (if $t >= 5 then 2000000 else 0 end)},
            {id: "c", metadata: {host: "probe.example", type: "mixed/probe-in-0"}, chains: ["direct"], download: ($t * 50000)},
            {id: "d", metadata: {host: "tiny.example", type: "mixed/mixed-in"}, chains: ["direct"], download: ($t * 1000)},
            {id: "e", metadata: {host: "far.example", type: "mixed/mixed-in"}, chains: ["primary", "proxy"], download: ($t * 50000)},
            {id: "f", metadata: {host: "speed.example", type: "mixed/proxy-suite-test-in"}, chains: ["primary", "proxy-suite-test"], download: ($t * 50000)}
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

  # Per-user inbound traffic collection; `proxy-ctl inbounds stats` is in proxy-ctl-unit.
  inbound-stats =
    pkgs.runCommand "proxy-suite-inbound-stats-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
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

        touch "$out"
      '';

  proxy-ctl-amneziawg =
    pkgs.runCommand "proxy-suite-proxy-ctl-amneziawg-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        proxy_ctl=${../../pkgs/proxy-ctl/proxy_ctl.py}

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

        python3 "$proxy_ctl" awg list > list-output
        grep -q 'home.*active' list-output
        grep -q 'work.*inactive' list-output
        python3 "$proxy_ctl" awg on work
        python3 "$proxy_ctl" awg off home
        python3 "$proxy_ctl" awg restart home
        grep -q '^start proxy-suite-awg-work$' "$SYSTEMCTL_LOG"
        grep -q '^stop proxy-suite-awg-home$' "$SYSTEMCTL_LOG"
        grep -q '^restart proxy-suite-awg-home$' "$SYSTEMCTL_LOG"

        if python3 "$proxy_ctl" awg on missing 2> error-output; then
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
