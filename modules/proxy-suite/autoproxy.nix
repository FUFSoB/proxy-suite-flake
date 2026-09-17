# autoProxy: probes the destinations the inbound listener dials through each
# exit in turn and remembers the first exit that gets content. The probe itself
# is `proxy-ctl proxy auto probe --json`, so every verdict is reproducible by hand.
{
  lib,
  pkgs,
  cfg,
  proxyCtl,
  autoProxyStateDir,
  runtimeDir,
  journalctl,
  userControlAllows,
}:

let
  apCfg = cfg.proxy.autoProxy;
  # The autoProxy scope's group writes the directory: `proxy auto learn` queues there.
  stateDirMode = if userControlAllows "autoProxy" then "0771" else "0751";
  render = import ./autoproxy-render.nix {
    inherit pkgs;
    inherit ((import ./derived.nix { inherit lib cfg; }).constants) serviceUser ifPrivileged;
  };
  jqFile =
    path:
    builtins.path {
      name = "proxy-suite-autoproxy";
      inherit path;
    };

  bin = lib.makeBinPath [
    pkgs.coreutils
    pkgs.curl
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.systemd
    pkgs.util-linux
    proxyCtl
  ];

  excludePattern = lib.concatStringsSep "|" (map lib.escapeRegex apCfg.exclude);

  # Sets $clash_api (empty when the API is off) and $clash_auth (curl args).
  clashApiBlock = ''
    socks_config="$(dirname "$index")/config.json"
    clash_api=$(jq -r '.experimental.clash_api.external_controller // empty' "$socks_config" 2>/dev/null || true)
    clash_secret=$(jq -r '.experimental.clash_api.secret // empty' "$socks_config" 2>/dev/null || true)
    clash_auth=()
    [ -z "$clash_secret" ] || clash_auth=(-H "Authorization: Bearer $clash_secret")
  '';

  sampler = pkgs.writeShellScript "proxy-suite-autoproxy" ''
    set -euo pipefail
    export PATH=${bin}
    state_dir=''${AUTOPROXY_STATE_DIR:-${lib.escapeShellArg autoProxyStateDir}}
    index=''${PROBE_EXITS_FILE:-${runtimeDir}/proxy-suite-socks/probe-exits.json}
    ${clashApiBlock}
    if [ -z "$clash_api" ]; then
      echo "sing-box has no Clash API (selection = \"first\"?); nothing to sample"
      exit 0
    fi
    install -d -m ${stateDirMode} "$state_dir"

    # Eleven snapshots a second apart: ten one-second deltas per connection.
    lines=$(
      for i in $(seq 0 10); do
        [ "$i" -eq 0 ] || sleep 1
        curl -sS --noproxy '*' --max-time 1 "''${clash_auth[@]}" "http://$clash_api/connections" 2>/dev/null ||
          echo '{}'
      done | jq -s -r --argjson min ${toString (300 * 1024)} \
        --argjson below ${toString (apCfg.slowBelowKiBps * 1024)} -f ${jqFile ./autoproxy-slow-sample.jq} || true
    )
    [ -z "$lines" ] || printf '%s\n' "$lines" >> "$state_dir/samples"
  '';

  runner = pkgs.writeShellScript "proxy-suite-autoproxy" ''
    set -euo pipefail
    export PATH=${bin}

    # --requests-only: just the `proxy-ctl proxy auto learn|forget|clear` requests.
    mode=''${1:-full}

    # Overridable to rehearse a run against a scratch copy; the units never set them.
    state_dir=''${AUTOPROXY_STATE_DIR:-${lib.escapeShellArg autoProxyStateDir}}
    export PROBE_EXITS_FILE=''${PROBE_EXITS_FILE:-${runtimeDir}/proxy-suite-socks/probe-exits.json}
    index=$PROBE_EXITS_FILE
    state="$state_dir/state.json"
    requests="$state_dir/requests"
    edits="$state_dir/edits"
    now=$(date +%s)
    ttl=$(( ${toString apCfg.ttlDays} * 86400 ))

    install -d -m ${stateDirMode} "$state_dir"

    # Timer runs and learn requests take turns on the state.
    exec 9> "$state_dir/lock"
    flock 9

    # Leftovers of a run that died partway; taken requests go back in line.
    rm -f "$state_dir/verdicts.json" "$state_dir/proxied-domains.txt" "$state".?????? "$state_dir/samples.taking"
    for queue in "$requests" "$edits"; do
      if [ -e "$queue.taking" ]; then
        cat "$queue.taking" >> "$queue"
        rm -f "$queue.taking"
        # Made here by root: the group appends to it too.
        chmod 0660 "$queue"
      fi
    done

    if [ -e "$state" ] && ! jq -e 'type == "object"' "$state" > /dev/null 2>&1; then
      echo "$state is unreadable; set aside as $state.broken, starting fresh" >&2
      mv -f "$state" "$state.broken"
    fi
    [ -s "$state" ] || echo '{"domains":{},"hosts":{},"exits":{},"backlog":{}}' > "$state"

    # Written aside and renamed, so a killed run never truncates the state.
    update() {
      local tmp
      tmp=$(mktemp "$state.XXXXXX")
      if ! jq "$@" "$state" > "$tmp"; then
        rm -f "$tmp"
        echo "could not update $state; it is left as it was" >&2
        return 1
      fi
      # mktemp makes it 0600; the state dir is 0751, so group-readable is enough.
      chmod 0640 "$tmp"
      mv -f "$tmp" "$state"
    }

    # --- 0. forget what `proxy-ctl proxy auto forget|relearn|clear` asked to ---
    # Before anything else, and even with the proxy stopped: its start renders the
    # rule-sets from the state again.
    edited=""
    if [ -s "$edits" ]; then
      mv -f "$edits" "$edits.taking"
      while read -r op dom; do
        case "$op" in
          forget)
            [[ "$dom" =~ ^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$ ]] || continue
            update --arg op forget --arg d "$dom" -f ${jqFile ./autoproxy-edit.jq}
            echo "forgot $dom"
            ;;
          clear)
            update --arg op clear --arg d "" -f ${jqFile ./autoproxy-edit.jq}
            echo "forgot everything learned"
            ;;
          *) continue ;;
        esac
        edited=1
      done < "$edits.taking"
      rm -f "$edits.taking"
    fi

    if [ ! -r "$index" ]; then
      echo "no probe listeners - is proxy-suite-socks running with autoProxy on?"
      exit 0
    fi

    # Routes through an outbound disabled since (`proxy-ctl proxy outbounds disable`)
    # are forgotten like the above, so their domains get probed again without it.
    inventory="$(dirname "$index")/outbounds.json"
    if [ -r "$inventory" ]; then
      while IFS=$'\t' read -r dom exit; do
        echo "forgot $dom: its exit $exit is disabled"
        update --arg op forget --arg d "$dom" -f ${jqFile ./autoproxy-edit.jq}
        edited=1
      done < <(jq -r --slurpfile inv "$inventory" '($inv[0].disabled // []) as $off
        | (.domains // {}) | to_entries[] | select(.value.exit as $e | $off | index([$e]))
        | "\(.key)\t\(.value.exit)"' "$state")
    fi
    [ -z "$edited" ] || ${render} "$index" "$state"

    # $1 JSON array of exit tags, $2 registrable domain, $3 wall:<page>|refused|slow.
    strike() {
      update --argjson tags "$1" --arg d "$2" --arg why "$3" --argjson now "$now" --argjson ttl "$ttl" \
        -f ${jqFile ./autoproxy-strike.jq}
    }

    # $1 registrable domain, $2 host probed, $3 probe JSON. Routes apply to the
    # whole domain (geo-blocks are drawn around sites); other verdicts only to
    # the host probed.
    record() {
      update --arg d "$1" --arg h "$2" --argjson r "$3" --argjson now "$now" '
        (if $r.verdict == "destination" then
          .domains[$d] = {verdict: "destination", exit: $r.exit, host: $h,
                          path: ($r.path // "/"), at: $now}
        else . end)
        | .hosts[$h] = {
            domain: $d,
            verdict: ($r.verdict // "error"),
            exit: (if $r.verdict == "destination" then $r.exit else null end),
            at: $now
          }
        | del(.backlog[$h])'
      # Exits refused on the path another egress reached: by a block page
      # (wall:<page>, the site turning the address away) or by the origin.
      local t why
      while IFS=$'\t' read -r t why; do
        strike "$(jq -cn --arg t "$t" '[$t]')" "$1" "$why"
      done < <(jq -r '(.path // "") as $p | .exit as $x
        | ([(.exits // [])[] | select(.tag == $x and .path == $p) | .judgement][0]) as $won
        | if $x == null then empty else
            # An origin refusal only counts against an exit when the winner got content.
            [(.exits // [])[] | select(.path == $p and .tag != "direct" and .tag != $x
                and (.judgement == "wall" or (.judgement == "blocked" and $won == "ok")))
              | {tag, why: (if .judgement == "wall" then "wall:" + .block else "refused" end)}]
            | unique_by(.tag)[] | "\(.tag)\t\(.why)"
          end' <<<"$3")
    }

    # Prefixes each host line with "registrable-domain<TAB>".
    # ponytail: last two labels, or three under a short list of two-label
    # suffixes. Switch to the Public Suffix List if a domain gets merged wrongly.
    to_reg() {
      awk -F'\t' '
        BEGIN {
          n = split("co.uk org.uk ac.uk gov.uk com.au net.au org.au co.jp ne.jp or.jp com.br com.tr co.kr com.cn com.hk co.in co.za com.ua com.mx co.nz", s, " ")
          for (i = 1; i <= n; i++) two[s[i]] = 1
        }
        {
          n = split($1, l, ".")
          if (n < 2) next
          k = (n >= 3 && (l[n - 1] "." l[n]) in two) ? l[n - 2] "." l[n - 1] "." l[n] : l[n - 1] "." l[n]
          print k "\t" $0
        }'
    }

    # The pinned direct listener, since TUN/TProxy capture --noproxy too.
    direct_url=$(jq -r '.[0] | "http://127.0.0.1:\(.port)"' "$index")

    # --- 1. verdicts are about this host's address; drop them if it changed ---
    egress=$(curl -sS -f --proxy "$direct_url" --max-time 10 https://api.ipify.org 2>/dev/null || true)
    # An error page or a captive portal must not pass for a new address: anything
    # that is not one discards every verdict this host learned.
    [[ "$egress" =~ ^[0-9a-fA-F.:]+$ ]] || egress=""
    if [ -n "$egress" ] && [ "$(jq -r '.egress // ""' "$state")" != "$egress" ]; then
      echo "egress is now $egress; discarding everything learned for the old address"
      update --arg e "$egress" \
        '{egress: $e, domains: {}, hosts: {}, exits: {}, backlog: (.backlog // {}), lastRun: (.lastRun // 0)}'
    fi

    # --- 2. which network (AS) each exit leaves from, once per TTL ---
    while IFS=$'\t' read -r tag port; do
      at=$(jq -r --arg t "$tag" '.exits[$t].at // 0' "$state")
      [ $(( now - at )) -ge "$ttl" ] || continue
      info=$(curl -sS --proxy "http://127.0.0.1:$port" --max-time 10 https://ipinfo.io/json 2>/dev/null || true)
      ip=$(jq -r '.ip // empty' <<<"$info" 2>/dev/null || true)
      asn=$(jq -r '(.org // "") | split(" ")[0]' <<<"$info" 2>/dev/null || true)
      [ -n "$ip" ] || continue
      update --arg t "$tag" --arg ip "$ip" --arg asn "$asn" --argjson now "$now" \
        '.exits[$t] += {ip: $ip, asn: $asn, at: $now}'
    done < <(jq -r '.[] | "\(.tag)\t\(.port)"' "$index")

    # --- 2b. strikes older than a TTL stop counting against an exit ---
    strike '[]' "" ""

    # See autoproxy-rounds.jq: one exit per AS, then the rest, bad exits last.
    rounds=$(jq -c --slurpfile s "$state" -f ${jqFile ./autoproxy-rounds.jq} "$index")
    round1=$(jq -r .r1 <<<"$rounds")
    round2=$(jq -r .r2 <<<"$rounds")

    # Every probe goes through here: a zero exit with nothing on stdout is no verdict
    # either, and empty is the one answer that slips through the checks downstream --
    # jq reads it as no input at all, so `.verdict // "error"' yields "" rather than
    # "error", and `--argjson r ""' then kills the run. Stdin is the caller's loop.
    probe_json() {
      local out
      out=$(proxy-ctl proxy auto probe --json "$@" < /dev/null 2>/dev/null || true)
      [ -n "$out" ] || out='{}'
      printf '%s' "$out"
    }

    walk() {
      local out first verdict
      out=$(probe_json --exits "$round1" "$1")
      verdict=$(jq -r '.verdict // "error"' <<<"$out")
      if { [ "$verdict" = both-fail ] || [ "$verdict" = unreachable ]; } && [ -n "$round2" ]; then
        first=$out
        out=$(probe_json --exits "$round2" "$1")
        # Round 1's refusals count against its exits too (see record).
        out=$(jq -c --argjson f "$first" '.exits = ($f.exits // []) + (.exits // [])' <<<"$out")
      fi
      printf '%s' "$out"
    }

    # Route changes take effect immediately, not at the end of the run.
    publish() { ${render} "$index" "$state"; }

    requeue=()
    if [ "$mode" = full ]; then
      # --- 3. re-check remembered exits, once per TTL ---
      # Probed routes only; slowness routes are judged by the sampler (4b).
      while IFS=$'\t' read -r dom host exit; do
        out=$(probe_json --exits "$exit" "$host")
        verdict=$(jq -r '.verdict // "error"' <<<"$out")
        if [ "$verdict" = destination ] && [ "$(jq -r '.exit // ""' <<<"$out")" = "$exit" ]; then
          update --arg d "$dom" --argjson now "$now" '.domains[$d].at = $now'
        elif [ "$verdict" = ok ]; then
          echo "recheck $dom: reachable directly now, dropping $exit"
          update --arg d "$dom" 'del(.domains[$d])'
          record "$dom" "$host" "$out"
          publish
        else
          echo "recheck $dom: $exit no longer works ($verdict), walking again"
          update --arg d "$dom" 'del(.domains[$d])'
          publish
          requeue+=("$dom"$'\t'"$host")
        fi
      done < <(jq -r --argjson now "$now" --argjson every "$ttl" '
        .domains | to_entries[]
        | select(.value.verdict == "destination" and ($now - .value.at) >= $every)
        | "\(.key)\t\(.value.host)\t\(.value.exit)"' "$state")

      # --- 4. what clients dialled since the last run, counted per host ---
      # Hit counts accumulate in a backlog that survives between runs.
      last=$(jq -r '.lastRun // 0' "$state")
      if [ "$last" -gt 0 ]; then since="@$last"; else since="-${apCfg.interval}"; fi
      dialled=$(
        ${journalctl} -u proxy-suite-inbounds --since "$since" --no-pager -o cat 2>/dev/null |
          sed -n 's/.* accepted tcp:\([a-zA-Z0-9._-]*\):[0-9]*.*/\1/p' |
          grep -E '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$' |
          ${lib.optionalString (excludePattern != "") "grep -vE '(^|\\.)(${excludePattern})$' |"}
          to_reg || true
      )
      counts=$(
        printf '%s\n' "$dialled" |
          awk -F'\t' 'NF == 2 { n[$2]++; d[$2] = $1 } END { for (h in n) print h "\t" d[h] "\t" n[h] }' |
          jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
            | {key: .[0], value: {domain: .[1], hits: (.[2] | tonumber)}}) | from_entries'
      )
      # Skipped: hosts of an already routed domain, hosts judged within the TTL.
      # Dropped: entries older than the TTL, and those a route now covers; host
      # verdicts past the TTL, which would only be probed again anyway.
      update --argjson c "$counts" --argjson now "$now" --argjson ttl "$ttl" '
        . as $s
        | .lastRun = $now
        | .hosts |= with_entries(select(.value.at + $ttl > $now))
        | .backlog = (reduce ($c | to_entries[]) as $e (($s.backlog // {});
            if ($s.domains[$e.value.domain].exit != null)
               or ((($s.hosts[$e.key].at // 0) + $ttl) > $now)
            then .
            else .[$e.key] = {
              domain: $e.value.domain,
              hits: ((.[$e.key].hits // 0) + $e.value.hits),
              first: (.[$e.key].first // $now)
            } end))
        | .backlog |= with_entries(select(.value.first + $ttl > $now
            and $s.domains[.value.domain].exit == null))'

      # --- 4b. what the sampler saw crawl (see autoproxy-slow-judge.jq) ---
      if [ -s "$state_dir/samples" ]; then
        mv -f "$state_dir/samples" "$state_dir/samples.taking"
        # Not `|| echo '[]'`: a grep that matches nothing fails the pipeline after
        # jq already printed [], and "[]\n[]" is no JSON for --argjson.
        obs=$(
          grep -E '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}'$'\t' "$state_dir/samples.taking" |
            ${lib.optionalString (excludePattern != "") "grep -vE '(^|\\.)(${excludePattern})'$'\\t' |"}
            to_reg |
            jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
              | {d: .[0], h: .[1], exit: .[2], slow: (.[3] == "slow"), peak: (.[4] | tonumber)})' ||
            true
        )
        [ -n "$obs" ] || obs='[]'
        rm -f "$state_dir/samples.taking"
        before=$(jq -c '.domains' "$state")
        update --argjson o "$obs" --argjson now "$now" --argjson ttl "$ttl" --argjson hits 3 \
          -f ${jqFile ./autoproxy-slow-judge.jq}

        # Each crawling destination gets the next exit, in probe order, that
        # answers it as well as direct does (`probe --via`). None left: it
        # stays direct for a TTL.
        while IFS=$'\t' read -r dom host tried; do
          was=''${tried##*,}
          # It crawled twice on the exit it was routed through.
          [ -z "$was" ] || strike "$(jq -cn --arg t "$was" '[$t]')" "$dom" slow
          via=""
          while IFS= read -r tag; do
            [[ ",$tried," != *",$tag,"* ]] || continue
            tried="''${tried:+$tried,}$tag"
            out=$(probe_json --via "$tag" "$host")
            verdict=$(jq -r '.verdict // ""' <<<"$out" 2>/dev/null || true)
            if [ "$verdict" = ok ]; then
              via=$tag
              break
            fi
            # Refused what direct gets, by a block page or by the origin.
            if [ "$verdict" = blocked ]; then
              why=$(jq -r --arg t "$tag" '[.exits[] | select(.tag == $t)] as $r
                | [$r[] | select(.judgement == "wall") | "wall:" + .block][0]
                  // (if any($r[]; .judgement == "blocked") then "refused" else "" end)' <<<"$out" 2>/dev/null || true)
              [ -z "$why" ] || strike "$(jq -cn --arg t "$tag" '[$t]')" "$dom" "$why"
            fi
          done < <(jq -r '.ordered[]' <<<"$rounds")
          if [ -n "$via" ]; then
            echo "slow $dom: crawls ''${was:+via $was}''${was:-directly}, routed via $via"
            update --arg d "$dom" --arg h "$host" --arg e "$via" --arg tried "$tried" --argjson now "$now" '
              .domains[$d] = {verdict: "slow", exit: $e, host: $h, at: $now, tried: ($tried | split(","))}
              | del(.slowWant[$d])'
          else
            echo "slow $dom: crawls ''${was:+via $was}''${was:-directly}, and no other exit reaches it; left direct"
            update --arg d "$dom" --argjson until $(( now + ttl )) '.slowSkip[$d] = $until | del(.slowWant[$d])'
          fi
        done < <(jq -r '(.slowWant // {}) | to_entries[]
          | "\(.key)\t\(.value.host)\t\(.value.tried | join(","))"' "$state")

        [ "$(jq -c '.domains' "$state")" = "$before" ] || publish
      fi
    fi

    # --- 5. probe: requests (uncapped), then broken routes, then the backlog ---
    asked=()
    if [ -s "$requests" ]; then
      mv -f "$requests" "$requests.taking"
      mapfile -t asked < <(grep -E '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$' "$requests.taking" | to_reg || true)
      rm -f "$requests.taking"
    fi
    backlog=()
    if [ "$mode" = full ]; then
      mapfile -t backlog < <(jq -r --argjson now "$now" --argjson ttl "$ttl" '
        . as $s | (.backlog // {}) | to_entries
        | map(select(($s.domains[.value.domain].exit == null)
            and ((($s.hosts[.key].at // 0) + $ttl) <= $now)))
        | sort_by(-.value.hits) | .[] | "\(.value.domain)\t\(.key)"' "$state")
    fi

    declare -A seen routed
    probe_row() {
      local dom=''${1%%$'\t'*} host=''${1#*$'\t'} out
      { [ -z "''${seen[$host]:-}" ] && [ -z "''${routed[$dom]:-}" ]; } || return 1
      seen[$host]=1
      out=$(walk "$host")
      # A probe that failed to run is no verdict; the host is probed again.
      if [ "$(jq -r '.verdict // "error"' <<<"$out")" = error ]; then
        echo "probe $host -> error, not recorded"
        return 0
      fi
      record "$dom" "$host" "$out"
      if [ "$(jq -r '.verdict // ""' <<<"$out")" = destination ]; then
        routed[$dom]=1
        publish
      fi
      # A censor verdict names an exit that got through, but zapret owns it.
      echo "probe $host -> $(jq -r '(.verdict // "error") + (if .verdict == "destination" then " via " + .exit
        elif .exit then " (" + .exit + " reaches it; left to zapret)" else "" end)' <<<"$out")"
    }

    for row in "''${asked[@]}"; do probe_row "$row" || true; done

    probed=0
    for row in "''${requeue[@]}" "''${backlog[@]}"; do
      [ "$probed" -lt ${toString apCfg.probesPerRun} ] || break
      if probe_row "$row"; then probed=$(( probed + 1 )); fi
    done
    echo "probed ''${#asked[@]} requested and $probed queued host(s); $(jq '(.backlog // {}) | length' "$state") still waiting"

    # sing-box reloads the rewritten rule-sets itself.
    ${render} "$index" "$state"
  '';

  # Group: `proxy-ctl proxy auto list|queue` reads state.json, `learn` queues requests.
  # Set on every unit that declares the directory - systemd re-applies the ownership
  # on each start.
  stateDirConfig = {
    StateDirectory = "proxy-suite/autoproxy";
    # 0751 and a 027 umask: sing-box (proxy-suite-daemon) reaches the rule-sets through
    # rules/, which its group reads (autoproxy-render.nix), and nothing else.
    StateDirectoryMode = stateDirMode;
    UMask = "0027";
  }
  // lib.optionalAttrs (userControlAllows "autoProxy") { Group = cfg.userControl.group; };

  mkUnit = description: args: {
    inherit description;
    after = [
      "proxy-suite-socks.service"
      "proxy-suite-inbounds.service"
    ];
    # No wants: a timer run must not start a proxy stopped on purpose; without
    # its listeners the runner has nothing to do and says so.
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${runner}${args}";
    }
    // stateDirConfig;
  };
in
{
  services.proxy-suite.internal.services.proxy-suite-autoproxy =
    mkUnit "proxy-suite - find the exit that reaches each destination, and remember it" "";

  services.proxy-suite.internal.services.proxy-suite-autoproxy-learn =
    mkUnit "proxy-suite - probe the destinations asked for with proxy-ctl proxy auto learn" " --requests-only";

  services.proxy-suite.internal.services.proxy-suite-autoproxy-sample = lib.mkIf (apCfg.slowBelowKiBps > 0) {
    description = "proxy-suite - watch live transfers for destinations that crawl directly";
    after = [ "proxy-suite-socks.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${sampler}";
    }
    // stateDirConfig;
  };

  services.proxy-suite.internal.timers.proxy-suite-autoproxy-sample = lib.mkIf (apCfg.slowBelowKiBps > 0) {
    description = "proxy-suite autoProxy transfer sampling";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "1m";
      OnUnitActiveSec = "1m";
      AccuracySec = "5s";
    };
  };

  services.proxy-suite.internal.timers.proxy-suite-autoproxy = {
    description = "proxy-suite autoProxy probe schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Not OnBootSec: after a rebuild restarts the timer, OnUnitActiveSec had
      # nothing to count from and the prober never ran again.
      OnActiveSec = "10m";
      OnUnitActiveSec = apCfg.interval;
      RandomizedDelaySec = "2m";
      Persistent = true;
    };
  };
}
