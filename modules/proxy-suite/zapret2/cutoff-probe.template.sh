set -euo pipefail
export PATH=@path@
cd @dir@
# Root works only here, which nobody else writes to now; the group's probe requests
# come through requests/. Anything left from when the group could write here goes:
# a symlink under a name below would have root write, or read, where it points.
for f in asn.txt sni.txt asn.new sni.new proxy.json proxy.json.tmp egress ts force; do
  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -O "$f" ]; }; then
    rm -f -- "$f"
  fi
done
touch asn.txt sni.txt
force=0
if [ -e requests/force ]; then
  force=1
  rm -f requests/force
fi
now=$(date +%s)
# Digits only: $(( )) would run what a[$(...)] in it names.
last=$(cat ts 2>/dev/null || true)
[[ $last =~ ^[0-9]+$ ]] || last=0

# The name map belongs to this line: probe again when its network changes, else
# once a day. Two services name the network, and they must agree: ipinfo.io alone now
# and then named Cloudflare's for this line's, and each flip cost a full probe. One
# answer alone counts only for the network already known (or when none is yet); no
# answer at all (offline, captive portal) is no reason to probe.
asn() {
  curl -sS --max-time 10 "$1" 2>/dev/null | jq -r "$2"' | select(test("^AS[0-9]+$"))' 2>/dev/null || true
}
known=$(cat egress 2>/dev/null || true)
ipinfo=$(asn https://ipinfo.io/json '(.org // "") | split(" ")[0]')
ifconfig=$(asn https://ifconfig.co/json '.asn // ""')
if [ -n "$ipinfo" ] && [ -n "$ifconfig" ] && [ "$ipinfo" != "$ifconfig" ]; then
  echo "ipinfo.io says $ipinfo, ifconfig.co says $ifconfig; keeping the last probe"
  exit 0
fi
egress=${ipinfo:-$ifconfig}
if [ -z "$egress" ]; then
  echo "no answer about this line's network; not probing"
  exit 0
fi
if [ -z "$ipinfo" ] || [ -z "$ifconfig" ]; then
  if [ -n "$known" ] && [ "$egress" != "$known" ]; then
    echo "only one service answered, with $egress for this line's $known; keeping the last probe"
    exit 0
  fi
fi
if [ "$force" = 0 ] && [ "$egress" = "$known" ] &&
  [ $((now - last)) -lt 86400 ]; then
  exit 0
fi
echo "probing the line from $egress"

rc=0
z2k-detect tcp16 -targets @lists@/tcp16_targets.txt -parallel 50 -asn-out asn.new || rc=$?
case "$rc" in
  1)
    rc=0
    z2k-detect tcp16 -targets @lists@/tcp16_targets.txt -scan @lists@/sni_wl_candidates.txt \
      -per-asn -batch 5 -parallel 50 -sni-out sni.new || rc=$?
    # 2: no network took any name; the list of cut-off networks still stands.
    if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then
      rm -f asn.new sni.new
      echo "name search failed ($rc); keeping the previous maps"
      exit 0
    fi
    [ -e sni.new ] || : >sni.new
    ;;
  0)
    : >asn.new
    : >sni.new
    ;;
  *)
    rm -f asn.new
    echo "the probe did not run ($rc); keeping the previous maps"
    exit 0
    ;;
esac

changed=0
{ cmp -s asn.new asn.txt && cmp -s sni.new sni.txt; } || changed=1
mv -f asn.new asn.txt
mv -f sni.new sni.txt
@proxyRules@ asn.txt sni.txt @lists@/tcp16_nets.txt >proxy.json.tmp
mv -f proxy.json.tmp proxy.json
printf '%s\n' "$egress" >egress
printf '%s\n' "$now" >ts
echo "cut-off networks: $(grep -c '^[0-9]' asn.txt || true), with a name: $(grep -c '^[0-9]' sni.txt || true)"

# nfqws2 reads the maps once; learned strategies survive the restart.
if [ "$changed" = 1 ]; then
  systemctl try-restart @restartUnits@
fi
