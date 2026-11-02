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
    perAppRefuseUnderGlobal
    daemonSandbox
    perAppZapretMarkUpScript
    perAppZapretMarkReloadScript
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
  ip6tables = "${pkgs.iptables}/bin/ip6tables";

  zapretCommonPreStart = package: ''
    ${package}/opt/zapret/init.d/sysv/zapret stop || true

    ${lib.getExe' pkgs.kmod "modprobe"} xt_NFQUEUE 2>/dev/null || true
    ${lib.getExe' pkgs.kmod "modprobe"} xt_connbytes 2>/dev/null || true
    ${lib.getExe' pkgs.kmod "modprobe"} xt_multiport 2>/dev/null || true

    if ! ${pkgs.ipset}/bin/ipset list nozapret >/dev/null 2>&1; then
      ${pkgs.ipset}/bin/ipset create nozapret hash:net
    fi
  '';

  # A firewall reload (a switch's) that flushed the whole ruleset took zapret's rules with it:
  # iptables-nft keeps them in nftables tables. The units' reload puts them back, and the
  # firewall's propagates to it (After= it, or the flush could come after). start_fw adds
  # only the rules that are missing (iptables -C first): a ruleset that kept them stays as
  # it is, and the daemons run on.
  startFirewall = package: "${package}/opt/zapret/init.d/sysv/zapret start_fw";

  # An IPv6 range to iptables failed the script (set -e), and every range after it with it.
  tablesFor = cidr: if lib.hasInfix ":" cidr then ip6tables else iptables;
  exemptStart = ''
    set -euo pipefail
  ''
  + lib.concatMapStrings (cidr: ''
    while ${tablesFor cidr} -t mangle -D FORWARD -d ${cidr} -j RETURN 2>/dev/null; do :; done
    while ${tablesFor cidr} -t mangle -D POSTROUTING -s ${cidr} -j RETURN 2>/dev/null; do :; done
    ${tablesFor cidr} -t mangle -I FORWARD 1 -d ${cidr} -j RETURN
    ${tablesFor cidr} -t mangle -I POSTROUTING 1 -s ${cidr} -j RETURN
  '') zapretCfg.cidrExemption.cidrs;

  exemptStartScript = pkgs.writeShellScript "proxy-suite-zapret" exemptStart;

  exemptStop = ''
    set +e
  ''
  + lib.concatMapStrings (cidr: ''
    while ${tablesFor cidr} -t mangle -D FORWARD -d ${cidr} -j RETURN 2>/dev/null; do :; done
    while ${tablesFor cidr} -t mangle -D POSTROUTING -s ${cidr} -j RETURN 2>/dev/null; do :; done
  '') zapretCfg.cidrExemption.cidrs;
in
{
  assertions = zapretPackages.assertions;

  services.proxy-suite.internal.earlyPackages = (
    lib.optionals zapretGlobalEnabled [ globalZapretPackage ]
    ++ lib.optionals perAppZapretCfg.enable [ perAppZapretPackage ]
  );

  services.proxy-suite.internal.services.proxy-suite-zapret = lib.mkIf zapretGlobalEnabled (
    mkOneshotService {
      description = "zapret DPI bypass";
      after = [
        "network-online.target"
        "nftables.service"
      ];
      wants = [ "network-online.target" ];
      conflicts = awgServiceNames;
      wantedBy = [ "multi-user.target" ];
      preStart = zapretCommonPreStart globalZapretPackage;
      runtimeDirectory = "proxy-suite-zapret";
      execStart = "${globalZapretPackage}/opt/zapret/init.d/sysv/zapret start";
      execStop = "${globalZapretPackage}/opt/zapret/init.d/sysv/zapret stop";
      extraServiceConfig = {
        ExecReload = startFirewall globalZapretPackage;
        Environment = globalZapretEnv;
      }
      // daemonSandbox;
    }
    // {
      unitConfig.ReloadPropagatedFrom = [ "nftables.service" ];
    }
  );

  services.proxy-suite.internal.services.proxy-suite-per-app-zapret =
    lib.mkIf perAppZapretCfg.enable
      (
        lib.mkMerge [
          (mkOneshotService {
            description = "proxy-suite per-app-routing zapret backend";
            after = [
              "network-online.target"
              "nftables.service"
              # Started and reloaded after the global instance: both insert into the same
              # mangle chains, and the global one's per-app bypass (a RETURN, which ends the
              # chain) above this one's queue rules would keep the apps' traffic from them.
              "proxy-suite-zapret.service"
            ];
            wants = [ "network-online.target" ];
            preStart = zapretCommonPreStart perAppZapretPackage;
            runtimeDirectory = "proxy-suite-per-app-zapret";
            execStart = "${perAppZapretPackage}/opt/zapret/init.d/sysv/zapret start";
            execStop = "${perAppZapretPackage}/opt/zapret/init.d/sysv/zapret stop";
            execStartPre = "${perAppZapretMarkUpScript}";
            execStopPost = "${perAppZapretMarkDownScript}";
            extraServiceConfig = {
              ExecReload = [
                "${perAppZapretMarkReloadScript}"
                (startFirewall perAppZapretPackage)
              ];
              Environment = perAppZapretEnv;
            }
            // daemonSandbox;
          })
          {
            # Ahead of everything, preStart's script among them (mkBefore there): under a global
            # mode nothing of it runs, not even the queue's firewall rules.
            serviceConfig.ExecStartPre = lib.mkOrder 400 [ perAppRefuseUnderGlobal ];
            # Its tables back after the firewall's flush (startFirewall).
            unitConfig.ReloadPropagatedFrom = [ "nftables.service" ];
          }
        ]
      );

  services.proxy-suite.internal.services.proxy-suite-zapret-vm-exempt =
    lib.mkIf (zapretGlobalEnabled && zapretCfg.cidrExemption.enable)
      (
        mkOneshotService {
          description = "Exempt CIDRs from zapret NFQUEUE";
          after = [
            "nftables.service"
            "proxy-suite-zapret.service"
          ];
          wants = [ "proxy-suite-zapret.service" ];
          conflicts = awgServiceNames;
          # zapret inserts its rules at the top (iptables -I): these are re-inserted after
          # every zapret start or restart, or they end up below its NFQUEUE jumps.
          wantedBy = [
            "multi-user.target"
            "proxy-suite-zapret.service"
          ];
          execStart = exemptStartScript;
          execStop = pkgs.writeShellScript "proxy-suite-zapret" exemptStop;
          # Back after a firewall reload's flush, above zapret's rules: this reload comes after
          # zapret's (After=), which puts those back.
          extraServiceConfig.ExecReload = exemptStartScript;
        }
        // {
          partOf = [ "proxy-suite-zapret.service" ];
          unitConfig.ReloadPropagatedFrom = [
            "nftables.service"
            "proxy-suite-zapret.service"
          ];
        }
      );
}
