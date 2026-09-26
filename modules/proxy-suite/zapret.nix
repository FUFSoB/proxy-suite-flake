# zapret DPI bypass services and optional CIDR exemption from NFQUEUE.
{
  lib,
  pkgs,
  cfg,
  zapret,
  perAppZapretRulesFile,
  nft,
}:

let
  builders = import ./service/builders.nix { inherit lib pkgs; };
  inherit (builders) mkOneshotService;

  zapretCfg = cfg.zapret;
  perAppZapretCfg = cfg.perAppRouting.zapret;
  inherit (import ./derived.nix { inherit lib cfg; }) zapretGlobalEnabled;
  inherit
    (import ./zapret/common.nix {
      inherit
        lib
        pkgs
        cfg
        nft
        perAppZapretRulesFile
        ;
    })
    awgServiceNames
    perAppConflicts
    perAppZapretMarkUpScript
    perAppZapretMarkDownScript
    ;
  zapretPackages = import ./zapret/packages.nix {
    inherit
      lib
      pkgs
      cfg
      zapret
      ;
  };
  inherit (zapretPackages)
    globalZapretPackage
    perAppZapretPackage
    globalZapretEnv
    perAppZapretEnv
    ;

  iptables = "${pkgs.iptables}/bin/iptables";

  zapretCommonPreStart = package: ''
    ${package}/opt/zapret/init.d/sysv/zapret stop || true

    ${lib.getExe' pkgs.kmod "modprobe"} xt_NFQUEUE 2>/dev/null || true
    ${lib.getExe' pkgs.kmod "modprobe"} xt_connbytes 2>/dev/null || true
    ${lib.getExe' pkgs.kmod "modprobe"} xt_multiport 2>/dev/null || true

    if ! ${pkgs.ipset}/bin/ipset list nozapret >/dev/null 2>&1; then
      ${pkgs.ipset}/bin/ipset create nozapret hash:net
    fi
  '';

  exemptStart = ''
    set -euo pipefail
  ''
  + lib.concatMapStrings (cidr: ''
    while ${iptables} -t mangle -D FORWARD -d ${cidr} -j RETURN 2>/dev/null; do :; done
    while ${iptables} -t mangle -D POSTROUTING -s ${cidr} -j RETURN 2>/dev/null; do :; done
    ${iptables} -t mangle -I FORWARD 1 -d ${cidr} -j RETURN
    ${iptables} -t mangle -I POSTROUTING 1 -s ${cidr} -j RETURN
  '') zapretCfg.cidrExemption.cidrs;

  exemptStop = ''
    set +e
  ''
  + lib.concatMapStrings (cidr: ''
    while ${iptables} -t mangle -D FORWARD -d ${cidr} -j RETURN 2>/dev/null; do :; done
    while ${iptables} -t mangle -D POSTROUTING -s ${cidr} -j RETURN 2>/dev/null; do :; done
  '') zapretCfg.cidrExemption.cidrs;
in
{
  assertions = zapretPackages.assertions;

  services.proxy-suite.internal.earlyPackages = (
    lib.optionals zapretGlobalEnabled [ globalZapretPackage ]
    ++ lib.optionals perAppZapretCfg.enable [ perAppZapretPackage ]
  );

  services.proxy-suite.internal.services.proxy-suite-zapret =
    lib.mkIf zapretGlobalEnabled
      (mkOneshotService {
        description = "zapret DPI bypass";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        conflicts = awgServiceNames;
        wantedBy = [ "multi-user.target" ];
        preStart = zapretCommonPreStart globalZapretPackage;
        runtimeDirectory = "proxy-suite-zapret";
        execStart = "${globalZapretPackage}/opt/zapret/init.d/sysv/zapret start";
        execStop = "${globalZapretPackage}/opt/zapret/init.d/sysv/zapret stop";
        extraServiceConfig = {
          ExecReload = "${globalZapretPackage}/opt/zapret/init.d/sysv/zapret restart";
          Environment = globalZapretEnv;
        };
      });

  services.proxy-suite.internal.services.proxy-suite-per-app-zapret =
    lib.mkIf perAppZapretCfg.enable
      (mkOneshotService {
        description = "proxy-suite per-app-routing zapret backend";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        conflicts = perAppConflicts ++ awgServiceNames;
        preStart = zapretCommonPreStart perAppZapretPackage;
        runtimeDirectory = "proxy-suite-per-app-zapret";
        execStart = "${perAppZapretPackage}/opt/zapret/init.d/sysv/zapret start";
        execStop = "${perAppZapretPackage}/opt/zapret/init.d/sysv/zapret stop";
        execStartPre = "${perAppZapretMarkUpScript}";
        execStopPost = "${perAppZapretMarkDownScript}";
        extraServiceConfig.Environment = perAppZapretEnv;
      });

  services.proxy-suite.internal.services.proxy-suite-zapret-vm-exempt =
    lib.mkIf (zapretGlobalEnabled && zapretCfg.cidrExemption.enable)
      (
        mkOneshotService {
          description = "Exempt CIDRs from zapret NFQUEUE";
          after = [ "proxy-suite-zapret.service" ];
          wants = [ "proxy-suite-zapret.service" ];
          conflicts = awgServiceNames;
          # zapret inserts its rules at the top (iptables -I): these are re-inserted after
          # every zapret start or restart, or they end up below its NFQUEUE jumps.
          wantedBy = [
            "multi-user.target"
            "proxy-suite-zapret.service"
          ];
          execStart = pkgs.writeShellScript "proxy-suite-zapret" exemptStart;
          execStop = pkgs.writeShellScript "proxy-suite-zapret" exemptStop;
        }
        // {
          partOf = [ "proxy-suite-zapret.service" ];
        }
      );
}
