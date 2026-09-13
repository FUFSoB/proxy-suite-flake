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
  inherit (builders) mkOneshotService;

  zapretCfg = cfg.zapret;
  perAppZapretCfg = cfg.perAppRouting.zapret;
  inherit (import ./derived.nix { inherit lib cfg; }) constants;
  awgServiceNames = map (name: "proxy-suite-awg-${name}.service") (
    builtins.attrNames cfg.amneziaWg.profiles
  );

  runtime = import ./zapret2/runtime.nix {
    inherit
      lib
      pkgs
      cfg
      packages
      zapret2Sources
      ;
  };

  tunInterfaces = lib.unique (
    lib.optional (cfg.proxy.enable && cfg.proxy.tun.enable) cfg.proxy.tun.interface
    ++ lib.optional (cfg.proxy.enable && cfg.perAppRouting.tun.enable) cfg.perAppRouting.tun.interface
  );

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
      if perAppZapretCfg.enable || tunInterfaces != [ ] || exemptCidrs != [ ] then
        runtime.mkCustomScript {
          inherit tunInterfaces exemptCidrs;
          excludeMark = if perAppZapretCfg.enable then perAppZapretCfg.filterMark else null;
        }
      else
        null;
  };

  # Wrapped apps opted in: MODE_FILTER=none applies every profile to all their traffic.
  perAppRuntime = runtime.mkRuntime {
    name = "proxy-suite-per-app-zapret2";
    qnum = perAppZapretCfg.qnum;
    desyncMark = 134217728; # 0x8000000
    desyncMarkPostnat = 67108864; # 0x4000000
    filterMark = perAppZapretCfg.filterMark;
    nftTable = "proxy_suite_per_app_zapret";
    modeFilter = "none";
    customScript =
      if tunInterfaces != [ ] then runtime.mkCustomScript { inherit tunInterfaces; } else null;
  };

  # nfqws2 and proxy-ctl expect the list files to exist.
  mkPreStart = ''
    ${lib.getExe' pkgs.kmod "modprobe"} nfnetlink_queue 2>/dev/null || true
    install -d -m 0755 ${runtime.stateDir} ${runtime.circularStateDir}
    touch ${runtime.autoHostlistFile} ${runtime.userHostlistFile} ${runtime.excludeHostlistFile}
  '';

  perAppZapretMarkUpScript = pkgs.writeShellScript "proxy-suite-per-app-zapret2-mark-up" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_zapret_mark 2>/dev/null || true
    ${nft} -f ${perAppZapretRulesFile}
  '';

  perAppZapretMarkDownScript = pkgs.writeShellScript "proxy-suite-per-app-zapret2-mark-down" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_zapret_mark 2>/dev/null || true
  '';
in
{
  environment.systemPackages = lib.mkBefore [ runtime.package ];

  systemd.services.zapret-discord-youtube = lib.mkIf zapretCfg.enable (mkOneshotService {
    description = "zapret2 DPI bypass";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    conflicts = awgServiceNames;
    wantedBy = [ "multi-user.target" ];
    preStart = mkPreStart;
    runtimeDirectory = "proxy-suite-zapret";
    stateDirectory = "proxy-suite";
    execStart = "${runtime.initScript} start";
    execStop = "${runtime.initScript} stop";
    extraServiceConfig = {
      ExecReload = "${runtime.initScript} restart";
      Environment = runtime.mkEnv {
        runtime = globalRuntime;
        pidDir = "/run/proxy-suite-zapret";
      };
    };
  });

  systemd.services.proxy-suite-per-app-zapret = lib.mkIf perAppZapretCfg.enable (mkOneshotService {
    description = "proxy-suite per-app-routing zapret2 backend";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    conflicts = [
      "proxy-suite-tproxy.service"
      "proxy-suite-tun.service"
    ]
    ++ awgServiceNames;
    preStart = mkPreStart;
    runtimeDirectory = "proxy-suite-per-app-zapret";
    stateDirectory = "proxy-suite";
    execStart = "${runtime.initScript} start";
    execStop = "${runtime.initScript} stop";
    execStartPre = "${perAppZapretMarkUpScript}";
    execStopPost = "${perAppZapretMarkDownScript}";
    extraServiceConfig.Environment = runtime.mkEnv {
      runtime = perAppRuntime;
      pidDir = "/run/proxy-suite-per-app-zapret";
    };
  });
}
