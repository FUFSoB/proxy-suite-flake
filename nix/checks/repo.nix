{
  pkgs,
  rg,
  generatedOptionsDoc,
  generatedReadmeDoc,
  readmeDocSource,
  tgWsProxyModuleSource,
  controlModuleSource,
}:

let
  # Every proxy-ctl CLI check runs against the same disabled-feature defaults; only the
  # files and the feature under test differ.
  perAppRoutingOff = ''
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
  '';
in
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

  # The tree as `nix fmt` leaves it.
  nix-format =
    pkgs.runCommand "proxy-suite-nix-format-check" { nativeBuildInputs = [ pkgs.nixfmt ]; }
      ''
        cd ${
          pkgs.lib.fileset.toSource {
            root = ../..;
            fileset = pkgs.lib.fileset.fileFilter (file: file.hasExt "nix") ../..;
          }
        }
        find . -name '*.nix' -print0 | xargs -0 nixfmt --check
        touch "$out"
      '';

  # Pyflakes and bugbear over every script and front end, as ruff.toml configures them.
  python-lint =
    pkgs.runCommand "proxy-suite-python-lint-check" { nativeBuildInputs = [ pkgs.ruff ]; }
      ''
        cd ${
          pkgs.lib.fileset.toSource {
            root = ../..;
            fileset = pkgs.lib.fileset.unions [
              ../../ruff.toml
              (pkgs.lib.fileset.fileFilter (file: file.hasExt "py") ../..)
            ];
          }
        }
        ruff check --no-cache .
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
          ${perAppRoutingOff}          python3 "$proxy_ctl" proxy subs list > output
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
            ${perAppRoutingOff}            python3 "$proxy_ctl" "$@"
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
      '';

  # autoProxy slowness routing: sampler and judge.
  autoproxy-slowness =
    pkgs.runCommand "proxy-suite-autoproxy-slowness-check" { nativeBuildInputs = [ pkgs.jq ]; }
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

  # autoProxy probe order: one exit per network first, bad exits last; and the
  # strikes that make an exit bad.
  autoproxy-rounds =
    pkgs.runCommand "proxy-suite-autoproxy-rounds-check" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        echo '[{"tag":"direct"},{"tag":"a"},{"tag":"b"},{"tag":"a2"},{"tag":"b2"},{"tag":"c"}]' > index.json
        echo '{"exits":{"a":{"asn":"AS1","bad":true},"b":{"asn":"AS2"},"a2":{"asn":"AS1"},
          "b2":{"asn":"AS2"},"c":{"asn":"AS3","bad":false}}}' > state.json
        r="$(jq -c --slurpfile s state.json -f ${../../modules/proxy-suite/autoproxy-rounds.jq} index.json)"
        printf '%s\n' "$r"
        # A refused a takes neither AS1's first place (a2 does) nor any place before b2.
        jq -e '. == {r1: "b,a2,c", r2: "b2,a", ordered: ["b", "a2", "b2", "c", "a"]}' <<<"$r" > /dev/null

        k() {
          jq -c --argjson tags "$1" --arg d "$2" --arg why "$3" --argjson now "$4" --argjson ttl 100 \
            -f ${../../modules/proxy-suite/autoproxy-strike.jq} <<<"$5"
        }
        s='{"exits":{"a":{"asn":"AS1"},"b":{}}}'
        # One destination is not enough, however often it strikes.
        s="$(k '["a"]' sekai.test refused 1000 "$s")"
        s="$(k '["a","b"]' sekai.test refused 1010 "$s")"
        jq -e '.exits.a.bad == false and .exits.a.asn == "AS1" and .exits.b.bad == false' <<<"$s" > /dev/null
        # A second one is.
        s="$(k '["a"]' pximg.net slow 1020 "$s")"
        jq -e '.exits.a | .bad and .badBy == ["sekai.test refused", "pximg.net slow"]' <<<"$s" > /dev/null
        jq -e '.exits.b.bad == false' <<<"$s" > /dev/null
        # A TTL later the older strike has expired.
        s="$(k '[]' "" "" 1115 "$s")"
        jq -e '.exits.a | (.bad | not) and .badBy == ["pximg.net slow"]' <<<"$s" > /dev/null
        # A block page may be a passing challenge: one is not enough either.
        s="$(k '["b"]' colorfulpalette.org wall:aws-waf 1120 "$s")"
        jq -e '.exits.b | (.bad | not) and .badBy == ["colorfulpalette.org wall:aws-waf"]' <<<"$s" > /dev/null
        s="$(k '["b"]' fandom.com wall:cloudflare 1130 "$s")"
        jq -e '.exits.b | .bad and .badBy == ["colorfulpalette.org wall:aws-waf", "fandom.com wall:cloudflare"]' <<<"$s" > /dev/null
        touch "$out"
      '';

  # `proxy-ctl proxy auto forget|clear`, as the runner applies them.
  autoproxy-edit =
    pkgs.runCommand "proxy-suite-autoproxy-edit-check" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        edit() { jq -c --arg op "$1" --arg d "$2" -f ${../../modules/proxy-suite/autoproxy-edit.jq} <<<"$3"; }
        s='{
          "domains": {"last.fm": {"exit": "a", "host": "www.last.fm"}, "pximg.net": {"exit": "b", "host": "i.pximg.net"}},
          "hosts": {"www.last.fm": {"domain": "last.fm"}, "cdn.last.fm": {"domain": "last.fm"}, "i.pximg.net": {"domain": "pximg.net"}},
          "backlog": {"api.last.fm": {"domain": "last.fm", "hits": 3}, "x.test": {"domain": "x.test", "hits": 1}},
          "slowWant": {"last.fm": 1}, "slowSkip": {"pximg.net": 1},
          "exits": {
            "a": {"asn": "AS1", "strikes": {"last.fm": {"why": "refused", "at": 1}, "sekai.test": {"why": "slow", "at": 2}}, "bad": true,
                  "badBy": ["last.fm refused", "sekai.test slow"]},
            "b": {"asn": "AS2"}
          },
          "egress": "203.0.113.1", "lastRun": 5
        }'

        # Forget: every trace of the one domain, and a strike it made no longer counts.
        f="$(edit forget last.fm "$s")"
        jq -e '(.domains | keys) == ["pximg.net"]' <<<"$f" > /dev/null
        jq -e '(.hosts | keys) == ["i.pximg.net"] and (.backlog | keys) == ["x.test"]' <<<"$f" > /dev/null
        jq -e '.slowWant == {} and .slowSkip == {"pximg.net": 1}' <<<"$f" > /dev/null
        jq -e '.exits.a | .asn == "AS1" and (.bad | not) and .badBy == ["sekai.test slow"]' <<<"$f" > /dev/null
        jq -e '.exits.b == {"asn": "AS2"}' <<<"$f" > /dev/null
        # A domain it never knew changes nothing.
        jq -e --argjson s "$s" '. == $s' <<<"$(edit forget nope.test "$s")" > /dev/null

        # Clear: every route and verdict; the exits, backlog and egress stay.
        c="$(edit clear "" "$s")"
        jq -e '.domains == {} and .hosts == {} and (has("slowWant") | not) and (has("slowSkip") | not)' <<<"$c" > /dev/null
        jq -e '.exits.a | .asn == "AS1" and .strikes == {} and (.bad | not) and .badBy == []' <<<"$c" > /dev/null
        jq -e '(.backlog | keys) == ["api.last.fm", "x.test"] and .egress == "203.0.113.1" and .lastRun == 5' <<<"$c" > /dev/null
        touch "$out"
      '';

  # A probe that exits 0 printing nothing: jq reads "" as no input at all, so the
  # "error" guard downstream saw "" instead of "error" and let it through to
  # `--argjson r ""`, which failed every autoProxy run until the state changed.
  # The helper is taken from the module, so it is the code the runner really uses.
  autoproxy-probe-json =
    pkgs.runCommand "proxy-suite-autoproxy-probe-json-check"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.gnused
          pkgs.coreutils
        ];
      }
      ''
        sed -n '/^    probe_json() {$/,/^    }$/p' ${../../modules/proxy-suite/autoproxy.nix} > helper.sh
        test -s helper.sh

        mkdir -p stub
        printf '%s\n' '#!/bin/sh' 'exit 0' > stub/proxy-ctl
        chmod +x stub/proxy-ctl
        export PATH="$PWD/stub:$PATH"

        set -euo pipefail
        . ./helper.sh
        # $out is the derivation's; the helper's own "out" is local to it.
        res=$(probe_json --exits direct example.test)
        test "$res" = '{}'
        # What the callers ask, and what used to come back empty.
        test "$(jq -r '.verdict // "error"' <<<"$res")" = error
        # And an update() built from it still runs.
        jq -e -n --argjson r "$res" '$r == {}' > /dev/null

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
        a() { jq -c --argjson q "$1" --argjson online "''${3:-{\}}" --argjson awg "''${4:-[]}" --arg day 2026-09-11 --argjson now "$now" -f "$add" <<<"$2"; }

        # XRay gives values as strings and leaves a zero counter without one.
        r='{"stat":[{"name":"user>>>fufsob>>>traffic>>>downlink","value":"3000000"},
          {"name":"user>>>fufsob>>>traffic>>>uplink","value":"2000"},
          {"name":"user>>>phone>>>traffic>>>uplink"},
          {"name":"inbound>>>vless-in>>>traffic>>>downlink","value":5},
          {"name":"outbound>>>direct>>>traffic>>>uplink","value":6}]}'
        s="$(a "$r" '{}')"
        s="$(a "$r" "$s")"
        jq -e '.days["2026-09-11"] | .user.fufsob == {down: 6000000, up: 4000}
          and .user.phone.up == 0 and .inbound["vless-in"].down == 10 and .outbound.direct.up == 12' <<<"$s" > /dev/null
        jq -e '.at == 1789135690' <<<"$s" > /dev/null
        # Nothing counted since the last reading: nothing changes.
        jq -e --argjson s "$s" '.days == $s.days' <<<"$(a '{}' "$s")" > /dev/null
        # An online user's last seen time is kept, and never goes back.
        o='{"users":[{"email":"phone","ips":[{"ip":"203.0.113.7","lastSeen":1789135000},{"ip":"203.0.113.8","lastSeen":1789135600}]}]}'
        s="$(a '{}' "$s" "$o")"
        jq -e '.seen.phone == 1789135600' <<<"$s" > /dev/null
        s="$(a '{}' "$s" '{"users":[{"email":"phone","ips":[{"ip":"203.0.113.7","lastSeen":1}]}]}')"
        jq -e '.seen.phone == 1789135600' <<<"$s" > /dev/null
        # Days more than a year old are let go.
        old="$(jq -c '.days["2024-01-01"] = {user: {fufsob: {up: 1}}}' <<<"$s")"
        jq -e '.days["2024-01-01"] == null' <<<"$(a '{}' "$old")" > /dev/null

        # AmneziaWG peers come with raw interface counters, of which only the growth is added.
        p() { echo '[{"interface":"awgi-home","key":"K","tag":"home","user":"tablet","rx":'"$1"',"tx":'"$2"',"handshake":'"$3"',"endpoint":"203.0.113.9:4000"}]'; }
        s="$(a '{}' "$s" '{}' "$(p 1000 5000 1789135500)")"
        jq -e '.days["2026-09-11"].user.tablet == {up: 1000, down: 5000} and .seen.tablet == 1789135500
          and .awgPeers.tablet == {tag: "home", handshake: 1789135500, endpoint: "203.0.113.9:4000"}' <<<"$s" > /dev/null
        s="$(a '{}' "$s" '{}' "$(p 1500 5200 1789135600)")"
        jq -e '.days["2026-09-11"].user.tablet == {up: 1500, down: 5200} and .seen.tablet == 1789135600' <<<"$s" > /dev/null
        # A counter below the last one restarted with its interface.
        s="$(a '{}' "$s" '{}' "$(p 100 100 0)")"
        jq -e '.days["2026-09-11"].user.tablet == {up: 1600, down: 5300} and .seen.tablet == 1789135600
          and .awgPeers == {}' <<<"$s" > /dev/null
        # A peer gone from the listeners leaves no counters behind.
        jq -e '.awgCounters == {}' <<<"$(a '{}' "$s")" > /dev/null

        touch "$out"
      '';

  # Proxy chains, resolved at start once subscription entries exist.
  outbound-detours =
    pkgs.runCommand "proxy-suite-outbound-detours-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        f=${../../modules/proxy-suite/outbound-detours.jq}
        d() { jq -c -f "$f" --argjson d "$1" --argjson sources "$2" --arg kind "$3" <<<"$4"; }

        # sing-box: a declared outbound and every entry of a subscription.
        r="$(d '{"outbounds":{"de":"ru"},"subscriptions":{"s":"warp"}}' '{"ru":"static","de":"static","s-a":"sub:s","warp":"warp"}' sing-box \
          '{"outbounds":[{"tag":"ru"},{"tag":"de"},{"tag":"s-a"},{"tag":"warp"}],"xray":[]}')"
        jq -e '.errors == [] and ([.outbounds[] | .detour] == [null, "ru", "warp", null])' <<<"$r" > /dev/null
        # XRay: dialerProxy, next to what sockopt already had.
        r="$(d '{"outbounds":{"de":"ru"},"subscriptions":{}}' '{"ru":"static","de":"static"}' xray \
          '{"outbounds":[{"tag":"ru"},{"tag":"de","streamSettings":{"sockopt":{"mark":1}}}],"xray":[]}')"
        jq -e '.outbounds[1].streamSettings.sockopt == {mark: 1, dialerProxy: "ru"}' <<<"$r" > /dev/null
        # Hybrid: sidecar outbounds chain in the sidecar, sing-box ones through anything.
        r="$(d '{"outbounds":{"x1":"x2","sb":"x1"},"subscriptions":{}}' '{"x1":"static","x2":"static","sb":"static"}' hybrid \
          '{"outbounds":[{"tag":"x1"},{"tag":"x2"},{"tag":"sb"}],"xray":[{"tag":"x1"},{"tag":"x2"}]}')"
        jq -e '.errors == [] and .xray[0].streamSettings.sockopt.dialerProxy == "x2"
          and .outbounds[0].detour == null and .outbounds[2].detour == "x1"' <<<"$r" > /dev/null
        r="$(d '{"outbounds":{"x1":"sb"},"subscriptions":{}}' '{"x1":"static","sb":"static"}' hybrid \
          '{"outbounds":[{"tag":"x1"},{"tag":"sb"}],"xray":[{"tag":"x1"}]}')"
        jq -e '[.errors[].message] == ["outbound '"'x1'"' runs on XRay and can only chain through another XRay outbound, not '"'sb'"'"]' <<<"$r" > /dev/null
        # A missing hop and a loop are errors, and nothing is rewritten.
        r="$(d '{"outbounds":{"a":"b","b":"a","c":"gone"},"subscriptions":{}}' '{"a":"static","b":"static","c":"static"}' sing-box \
          '{"outbounds":[{"tag":"a"},{"tag":"b"},{"tag":"c"}],"xray":[]}')"
        jq -e '(.errors | length) == 3 and all(.outbounds[]; .detour == null)' <<<"$r" > /dev/null

        touch "$out"
      '';

  # `proxy-ctl proxy outbounds disable` markers, as the start script reads them.
  outbound-disabled =
    let
      inherit
        (import ../../modules/proxy-suite/service/script-blocks/outbounds.nix {
          lib = pkgs.lib;
          inherit pkgs;
          jq = "${pkgs.jq}/bin/jq";
          proxyCfg.selectionExclude = [ "ex" ];
          selectionMode = "urltest";
          hybridEnabled = false;
          # Relative: the build directory.
          pinnedOutboundFile = "pinned";
          runtimeOutboundsDir = "obd";
          singBoxCfg = null;
          sshProxyCfg = null;
          warpCfg = null;
          torCfg = null;
          whitelistBypassJoiners = [ ];
          awgOutbounds = null;
          constants = null;
          pureXrayEnabled = null;
          collapseNamedOutbounds = null;
          backend = null;
          backendArg = null;
          xraySidecarRoutingMark = null;
          python3 = null;
          parserScriptsPythonPath = null;
          buildOutboundPy = null;
          mkSubscriptionBlock = null;
          mkSubscriptionLoadHelperBlock = null;
          runtimeSubscriptionsBlock = null;
        })
        selectionBlocks
        ;
      selection = pkgs.writeShellScript "outbound-selection" ''
        set -euo pipefail
        ${selectionBlocks}
      '';
    in
    pkgs.runCommand "proxy-suite-outbound-disabled-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
      mkdir obd
      export RUNTIME_DIR="$PWD" OUTBOUND_SOURCES_JSON='{}'
      export OUTBOUNDS_JSON='[{"tag":"a"},{"tag":"b"},{"tag":"ex"}]'

      # A marker takes its outbound out of selection and drops a pin on it; stale markers do nothing.
      touch obd/a.disabled obd/gone.disabled
      echo a > pinned
      ${selection} 2> err
      grep -q "pinned outbound 'a' is disabled" err
      jq -e '.pinned == "" and .disabled == ["a"] and .excluded == ["a", "ex"]' outbounds.json > /dev/null

      # With nothing left to select and no pin the start fails, saying how out.
      touch obd/b.disabled
      ! ${selection} 2> err
      grep -q "outbounds enable" err
      # A pin on one still enabled carries it.
      echo ex > pinned
      ${selection}
      jq -e '.pinned == "ex" and .disabled == ["a", "b"]' outbounds.json > /dev/null
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
    assert !(pkgs.lib.hasInfix "../../pkgs/tg-ws-proxy.nix" tgWsProxyModuleSource);
    assert !(pkgs.lib.hasInfix "../../../pkgs/proxy-ctl.nix" controlModuleSource);
    true
  ) (pkgs.writeText "proxy-suite-package-source-check" "ok");
}
