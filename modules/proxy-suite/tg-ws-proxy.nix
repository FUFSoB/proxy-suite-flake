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
in
{
  systemd.services.proxy-suite-tg-ws-proxy = {
    description = "Telegram MTProto WebSocket proxy";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${startScript}";
      LoadCredential = lib.optional (t.secretFile != null) "tg_ws_proxy_secret:${t.secretFile}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
