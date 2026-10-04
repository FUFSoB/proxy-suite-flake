root=$out/root
mkdir -p "$root/lists" "$root/lua" conf
cp -r @z2k@/files/lists/extra_strats "$root/"
chmod -R u+w "$root"
cp "$root/extra_strats/TCP/RKN/Discord.txt" "$root/extra_strats/TCP_Discord.txt"
cp @z2k@/files/lists/cf_extra_check_ips.txt "$root/lists/"
: >"$root/lists/discovered-domains.txt"
# Its cutoff name step is emitted only on lines its probe flagged; ours is
# a no-op until the cutoff probe writes maps, so emit it unconditionally.
mkdir -p "$root/state"
echo 1 >"$root/state/tcp16.flag"
# The generator wires its detectors only when their Lua files exist.
ln -s @z2k@/files/lua/*.lua "$root/lua/"

export ZAPRET2_DIR="$root" CONFIG_DIR="$PWD/conf" LISTS_DIR="$root/lists"
(
  cd @z2k@
  bash -c '
    . lib/utils.sh && . lib/config.sh && . lib/strategies.sh && . lib/config_official.sh || exit 1
    print_info() { echo "$*" >&2; }
    print_success() { echo "$*" >&2; }
    print_warning() { echo "$*" >&2; }
    print_error() { echo "$*" >&2; }
    create_base_config >&2 &&
      generate_strategies_conf strats_new2.txt "$STRATEGIES_CONF" >&2 &&
      generate_quic_strategies_conf quic_strats.ini "$QUIC_STRATEGIES_CONF" >&2 &&
      create_default_strategy_files >&2 &&
      generate_nfqws2_opt_from_strategies
  '
) >generated

sed -n '/^NFQWS2_OPT="/,/^"$/p' generated | sed '1s/^NFQWS2_OPT="//; $d' | tr '\n' ' ' >raw
grep -q -- '--lua-desync=circular' raw || { echo "z2k generator produced no profiles" >&2; exit 1; }

# Its learned-host list becomes ours, its whitelist gains our excludes, and
# the circular args it pins to the zapret2 docs are dropped so autoHostlist
# fills them in. A profile with --hostlist-auto wins every flow with a known
# name (nfq2/desync.c), so learning goes in a last profile of its own with no
# strategies, as z2k's own autohostlist does: on rkn_tcp it would take
# YouTube from yt_tcp/gv_tcp below it. rkn_tcp then leaves their hosts to
# them even once learned or added by hand.
awk -v disc="--hostlist=$root/lists/discovered-domains.txt" \
    -v wl="--hostlist-exclude=$root/lists/whitelist.txt" \
    -v yt="--hostlist-exclude=$root/extra_strats/TCP/YT/List.txt --hostlist-exclude=$root/extra_strats/TCP/YT_GV/List.txt" \
    -v hsuf="$hostlistSuffix" -v esuf="$excludeSuffix" '
  {
    for (i = 1; i <= NF; i++) {
      t = $i
      if (t == "--new") {
        prof++
      } else if (t ~ /^--filter-tcp=/ && !(prof in ports)) {
        ports[prof] = substr(t, 14)
      }
      if (t == disc) {
        t = "<HOSTLIST_NOAUTO>" hsuf
        if (!seen++) { t = t " " yt; learner = prof }
      } else if (t == wl) {
        t = t esuf
      } else if (t ~ /^--lua-desync=circular:/) {
        n = split(substr(t, 23), p, ":")
        t = "--lua-desync=circular"
        for (j = 1; j <= n; j++)
          if (p[j] !~ /^(retrans|maxseq|inseq)=/ && p[j] != "reset") t = t ":" p[j]
      }
      printf "%s%s", (i > 1 ? " " : ""), t
    }
  }
  END {
    if (!seen || !(learner in ports)) { print "z2k general TLS profile not found" > "/dev/stderr"; exit 1 }
    printf " --new --filter-tcp=%s --filter-l7=tls %s%s <HOSTLIST>%s", ports[learner], wl, esuf, hsuf
  }' raw >body

# QUIC to blocked sites: z2k rotates QUIC strategies over YouTube's list alone, and DPI
# drops QUIC to the rest by name (every Discord host), so a browser stalls on each
# HTTP/3 attempt before it falls back to TCP. rkn_quic is its YouTube QUIC profile over
# the sites rkn_tcp handles, right after it: YouTube's hosts still meet yt_quic first.
# Its udp_in is 4: there DPI lets the server's first flight (two packets from Cloudflare)
# through before it drops the flow, which at udp_in=1 counted as a success and undid
# every failure counted; a real handshake brings back more.
awk -v yt="--hostlist=$root/extra_strats/UDP/YT/List.txt" \
    -v rkn="--hostlist=$root/extra_strats/TCP/RKN/List.txt --hostlist=$root/extra_strats/TCP_Discord.txt <HOSTLIST_NOAUTO>$hostlistSuffix" '
  {
    n = split($0, p, / --new /)
    for (i = 1; i <= n; i++) {
      printf "%s%s", (i > 1 ? " --new " : ""), p[i]
      if (p[i] ~ /key=yt_quic:/ && (k = index(p[i], yt))) {
        q = substr(p[i], 1, k - 1) rkn substr(p[i], k + length(yt))
        gsub(/key=yt_quic:/, "key=rkn_quic:", q)
        if (!sub(/:udp_in=1:/, ":udp_in=4:", q)) { print "z2k YouTube QUIC udp_in=1 not found" > "/dev/stderr"; exit 1 }
        printf " --new %s", q
        found++
      }
    }
  }
  END { if (found != 1) { print "z2k YouTube QUIC profile not found" > "/dev/stderr"; exit 1 } }
' body >body.quic
mv body.quic body

awk -v z=@z2k@ '
  match($0, /^([A-Z0-9_]+_BLOB)="\$ZAPRET_BASE\/([^"]+)"/, m) { file[m[1]] = m[2] }
  match($0, /--blob=([a-z0-9_]+):@\$([A-Z0-9_]+_BLOB)/, m) { printf "--blob=%s:@%s/%s ", m[1], z, file[m[2]] }
' @z2k@/files/S99zapret2.new >blobs
grep -q -- '--blob=' blobs || { echo "z2k blob registrations not found" >&2; exit 1; }

mkdir -p "$out"
cp blobs "$out/blobs"
cp body "$out/profiles"
