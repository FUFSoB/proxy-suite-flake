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
  fillTemplate = import ../lib/fill-template.nix;
  inherit (import ../derived.nix { inherit lib cfg; })
    constants
    userControlAllows
    userControlAnyAllows
    zapretGlobalEnabled
    ;
  z2k = zapret2Sources.z2k;
  lists = "${z2k}/files/lists";
  dir = constants.zapret2CutoffDir;
  unit = "proxy-suite-zapret2-cutoff";
  table = "proxy_suite_cutoff_probe";
  # try-restart fails on a unit that is not installed, so only name the ones built.
  restartUnits =
    lib.optional zapretGlobalEnabled "proxy-suite-zapret.service"
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

  probe = pkgs.writeShellScript "proxy-suite-zapret2" (
    fillTemplate ./cutoff-probe.template.sh {
      path = lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.diffutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.systemd
        z2kDetect
      ];
      dir = lib.escapeShellArg dir;
      inherit lists proxyRules;
      restartUnits = lib.escapeShellArgs restartUnits;
    }
  );

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
      StateDirectory = "proxy-suite/zapret2-cutoff";
      ExecStartPre = "${exempt}";
      ExecStart = "${probe}";
      ExecStopPost = "-${nft} delete table inet ${table}";
      # Root writes and reads here by fixed names: only root may add entries. The group's
      # `proxy-ctl zapret cutoff probe` drops its `force` file in requests/ instead.
      StateDirectoryMode = "0755";
    }
    // constants.rootInSharedDirConfig;
  };

  tmpfiles = [
    "d ${dir}/requests ${
      if userControlAllows "zapret" then
        "2770 root ${cfg.userControl.group}"
      # userControl.groups only, through ACLs (proxy-suite-acls): the mode keeps them open.
      else if userControlAnyAllows "zapret" then
        "2770 root root"
      else
        "0700 root root"
    } -"
  ];

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
