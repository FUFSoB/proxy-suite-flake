# Per-instance zapret2 runtime: a generated config and custom.d hook, no package copy.
{
  lib,
  pkgs,
  cfg,
  packages,
  zapret2Sources,
}:

let
  zapret2Cfg = cfg.zapret.zapret2;
  autoCfg = zapret2Cfg.autoHostlist;

  package = packages.zapret2;
  zapretBase = "${package}/opt/zapret2";

  # Shared by both instances: what the global one learns applies per-app too.
  inherit (import ../derived.nix { inherit lib cfg; }) constants;
  stateDir = constants.zapret2StateDir;
  autoHostlistFile = "${stateDir}/zapret-hosts-auto.txt";
  userHostlistFile = "${stateDir}/zapret-hosts-user.txt";
  excludeHostlistFile = "${stateDir}/zapret-hosts-user-exclude.txt";
  circularStateDir = "${stateDir}/circular";

  runtimeDeps = lib.attrValues {
    inherit (pkgs)
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      iproute2
      iptables
      ipset
      kmod
      nftables
      procps
      util-linux
      ;
  };

  toHex = value: "0x" + lib.toHexString value;
  orSource = value: fallback: if value != null then value else fallback;
  withSpaces = lib.concatMapStrings (arg: " " + arg);

  sources = import ./sources.nix {
    inherit lib pkgs;
    sources = zapret2Sources;
  };
  source = sources.${zapret2Cfg.strategySource};
  isZ2k = zapret2Cfg.strategySource == "z2k";

  blobPath = file: if lib.hasPrefix "/" file then file else "${zapretBase}/files/fake/${file}";

  hostlistMarkers = [
    "<HOSTLIST>"
    "<HOSTLIST_NOAUTO>"
  ];

  # Static domain filters join every profile that uses a hostlist marker.
  staticListArgs =
    lib.optional (
      zapret2Cfg.domains != [ ]
    ) "--hostlist-domains=${lib.concatStringsSep "," zapret2Cfg.domains}"
    ++ excludeDomainArgs;
  excludeDomainArgs = lib.optional (
    zapret2Cfg.excludeDomains != [ ]
  ) "--hostlist-exclude-domains=${lib.concatStringsSep "," zapret2Cfg.excludeDomains}";

  # lib.trim drops string context: without it the source's list paths are no build input,
  # so lazy trees never materialize them and the closure omits them.
  renderProfile =
    profile:
    lib.replaceStrings hostlistMarkers (map (
      marker: marker + withSpaces staticListArgs
    ) hostlistMarkers) (lib.addContextFrom profile (lib.trim profile));

  z2kGenerated = sources.z2k.mkProfiles {
    hostlistSuffix = withSpaces staticListArgs;
    # z2k's category profiles filter on their own lists, not on a marker.
    excludeSuffix = withSpaces ([ "--hostlist-exclude=${excludeHostlistFile}" ] ++ excludeDomainArgs);
  };

  profilesFile =
    if zapret2Cfg.profiles == null && isZ2k then
      "${z2kGenerated}/profiles"
    else
      pkgs.writeText "proxy-suite-zapret2" (
        lib.concatStringsSep " --new " (map renderProfile (orSource zapret2Cfg.profiles source.profiles))
      );

  blobsFile =
    if isZ2k then
      "${z2kGenerated}/blobs"
    else
      pkgs.writeText "proxy-suite-zapret2" (lib.concatStringsSep " " source.blobArgs);

  # The state layer undoes a rotation when the host succeeded within 30 s, unless
  # a failure came later; only z2k's own detector stamps that failure. Without the
  # stamp any success on a busy host (all of googlevideo.com) undoes every rotation.
  failStamp = pkgs.writeText "proxy-suite-zapret2-fail-stamp.lua" ''
    local count = automate_failure_counter
    function automate_failure_counter(hrec, crec, fails, maxtime)
      if not (crec and crec.failure) then
        hrec.z2k_last_fail_ts = type(clock_getfloattime) == "function" and clock_getfloattime() or os.time()
      end
      return count(hrec, crec, fails, maxtime)
    end
  '';

  # The state layer wraps circular, so it loads after the source's Lua.
  optPrefix = lib.concatStringsSep " " (
    map (file: "--lua-init=@${file}") (
      source.luaInit
      ++ [
        failStamp
        "${zapret2Sources.z2k}/files/lua/z2k-state-persist.lua"
      ]
    )
    ++ lib.mapAttrsToList (name: file: "--blob=${name}:@${blobPath file}") zapret2Cfg.blobs
  );

  # Detector args a circular instance leaves unset come from autoHostlist, so
  # learning and rotation agree; each source keeps its own fails and time.
  circularFill = lib.concatStringsSep " " (
    [
      "retrans=${toString autoCfg.retransThreshold}"
      "maxseq=${toString autoCfg.retransMaxseq}"
      "inseq=${toString autoCfg.incomingMaxseq}"
      "udp_out=${toString autoCfg.udpOut}"
      "udp_in=${toString autoCfg.udpIn}"
    ]
    ++ lib.optional autoCfg.retransReset "reset"
  );

  # The NFQUEUE window must exceed the retransmission threshold it counts, and
  # cover what the source's detectors need.
  packetWindow = {
    tcpOut = lib.max (6 + autoCfg.retransThreshold) (source.window.tcpOut or 0);
    tcpIn = 15;
    udpOut = lib.max (6 + autoCfg.retransThreshold) (source.window.udpOut or 0);
    udpIn = source.window.udpIn or 3;
  };

  mkConfig =
    {
      qnum,
      desyncMark,
      desyncMarkPostnat,
      nftTable,
      filterMark ? null,
      modeFilter,
    }:
    let
      header = pkgs.writeText "proxy-suite-zapret2" (
        lib.concatStringsSep "\n" (
          [
            "# Generated by proxy-suite. Do not edit."
            "WS_USER=root"
            "FWTYPE=nftables"
            "INIT_APPLY_FW=1"
            "QNUM=${toString qnum}"
            "DESYNC_MARK=${toHex desyncMark}"
            "DESYNC_MARK_POSTNAT=${toHex desyncMarkPostnat}"
            "ZAPRET_NFT_TABLE=${nftTable}"
          ]
          ++ lib.optional (filterMark != null) "FILTER_MARK=${toHex filterMark}"
          ++ lib.optional (!zapret2Cfg.ipv6) "DISABLE_IPV6=1"
          ++ [
            "NFQWS2_ENABLE=1"
            "NFQWS2_PORTS_TCP=${orSource zapret2Cfg.ports.tcp source.ports.tcp}"
            "NFQWS2_PORTS_UDP=${orSource zapret2Cfg.ports.udp source.ports.udp}"
            "NFQWS2_TCP_PKT_OUT=${toString packetWindow.tcpOut}"
            "NFQWS2_TCP_PKT_IN=${toString packetWindow.tcpIn}"
            "NFQWS2_UDP_PKT_OUT=${toString packetWindow.udpOut}"
            "NFQWS2_UDP_PKT_IN=${toString packetWindow.udpIn}"
            "MODE_FILTER=${modeFilter}"
            "AUTOHOSTLIST_FAIL_THRESHOLD=${toString autoCfg.failThreshold}"
            "AUTOHOSTLIST_FAIL_TIME=${toString autoCfg.failTime}"
            "AUTOHOSTLIST_RETRANS_THRESHOLD=${toString autoCfg.retransThreshold}"
            "AUTOHOSTLIST_RETRANS_RESET=${if autoCfg.retransReset then "1" else "0"}"
            "AUTOHOSTLIST_RETRANS_MAXSEQ=${toString autoCfg.retransMaxseq}"
            "AUTOHOSTLIST_INCOMING_MAXSEQ=${toString autoCfg.incomingMaxseq}"
            "AUTOHOSTLIST_UDP_OUT=${toString autoCfg.udpOut}"
            "AUTOHOSTLIST_UDP_IN=${toString autoCfg.udpIn}"
            "AUTOHOSTLIST_DEBUGLOG=${if autoCfg.debugLog then "1" else "0"}"
            ""
          ]
        )
      );
    in
    pkgs.runCommand "proxy-suite-zapret2"
      {
        nativeBuildInputs = [ pkgs.gawk ];
        inherit circularFill optPrefix;
      }
      ''
        opt="$optPrefix $(cat ${blobsFile}) $(cat ${profilesFile})"
        opt=$(printf '%s\n' "$opt" | awk -v fill="$circularFill" '
          {
            for (i = 1; i <= NF; i++) {
              t = $i
              if (t ~ /^--lua-desync=circular(:|$)/) {
                n = split(fill, f, " ")
                for (j = 1; j <= n; j++) {
                  k = f[j]
                  sub(/=.*/, "", k)
                  if (t !~ (":" k "(=|:|$)")) t = t ":" f[j]
                }
              }
              printf "%s%s", (i > 1 ? " " : ""), t
            }
          }')
        case "$opt" in
          *"'"*)
            echo "nfqws2 options must not contain a single quote" >&2
            exit 1
            ;;
        esac
        { cat ${header}; printf "NFQWS2_OPT='%s'\n" "$opt"; } >"$out"
      '';

  # Keep desync off TUN interfaces (it breaks proxied handshakes), off per-app
  # traffic, and off exempted subnets (e.g. NATed VMs whose traffic it would break).
  mkCustomScript =
    {
      tunInterfaces ? [ ],
      excludeMark ? null,
      exemptCidrs ? [ ],
      probeCtMark ? null,
    }:
    let
      chains = [
        {
          name = "postrouting";
          direction = "oifname";
          ipMatch = "daddr";
        }
        {
          name = "postnat";
          direction = "oifname";
          ipMatch = "daddr";
        }
        {
          name = "prerouting";
          direction = "iifname";
          ipMatch = "saddr";
        }
        {
          name = "prenat";
          direction = "iifname";
          ipMatch = "saddr";
        }
      ];
      nftFamily = cidr: if lib.hasInfix ":" cidr then "ip6" else "ip";
      mkRule =
        chain: match: comment:
        "  nft insert rule inet $ZAPRET_NFT_TABLE ${chain} ${match} return comment '\"${comment}\"'";
      rules = lib.concatMap (
        chain:
        lib.optional (excludeMark != null) (
          mkRule chain.name "mark and ${toHex excludeMark} != 0" "proxy-suite per-app-zapret bypass"
        )
        # Replies carry no socket, so the cutoff probe is matched by conntrack.
        ++ lib.optional (probeCtMark != null) (
          mkRule chain.name "ct mark and ${toHex probeCtMark} != 0" "proxy-suite cutoff probe bypass"
        )
        ++ map (
          interface: mkRule chain.name "${chain.direction} '\"${interface}\"'" "proxy-suite TUN bypass"
        ) tunInterfaces
        ++ map (
          cidr: mkRule chain.name "${nftFamily cidr} ${chain.ipMatch} ${cidr}" "proxy-suite CIDR exemption"
        ) exemptCidrs
      ) chains;
    in
    pkgs.writeText "proxy-suite-zapret2" (
      lib.concatStringsSep "\n" (
        [ "zapret_custom_firewall_nft() {" ]
        ++ rules
        ++ [
          "  return 0"
          "}"
          ""
        ]
      )
    );

  mkRuntime =
    {
      name,
      customScript ? null,
      ...
    }@args:
    pkgs.runCommand name { } ''
      mkdir -p "$out/init.d/sysv/custom.d"
      cp ${
        mkConfig (
          builtins.removeAttrs args [
            "name"
            "customScript"
          ]
        )
      } "$out/config"
      ${lib.optionalString (customScript != null) ''
        cp ${customScript} "$out/init.d/sysv/custom.d/50-proxy-suite-custom.sh"
      ''}
    '';

  mkEnv =
    { runtime, pidDir }:
    [
      "ZAPRET_BASE=${zapretBase}"
      "ZAPRET_RW=${runtime}"
      "HOSTLIST_BASE=${stateDir}"
      "PIDDIR=${pidDir}"
      "PATH=${lib.makeBinPath runtimeDeps}"
      # Read by z2k-state-persist.lua inside nfqws2, which inherits the unit's environment.
      "Z2K_STATE_DIR_OVERRIDE=${circularStateDir}"
      "Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE=${pidDir}"
    ]
    # The cutoff probe's maps, read by z2k's tcp16 name step; pin.txt forces one name for the line.
    ++ lib.optionals (zapret2Cfg.cutoff.enable && isZ2k) [
      "Z2K_TCP16_ASN=${constants.zapret2CutoffDir}/asn.txt"
      "Z2K_TCP16_SNI=${constants.zapret2CutoffDir}/sni.txt"
      "Z2K_SNI_PIN=${constants.zapret2CutoffDir}/pin.txt"
      "Z2K_TCP16_NETS=${zapret2Sources.z2k}/files/lists/tcp16_nets.txt"
    ];
  initScript = "${zapretBase}/init.d/sysv/zapret2";

  # nfqws2 as the unit's main process, with the command line the init script would
  # build. The init script backgrounds it with stdout on /dev/null in a oneshot
  # unit: when it dies, the unit stays active and the queue's bypass flag lets
  # every packet through untouched, with nothing in the log.
  daemonScript = pkgs.writeShellScript "proxy-suite-zapret2" ''
    . "$ZAPRET_BASE/init.d/sysv/functions"
    opt="--qnum=$QNUM $NFQWS2_OPT"
    filter_apply_hostlist_target opt
    set -f
    exec "$NFQWS2" $NFQWS2_OPT_BASE $opt
  '';
in
{
  inherit
    package
    stateDir
    autoHostlistFile
    userHostlistFile
    excludeHostlistFile
    circularStateDir
    mkCustomScript
    mkRuntime
    mkEnv
    initScript
    daemonScript
    ;
}
