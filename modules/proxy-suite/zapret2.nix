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
  inherit (import ./derived.nix { inherit lib cfg; }) constants userControlAllows;
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
    perAppConflicts
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
  mkPreStart = ''
    ${lib.getExe' pkgs.kmod "modprobe"} nfnetlink_queue 2>/dev/null || true
    install -d -m ${
      if userControlAllows "zapret" then "2775 -g ${lib.escapeShellArg cfg.userControl.group}" else "0755"
    } ${runtime.stateDir} ${runtime.circularStateDir}
    touch ${runtime.autoHostlistFile} ${runtime.userHostlistFile} ${runtime.excludeHostlistFile}
    ${runtime.initScript} start_fw
  '';

  # nfqws2 runs supervised; the firewall comes and goes around it.
  daemonConfig = runtimeEnv: {
    Type = "notify";
    ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
    Environment = runtimeEnv;
  };

  cutoff = import ./zapret2/cutoff.nix {
    inherit
      lib
      pkgs
      cfg
      zapret2Sources
      nft
      ;
  };

in
{
  services.proxy-suite.internal.earlyPackages = [ runtime.package ];

  services.proxy-suite.internal.services.proxy-suite-zapret2-cutoff =
    lib.mkIf cutoffCfg.enable cutoff.service;
  services.proxy-suite.internal.timers.proxy-suite-zapret2-cutoff =
    lib.mkIf cutoffCfg.enable cutoff.timer;

  services.proxy-suite.internal.services.proxy-suite-zapret =
    lib.mkIf zapretCfg.enable
      (mkRestartingService {
        description = "zapret2 DPI bypass";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        conflicts = awgServiceNames;
        wantedBy = [ "multi-user.target" ];
        preStart = mkPreStart;
        runtimeDirectory = "proxy-suite-zapret";
        stateDirectory = "proxy-suite";
        execStart = "${runtime.daemonScript}";
        execStopPost = "${runtime.initScript} stop_fw";
        extraServiceConfig = daemonConfig (
          runtime.mkEnv {
            runtime = globalRuntime;
            pidDir = "/run/proxy-suite-zapret";
          }
        );
      });

  services.proxy-suite.internal.services.proxy-suite-per-app-zapret =
    lib.mkIf perAppZapretCfg.enable
      (mkRestartingService {
        description = "proxy-suite per-app-routing zapret2 backend";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        conflicts = perAppConflicts ++ awgServiceNames;
        preStart = mkPreStart;
        runtimeDirectory = "proxy-suite-per-app-zapret";
        stateDirectory = "proxy-suite";
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
      });
}
