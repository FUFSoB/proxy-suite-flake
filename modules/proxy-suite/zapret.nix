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
  perAppZapretCfg = zapretCfg.perApp;
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

  perAppZapretMarkUpScript = pkgs.writeShellScript "proxy-suite-per-app-zapret-mark-up" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_zapret_mark 2>/dev/null || true
    ${nft} -f ${perAppZapretRulesFile}
  '';

  perAppZapretMarkDownScript = pkgs.writeShellScript "proxy-suite-per-app-zapret-mark-down" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_zapret_mark 2>/dev/null || true
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

  environment.systemPackages = lib.mkBefore (
    lib.optionals zapretCfg.enable [ globalZapretPackage ]
    ++ lib.optionals perAppZapretCfg.enable [ perAppZapretPackage ]
  );

  systemd.services.zapret-discord-youtube = lib.mkIf zapretCfg.enable (mkOneshotService {
    description = "zapret DPI bypass";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
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

  systemd.services.proxy-suite-per-app-zapret = lib.mkIf perAppZapretCfg.enable (mkOneshotService {
    description = "proxy-suite per-app-routing zapret backend";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    conflicts = [
      "proxy-suite-tproxy.service"
      "proxy-suite-tun.service"
    ];
    preStart = zapretCommonPreStart perAppZapretPackage;
    runtimeDirectory = "proxy-suite-per-app-zapret";
    execStart = "${perAppZapretPackage}/opt/zapret/init.d/sysv/zapret start";
    execStop = "${perAppZapretPackage}/opt/zapret/init.d/sysv/zapret stop";
    execStartPre = "${perAppZapretMarkUpScript}";
    execStopPost = "${perAppZapretMarkDownScript}";
    extraServiceConfig.Environment = perAppZapretEnv;
  });

  systemd.services.proxy-suite-zapret-vm-exempt =
    lib.mkIf (zapretCfg.enable && zapretCfg.cidrExemption.enable)
      (mkOneshotService {
        description = "Exempt CIDRs from zapret NFQUEUE";
        after = [ "zapret-discord-youtube.service" ];
        wants = [ "zapret-discord-youtube.service" ];
        wantedBy = [ "multi-user.target" ];
        execStart = pkgs.writeShellScript "proxy-suite-zapret-vm-exempt-start" exemptStart;
        execStop = pkgs.writeShellScript "proxy-suite-zapret-vm-exempt-stop" exemptStop;
      });
}
