# Telegram MTProto WebSocket proxy service
{ lib, pkgs, cfg }:

let
  t = cfg.tgWsProxy;
  tgPkg = import ../../pkgs/tg-ws-proxy.nix { inherit pkgs; };

  dcArgs = lib.concatMapStrings (id: " --dc-ip=${id}:${t.dcIps.${id}}") (
    builtins.attrNames t.dcIps
  );
  secretArg =
    if t.secretFile != null then
      " --secret-file=%d/tg_ws_proxy_secret"
    else
      " --secret=${t.secret}";
in
{
  systemd.services.proxy-suite-tg-ws-proxy = {
    description = "Telegram MTProto WebSocket proxy";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${tgPkg}/bin/tg-ws-proxy --port=${toString t.port} --host=${t.host}${secretArg}${dcArgs}";
      LoadCredential = lib.optional (t.secretFile != null) "tg_ws_proxy_secret:${t.secretFile}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
