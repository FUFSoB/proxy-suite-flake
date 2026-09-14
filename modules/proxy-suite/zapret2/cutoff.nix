# 16 KB cutoff: some lines let TLS to certain hosting networks handshake and then
# kill the connection at 12-34 KB, which no strategy rotation fixes. z2k-detect
# probes which networks (AS) this line cuts and finds a whitelisted name per network
# that z2k-tcp16.lua puts into a fake ClientHello; the networks no name fixes go to
# a sing-box rule-set that sends them through the proxy.
{
  lib,
  pkgs,
  cfg,
  zapret2Sources,
  nft,
}:

let
  inherit (import ../derived.nix { inherit lib cfg; }) constants;
  z2k = zapret2Sources.z2k;
  lists = "${z2k}/files/lists";
  dir = constants.zapret2CutoffDir;
  unit = "proxy-suite-zapret2-cutoff";
  table = "proxy_suite_cutoff_probe";
  # try-restart fails on a unit that is not installed, so only name the ones built.
  restartUnits =
    lib.optional cfg.zapret.enable "zapret-discord-youtube.service"
    ++ lib.optional cfg.perAppRouting.zapret.enable "proxy-suite-per-app-zapret.service";

  z2kDetect = pkgs.buildGoModule {
    pname = "z2k-detect";
    version = "0-unstable-${z2k.shortRev or "local"}";
    src = "${z2k}/z2k-detect";
    vendorHash = "sha256-9Qv6O6/8MP9N44GPSDULEV/NcrHdEC3YZmIQmpaa1nE=";
    subPackages = [ "cmd/z2k-detect" ];
    # Its tests open raw sockets and dial out.
    doCheck = false;
    meta.mainProgram = "z2k-detect";
  };

  # $1 asn.txt, $2 sni.txt, $3 AS-to-prefix map; prints a sing-box source rule-set
  # with the prefixes of every cut-off network that no whitelisted name fixes.
  proxyRules = pkgs.writeShellScript "proxy-suite-zapret2" ''
    set -euo pipefail
    ${pkgs.gawk}/bin/awk -F'\t' '
      FILENAME == ARGV[1] { if ($1 ~ /^[0-9]+$/) cut[$1] = 1; next }
      FILENAME == ARGV[2] { if ($1 ~ /^[0-9]+$/) named[$1] = 1; next }
      ($1 in cut) && !($1 in named) { print $2 }
    ' "$1" "$2" "$3" \
      | ${pkgs.jq}/bin/jq -R -s -c '
          split("\n") | map(select(. != ""))
          | {version: 1, rules: (if length > 0 then [{ip_cidr: .}] else [] end)}'
  '';

  probe = pkgs.writeShellScript "proxy-suite-zapret2" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.diffutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.systemd
        z2kDetect
      ]
    }
    cd ${lib.escapeShellArg dir}
    touch asn.txt sni.txt
    force=0
    if [ -e force ]; then
      force=1
      rm -f force
    fi
    now=$(date +%s)

    # The name map belongs to this line: probe again when its network changes, else
    # once a day. No answer (offline, captive portal) is no reason to probe.
    info=$(curl -sS --max-time 10 https://ipinfo.io/json 2>/dev/null || true)
    egress=$(jq -r '((.org // "") | split(" ")[0]) as $as
      | if ($as | test("^AS[0-9]+$")) then $as else (.ip // "") end' <<<"$info" 2>/dev/null || true)
    if [ -z "$egress" ]; then
      echo "no answer about this line's address; not probing"
      exit 0
    fi
    if [ "$force" = 0 ] && [ "$egress" = "$(cat egress 2>/dev/null || true)" ] &&
      [ $((now - $(cat ts 2>/dev/null || echo 0))) -lt 86400 ]; then
      exit 0
    fi
    echo "probing the line from $egress"

    rc=0
    z2k-detect tcp16 -targets ${lists}/tcp16_targets.txt -parallel 50 -asn-out asn.new || rc=$?
    case "$rc" in
      1)
        rc=0
        z2k-detect tcp16 -targets ${lists}/tcp16_targets.txt -scan ${lists}/sni_wl_candidates.txt \
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
    ${proxyRules} asn.txt sni.txt ${lists}/tcp16_nets.txt >proxy.json.tmp
    mv -f proxy.json.tmp proxy.json
    printf '%s\n' "$egress" >egress
    printf '%s\n' "$now" >ts
    echo "cut-off networks: $(grep -c '^[0-9]' asn.txt || true), with a name: $(grep -c '^[0-9]' sni.txt || true)"

    # nfqws2 reads the maps once; learned strategies survive the restart.
    if [ "$changed" = 1 ]; then
      systemctl try-restart ${lib.escapeShellArgs restartUnits}
    fi
  '';

  # The probe measures this line, so its traffic leaves directly: proxyMark keeps it
  # out of TUN/TProxy like the backend's own, and the conntrack bit keeps zapret2 from
  # touching or learning it.
  exempt = pkgs.writeShellScript "proxy-suite-zapret2" ''
    set -euo pipefail
    ${nft} delete table inet ${table} 2>/dev/null || true
    ${nft} -f - <<EOF
    table inet ${table} {
      chain output {
        type route hook output priority mangle - 1; policy accept;
        socket cgroupv2 level 2 "system.slice/${unit}.service" meta mark set ${toString cfg.proxy.tproxy.proxyMark} ct mark set ct mark or ${toString constants.zapret2CutoffProbeCtMark}
      }
    }
    EOF
  '';
in
{
  inherit z2kDetect proxyRules;

  service = {
    description = "proxy-suite - probe this line for the 16 KB cutoff and find a name per network";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "proxy-suite/zapret2/cutoff";
      ExecStartPre = "${exempt}";
      ExecStart = "${probe}";
      ExecStopPost = "-${nft} delete table inet ${table}";
    };
  };

  timer = {
    description = "proxy-suite 16 KB cutoff probe schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Cheap unless the line changed or a day passed. Not OnBootSec: see autoproxy.nix.
      OnActiveSec = "5m";
      OnUnitActiveSec = "10m";
      RandomizedDelaySec = "1m";
      Persistent = true;
    };
  };
}
