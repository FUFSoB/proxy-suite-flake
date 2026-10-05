# zapret2 (nfqws2) services, under the zapret v1 unit and table names.
{
  lib,
  pkgs,
  cfg,
  packages,
  zapret2Sources,
  perAppZapretRulesFile,
  nft,
}:

let
  builders = import ./service/builders.nix { inherit lib pkgs; };
  inherit (builders) mkRestartingService;

  zapretCfg = cfg.zapret;
  perAppZapretCfg = cfg.perAppRouting.zapret;
  cutoffCfg = zapretCfg.zapret2.cutoff;
  inherit (import ./derived.nix { inherit lib cfg; })
    constants
    userControlAllows
    userControlAnyAllows
    userControlExtraGroupsFor
    zapretGlobalEnabled
    zapret2DirectSync
    zapret2ProxyFallback
    ;
  inherit
    (import ./zapret/common.nix {
      inherit
        lib
        pkgs
        cfg
        nft
        perAppZapretRulesFile
        ;
      scriptName = "proxy-suite-zapret2";
    })
    awgServiceNames
    tunInterfaces
    perAppRefuseUnderGlobal
    daemonSandbox
    perAppZapretMarkUpScript
    perAppZapretMarkDownScript
    ;

  runtime = import ./zapret2/runtime.nix {
    inherit
      lib
      pkgs
      cfg
      packages
      zapret2Sources
      ;
  };

  globalRuntime = runtime.mkRuntime {
    name = "proxy-suite-zapret2";
    qnum = constants.zapretGlobalQnum.zapret2;
    desyncMark = 1073741824; # 0x40000000
    desyncMarkPostnat = 536870912; # 0x20000000
    nftTable = "zapret2";
    modeFilter = if zapretCfg.zapret2.autoHostlist.enable then "autohostlist" else "hostlist";
    customScript =
      let
        exemptCidrs = lib.optionals zapretCfg.cidrExemption.enable zapretCfg.cidrExemption.cidrs;
      in
      if perAppZapretCfg.enable || tunInterfaces != [ ] || exemptCidrs != [ ] || cutoffCfg.enable then
        runtime.mkCustomScript {
          inherit tunInterfaces exemptCidrs;
          excludeMark = if perAppZapretCfg.enable then perAppZapretCfg.filterMark else null;
          probeCtMark = if cutoffCfg.enable then constants.zapret2CutoffProbeCtMark else null;
        }
      else
        null;
  };

  # Wrapped apps opted in: MODE_FILTER=none applies every profile to all their traffic.
  perAppRuntime = runtime.mkRuntime {
    name = "proxy-suite-zapret2";
    qnum = perAppZapretCfg.qnum;
    desyncMark = 134217728; # 0x8000000
    desyncMarkPostnat = 67108864; # 0x4000000
    filterMark = perAppZapretCfg.filterMark;
    nftTable = "proxy_suite_per_app_zapret";
    modeFilter = "none";
    customScript =
      if tunInterfaces != [ ] then runtime.mkCustomScript { inherit tunInterfaces; } else null;
  };

  # nfqws2 and proxy-ctl expect the list files to exist. With userControl its group
  # edits them: proxy-ctl renames a new list in, so the directories are what it writes.
  stateDirMode =
    if userControlAllows "zapret" then
      "2775 -g ${lib.escapeShellArg cfg.userControl.group}"
    # userControl.groups only, through ACLs: the group bits (their mask) stay open.
    else if userControlAnyAllows "zapret" then
      "2775"
    else
      "0755";
  mkPreStart = ''
    ${lib.getExe' pkgs.kmod "modprobe"} nfnetlink_queue 2>/dev/null || true
    install -d -m ${stateDirMode} ${runtime.stateDir}
    # A plain mkdir, not install -d, which would chmod and chown a symlink a member left in the
    # group's state directory.
    circular=${runtime.circularStateDir}
    if [ -L "$circular" ]; then rm -f -- "$circular"; fi
    mkdir -m ${lib.head (lib.splitString " " stateDirMode)} -- "$circular" 2>/dev/null || true
    touch ${runtime.autoHostlistFile} ${runtime.userHostlistFile} ${runtime.excludeHostlistFile}
    # In this unit's sandbox: a name a member left here leads nowhere else.
    ${constants.grantDirAcl pkgs runtime.stateDir (userControlExtraGroupsFor "zapret") "rwX"}
    ${runtime.initScript} start_fw
  '';

  # nfqws2 runs supervised; the firewall comes and goes around it.
  daemonConfig =
    runtimeEnv:
    {
      Type = "notify";
      ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
      Environment = runtimeEnv;
      # Its own part of the state only: under the sandbox below, the rest stays read-only.
      StateDirectoryMode = if userControlAnyAllows "zapret" then "2775" else "0755";
    }
    # systemd gives the state directory the unit's group on every start: the group's, which
    # edits the lists (as autoProxy's units do).
    // lib.optionalAttrs (userControlAllows "zapret") { Group = cfg.userControl.group; }
    # nfqws2 runs as root and writes its lists in a directory the zapret scope's group
    # writes to as well.
    // constants.rootInSharedDirConfig
    // daemonSandbox;

  cutoff = import ./zapret2/cutoff.nix {
    inherit
      lib
      pkgs
      cfg
      zapret2Sources
      nft
      ;
  };

  directSync = import ./zapret2/direct-sync.nix { inherit lib pkgs cfg; };

  # autohostlist wants nf_conntrack_tcp_be_liberal on; the stop puts back what the host had.
  # Outside the sandbox ("+"), which keeps /proc/sys read-only.
  conntrackLiberalKey = "/proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal";
  conntrackLiberalOn = "-+${pkgs.writeShellScript "proxy-suite-zapret2-liberal" ''
    saved="$RUNTIME_DIRECTORY/conntrack-liberal"
    # Created, never followed: this runs as root outside the sandbox.
    if [ ! -e "$saved" ] && [ ! -L "$saved" ]; then
      ${pkgs.coreutils}/bin/cat ${conntrackLiberalKey} | (set -o noclobber; cat > "$saved") 2>/dev/null || true
    fi
    echo 1 > ${conntrackLiberalKey}
  ''}";
  conntrackLiberalRestore = "-+${pkgs.writeShellScript "proxy-suite-zapret2-liberal" ''
    saved="$RUNTIME_DIRECTORY/conntrack-liberal"
    value=$(${pkgs.coreutils}/bin/cat "$saved" 2>/dev/null || echo 0)
    [[ $value =~ ^[01]$ ]] || value=0
    echo "$value" > ${conntrackLiberalKey}
    ${pkgs.coreutils}/bin/rm -f "$saved"
  ''}";

