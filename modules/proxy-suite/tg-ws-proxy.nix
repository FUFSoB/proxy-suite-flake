# Telegram MTProto WebSocket proxy service
{
  lib,
  pkgs,
  packages,
  cfg,
}:

let
  t = cfg.tgWsProxy;
  tgPkg = packages.tg-ws-proxy;
  ip = "${pkgs.iproute2}/bin/ip";

  transparentBypassEnabled =
    t.bypassTransparentProxy
    && cfg.singBox.enable
    && (cfg.singBox.tun.enable || cfg.singBox.tproxy.enable);
  bypassRulePriority = 8999;

  dcArgs = lib.concatMapStrings
    (id: " --dc-ip=${lib.escapeShellArg "${id}:${t.dcIps.${id}}"}")
    (builtins.attrNames t.dcIps);
  startScript = pkgs.writeShellScript "proxy-suite-tg-ws-proxy-start" ''
    exec ${tgPkg}/bin/tg-ws-proxy \
      --port=${toString t.port} \
      --host=${lib.escapeShellArg t.host} \
      ${
        if t.secretFile != null then
          "--secret-file=$CREDENTIALS_DIRECTORY/tg_ws_proxy_secret"
        else
          "--secret=${lib.escapeShellArg t.secret}"
      }${dcArgs}
  '';

  bypassUpScript = pkgs.writeShellScript "proxy-suite-tg-ws-proxy-bypass-up" ''
    set -euo pipefail

    add_bypass_rule() {
      local family="$1"
      while ${ip} "$family" rule del pref ${toString bypassRulePriority} fwmark ${toString t.routingMark} lookup main 2>/dev/null; do :; done
      ${ip} "$family" rule add pref ${toString bypassRulePriority} fwmark ${toString t.routingMark} lookup main 2>/dev/null || true
    }

    add_bypass_rule -4
    add_bypass_rule -6
  '';

  bypassDownScript = pkgs.writeShellScript "proxy-suite-tg-ws-proxy-bypass-down" ''
    set +e

    while ${ip} -4 rule del pref ${toString bypassRulePriority} fwmark ${toString t.routingMark} lookup main 2>/dev/null; do :; done
    while ${ip} -6 rule del pref ${toString bypassRulePriority} fwmark ${toString t.routingMark} lookup main 2>/dev/null; do :; done
  '';
in
{
  systemd.services.proxy-suite-tg-ws-proxy = {
    description = "Telegram MTProto WebSocket proxy";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${startScript}";
      LoadCredential = lib.optional (t.secretFile != null) "tg_ws_proxy_secret:${t.secretFile}";
      Restart = "on-failure";
      RestartSec = 5;
    }
    // lib.optionalAttrs transparentBypassEnabled {
      ExecStartPre = bypassUpScript;
      ExecStopPost = bypassDownScript;
      SocketMark = toString t.routingMark;
    };
  };
}
