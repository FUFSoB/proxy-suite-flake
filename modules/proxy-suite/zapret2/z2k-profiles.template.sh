root=$out/root
mkdir -p "$root/lists" "$root/lua" conf
cp -r @z2k@/files/lists/extra_strats "$root/"
chmod -R u+w "$root"
cp "$root/extra_strats/TCP/RKN/Discord.txt" "$root/extra_strats/TCP_Discord.txt"
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

# The learned and hand-added sites join every profile over its blocked-sites list
# (rkn_tcp, quic, http_rkn), its whitelist gains our excludes, and the circular args
# it pins to the zapret2 docs are dropped so autoHostlist fills them in. A profile
# with --hostlist-auto wins every flow with a known name (nfq2/desync.c), so learning
# goes in a last profile of its own with no strategies, as z2k's own autohostlist
# did: on rkn_tcp it would take YouTube from yt_tcp/gv_tcp below it. rkn_tcp then
# leaves their hosts to them even once learned or added by hand.
#
# QUIC: z2k's pool is one profile for YouTube's and the blocked sites' QUIC alike. Its
# detector needs z2k's own zapret2 fork (circular_report_failure) and takes nfqws2's
# standard one on ours, where udp_in=1 counts the server's first flight, which DPI
# lets through before it drops the flow (two packets from Cloudflare), as a success
# that undoes every failure counted. udp_in=4: a real handshake brings back more.
#
# With $learnArgs (autoHostlist.extendedDetection), detect.lua's ps_learn learns
# instead, in the same last place. It cannot ride along on the autohostlist profile:
# nfqws2 applies nothing there to a host in no list, Lua included. It writes the
# same auto list and reads the same excludes, which it checks itself.
#
# $stallWatch (detect.lua's ps_watch) goes first among the instances of the profile
# that takes the learned sites, ahead of its in-profile filters, which it resets after.
awk -v rkn="--hostlist=$root/extra_strats/TCP/RKN/List.txt" \
    -v wl="--hostlist-exclude=$root/lists/whitelist.txt" \
    -v yt="--hostlist-exclude=$root/extra_strats/TCP/YT/List.txt --hostlist-exclude=$root/extra_strats/TCP/YT_GV/List.txt" \
    -v hsuf="$hostlistSuffix" -v esuf="$excludeSuffix" \
    -v learn="$learnArgs" -v wlfile="$root/lists/whitelist.txt" -v watch="$stallWatch" '
  {
    for (i = 1; i <= NF; i++) {
      t = $i
      if (t == "--new") {
        prof++
      } else if (t ~ /^--filter-tcp=/ && !(prof in ports)) {
        ports[prof] = substr(t, 14)
      }
      pre = ""
      if (t ~ /^--(in-range|out-range|payload|lua-desync)=/) {
        if (watch != "" && seen && prof == learner && !watched++) pre = watch " "
        filtered[prof] = 1
      }
      if (t == rkn) {
        t = t " <HOSTLIST_NOAUTO>" hsuf
        if (!seen++) {
          t = t " " yt
          learner = prof
          if (prof in filtered) { print "z2k general TLS profile: hostlist after its instances" > "/dev/stderr"; exit 1 }
        }
      } else if (t == wl) {
        t = t esuf
      } else if (t ~ /^--lua-desync=circular:/) {
        n = split(substr(t, 23), p, ":")
        t = "--lua-desync=circular"
        for (j = 1; j <= n; j++)
          if (p[j] !~ /^(retrans|maxseq|inseq)=/ && p[j] != "reset") t = t ":" p[j]
        if (seen && prof == learner && t !~ /:key=rkn_tcp(:|$)/) { print "z2k general TLS profile is not rkn_tcp" > "/dev/stderr"; exit 1 }
        if (t ~ /:key=quic(:|$)/ && !quic++ && !sub(/:udp_in=1:/, ":udp_in=4:", t)) { print "z2k QUIC udp_in=1 not found" > "/dev/stderr"; exit 1 }
      }
      printf "%s%s%s", (i > 1 ? " " : ""), pre, t
    }
  }
  END {
    if (!seen || !(learner in ports)) { print "z2k general TLS profile not found" > "/dev/stderr"; exit 1 }
    if (quic != 1) { print "z2k QUIC profile not found" > "/dev/stderr"; exit 1 }
    if (watch != "" && !watched) { print "z2k general TLS profile has no instances" > "/dev/stderr"; exit 1 }
    if (learn == "")
      printf " --new --filter-tcp=%s --filter-l7=tls %s%s <HOSTLIST>%s", ports[learner], wl, esuf, hsuf
    else {
      # Its own excludes come first: the profile itself takes every remaining TLS flow.
      sub(/:exclude=/, ":exclude=" wlfile ",", learn)
      printf " --new --filter-tcp=%s --filter-l7=tls --in-range=-s65536 --out-range=-s32768 --payload=all --lua-desync=ps_learn:%s", ports[learner], learn
    }
  }' raw >body

awk -v z=@z2k@ '
  match($0, /^([A-Z0-9_]+_BLOB)="\$ZAPRET_BASE\/([^"]+)"/, m) { file[m[1]] = m[2] }
  match($0, /--blob=([a-z0-9_]+):@\$([A-Z0-9_]+_BLOB)/, m) { printf "--blob=%s:@%s/%s ", m[1], z, file[m[2]] }
' @z2k@/files/S99zapret2.new >blobs
grep -q -- '--blob=' blobs || { echo "z2k blob registrations not found" >&2; exit 1; }

mkdir -p "$out"
cp blobs "$out/blobs"
cp body "$out/profiles"