in
{
  services.proxy-suite.internal.services.proxy-suite-zapret2-direct = lib.mkIf (
    zapret2DirectSync || zapret2ProxyFallback
  ) directSync.service;
  services.proxy-suite.internal.paths.proxy-suite-zapret2-direct = lib.mkIf (
    zapret2DirectSync || zapret2ProxyFallback
  ) directSync.path;

  services.proxy-suite.internal.earlyPackages = [ runtime.package ];

  services.proxy-suite.internal.services.proxy-suite-zapret2-cutoff =
    lib.mkIf cutoffCfg.enable cutoff.service;
  services.proxy-suite.internal.timers.proxy-suite-zapret2-cutoff =
    lib.mkIf cutoffCfg.enable cutoff.timer;
  services.proxy-suite.internal.tmpfiles = lib.mkIf cutoffCfg.enable cutoff.tmpfiles;

  services.proxy-suite.internal.services.proxy-suite-zapret =
    lib.mkIf zapretGlobalEnabled
      (mkRestartingService {
        description = "zapret2 DPI bypass";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        conflicts = awgServiceNames;
        wantedBy = [ "multi-user.target" ];
        preStart = mkPreStart + ''
          ln -sfn ${globalRuntime}/strategies.json ${constants.zapret2StrategiesFile}
        '';
        runtimeDirectory = "proxy-suite-zapret";
        stateDirectory = "proxy-suite/zapret2";
        execStart = "${runtime.daemonScript}";
        execStopPost = [
          "${runtime.initScript} stop_fw"
        ]
        ++ lib.optional zapretCfg.zapret2.autoHostlist.enable conntrackLiberalRestore;
        # What zapret's start_fw would do for autohostlist, here outside the sandbox ("+"),
        # once the firewall has loaded nf_conntrack.
        execStartPost = if zapretCfg.zapret2.autoHostlist.enable then conntrackLiberalOn else null;
        extraServiceConfig = daemonConfig (
          runtime.mkEnv {
            runtime = globalRuntime;
            pidDir = "/run/proxy-suite-zapret";
          }
        );
      });

  services.proxy-suite.internal.services.proxy-suite-per-app-zapret =
    lib.mkIf perAppZapretCfg.enable
      (
        lib.mkMerge [
          (mkRestartingService {
            description = "proxy-suite per-app-routing zapret2 backend";
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            preStart = mkPreStart;
            runtimeDirectory = "proxy-suite-per-app-zapret";
            stateDirectory = "proxy-suite/zapret2";
            execStart = "${runtime.daemonScript}";
            execStartPre = "${perAppZapretMarkUpScript}";
            execStopPost = [
              "${runtime.initScript} stop_fw"
              "${perAppZapretMarkDownScript}"
            ];
            extraServiceConfig = daemonConfig (
              runtime.mkEnv {
                runtime = perAppRuntime;
                pidDir = "/run/proxy-suite-per-app-zapret";
              }
            );
          })
          {
            # Ahead of everything, preStart's script among them (mkBefore there): under a global
            # mode nothing of it runs, not even the queue's firewall rules.
            serviceConfig.ExecStartPre = lib.mkOrder 400 [ perAppRefuseUnderGlobal ];
          }
        ]
      );
}
