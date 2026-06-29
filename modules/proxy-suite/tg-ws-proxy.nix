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
    t.bypassTransparentProxy && cfg.proxy.enable && (cfg.proxy.tun.enable || cfg.proxy.tproxy.enable);
  bypassRulePriority = 8999;

  mkValueArg = name: value: "    args+=(${name}=${lib.escapeShellArg value})\n";
  mkRawValueArg = name: value: "    args+=(${name}=${toString value})\n";
  mkFlagArg = condition: name: lib.optionalString condition "    args+=(${name})\n";
  mkOptionalValueArg =
    condition: name: value:
    lib.optionalString condition (mkValueArg name value);
  mkRepeatedValueArgs = name: values: lib.concatMapStrings (value: mkValueArg name value) values;
  dcArgs = lib.concatMapStrings (id: mkValueArg "--dc-ip" "${id}:${t.dcIps.${id}}") (
    builtins.attrNames t.dcIps
  );
  startScript = pkgs.writeShellScript "proxy-suite-tg-ws-proxy-start" ''
    args=(
      --port=${toString t.port}
      --host=${lib.escapeShellArg t.host}
    )
    ${
      if t.secretFile != null then
        ''args+=(--secret-file="$CREDENTIALS_DIRECTORY/tg_ws_proxy_secret")''
      else
        "args+=(--secret=${lib.escapeShellArg t.secret})"
    }
    ${dcArgs}${mkFlagArg t.verbose "--verbose"}${
      mkOptionalValueArg (t.logFile != null) "--log-file" t.logFile
    }${lib.optionalString (t.logFile != null) (mkRawValueArg "--log-max-mb" t.logMaxMb)}${
      lib.optionalString (t.logFile != null) (mkRawValueArg "--log-backups" t.logBackups)
    }${mkRawValueArg "--buf-kb" t.bufKb}${mkRawValueArg "--pool-size" t.poolSize}${mkRepeatedValueArgs "--cfproxy-domain" t.cfProxyDomains}${mkRepeatedValueArgs "--cfproxy-worker-domain" t.cfProxyWorkerDomains}${
      mkFlagArg (!t.cfProxyFallback) "--no-cfproxy"
    }${
      mkOptionalValueArg (t.fakeTlsDomain != null) "--fake-tls-domain" t.fakeTlsDomain
    }${mkFlagArg t.proxyProtocol "--proxy-protocol"}
    exec ${tgPkg}/bin/tg-ws-proxy "''${args[@]}"
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
