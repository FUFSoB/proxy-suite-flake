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
  nft = "${pkgs.nftables}/bin/nft";
  markTable = "proxy_suite_tg_ws_proxy";

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
  startScript = pkgs.writeShellScript "proxy-suite-tg-ws-proxy" ''
    args=(
      --port=${toString t.listener.port}
      --host=${lib.escapeShellArg t.listener.address}
    )
    ${
      if t.secretFile != null then
        ''args+=(--secret-file="$CREDENTIALS_DIRECTORY/tg_ws_proxy_secret")''
      else
        "args+=(--secret=${lib.escapeShellArg t.secret})"
    }
    ${dcArgs}${mkFlagArg t.log.verbose "--verbose"}${
      mkOptionalValueArg (t.log.file != null) "--log-file" t.log.file
    }${lib.optionalString (t.log.file != null) (mkRawValueArg "--log-max-mb" t.log.maxSizeMiB)}${
      lib.optionalString (t.log.file != null) (mkRawValueArg "--log-backups" t.log.keep)
    }${mkRawValueArg "--buf-kb" t.bufferKiB}${mkRawValueArg "--pool-size" t.poolSize}${mkRepeatedValueArgs "--cfproxy-domain" t.cloudflare.domains}${mkRepeatedValueArgs "--cfproxy-worker-domain" t.cloudflare.workerDomains}${
      mkFlagArg (!t.cloudflare.fallback) "--no-cfproxy"
    }${
      mkOptionalValueArg (t.fakeTlsDomain != null) "--fake-tls-domain" t.fakeTlsDomain
    }${mkFlagArg t.proxyProtocol "--proxy-protocol"}
    exec ${tgPkg}/bin/tg-ws-proxy "''${args[@]}"
  '';

  bypassUpScript = pkgs.writeShellScript "proxy-suite-tg-ws-proxy" ''
    set -euo pipefail

    add_bypass_rule() {
      local family="$1"
      while ${ip} "$family" rule del pref ${toString bypassRulePriority} fwmark ${toString t.fwmark} lookup main 2>/dev/null; do :; done
      ${ip} "$family" rule add pref ${toString bypassRulePriority} fwmark ${toString t.fwmark} lookup main 2>/dev/null || true
    }

    add_bypass_rule -4
    add_bypass_rule -6

    # The relay's own sockets carry the mark. By cgroup, which is resolved when the rule
    # loads: this runs again on every start. Ahead of the TProxy output chain.
    ${nft} delete table inet ${markTable} 2>/dev/null || true
    ${nft} -f - <<EOF
    table inet ${markTable} {
      chain output {
        type route hook output priority mangle - 1; policy accept;
        socket cgroupv2 level 2 "system.slice/proxy-suite-tg-ws-proxy.service" meta mark set ${toString t.fwmark}
      }
    }
    EOF
  '';

  bypassDownScript = pkgs.writeShellScript "proxy-suite-tg-ws-proxy" ''
    set +e

    while ${ip} -4 rule del pref ${toString bypassRulePriority} fwmark ${toString t.fwmark} lookup main 2>/dev/null; do :; done
    while ${ip} -6 rule del pref ${toString bypassRulePriority} fwmark ${toString t.fwmark} lookup main 2>/dev/null; do :; done
    ${nft} delete table inet ${markTable} 2>/dev/null
  '';
in
{
  systemd.services.proxy-suite-tg-ws-proxy = {
    description = "Telegram MTProto WebSocket proxy";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = startScript;
      LoadCredential = lib.optional (t.secretFile != null) "tg_ws_proxy_secret:${t.secretFile}";
      Restart = "on-failure";
      RestartSec = 5;
    }
    // lib.optionalAttrs transparentBypassEnabled {
      ExecStartPre = bypassUpScript;
      ExecStopPost = bypassDownScript;
    };
  };
}
