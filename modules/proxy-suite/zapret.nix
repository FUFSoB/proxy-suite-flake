# zapret DPI bypass configuration + optional CIDR exemption from NFQUEUE
{ lib, pkgs, cfg }:

let
  z = cfg.zapret;

  iptables = "${pkgs.iptables}/bin/iptables";

  exemptStart = lib.concatMapStrings (cidr: ''
    ${iptables} -t mangle -I FORWARD     1 -d ${cidr} -j RETURN
    ${iptables} -t mangle -I POSTROUTING 1 -s ${cidr} -j RETURN
  '') z.cidrExemption.cidrs;

  exemptStop = lib.concatMapStrings (cidr: ''
    ${iptables} -t mangle -D FORWARD     -d ${cidr} -j RETURN || true
    ${iptables} -t mangle -D POSTROUTING -s ${cidr} -j RETURN || true
  '') z.cidrExemption.cidrs;
in
{
  services.zapret-discord-youtube = {
    enable = true;
    configName = z.configName;
    gameFilter = z.gameFilter;
    listGeneral = z.listGeneral;
    listExclude = z.listExclude;
    ipsetAll = z.ipsetAll;
    ipsetExclude = z.ipsetExclude;
  };

  systemd.services.proxy-suite-zapret-vm-exempt = lib.mkIf z.cidrExemption.enable {
    description = "Exempt CIDRs from zapret NFQUEUE";
    after = [ "zapret-discord-youtube.service" ];
    wants = [ "zapret-discord-youtube.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "proxy-suite-zapret-vm-exempt-start" exemptStart;
      ExecStop = pkgs.writeShellScript "proxy-suite-zapret-vm-exempt-stop" exemptStop;
    };
  };
}
