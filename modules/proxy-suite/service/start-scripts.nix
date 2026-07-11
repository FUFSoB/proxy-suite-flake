# Backend startup script derivations.
{
  lib,
  pkgs,
  proxyCfg,
  perAppRoutingCfg,
  userControlCfg,
  globalTproxy,
  xrayEnabled,
  hybridEnabled,
  pureXrayEnabled,
  constants,
  jq,
  singBox,
  xray,
  backendBin,
  routeModeStateFile,
  routeModeRulesFile,
  xrayLoglevelFile,
  runtimeProxychainsConfig,
  localProxyAuth,
  localProxyAuthEnabled,
  localProxyAuthPasswordSource,
  backendJqFilterFile,
  hybridRuntimeHelpersBlock,
  subscriptionCacheHelpersBlock,
  mkOutboundScript,
  tproxyFile,
  tunFile,
  perAppTunFile,
}:

let
  inherit (constants)
    xrayDnsBridgePorts
    xraySidecarBasePorts
    ;

  routeModeBlacklistTail =
    if pureXrayEnabled then
      ''
        + .proxyGeo
        + .block
      ''
    else
      ''
        + .block
        + .proxyGeo
      '';

  routeModeCaseBlock = ''
    if [ -r "$ROUTE_MODE_STATE_FILE" ]; then
      ROUTE_MODE="$(tr -d '\r\n[:space:]' < "$ROUTE_MODE_STATE_FILE" 2>/dev/null || true)"
    fi
    case "$ROUTE_MODE" in
      blacklist)
        ROUTE_FINAL="proxy"
        DNS_FINAL="remote"
        ROUTE_MODE_ACTIVE=true
        ROUTE_RULES_JSON=$(${jq} -c '
          .common
          + (.custom | map(.entries) | add // [])
          + .proxyPrimary
          + .direct
          + .safetyDirect
          ${routeModeBlacklistTail}
        ' "${routeModeRulesFile}")
        ;;
      whitelist)
        ROUTE_FINAL="direct"
        DNS_FINAL="local"
        ROUTE_MODE_ACTIVE=true
        ROUTE_RULES_JSON=$(${jq} -c '
          .common
          + (.custom | map(.entries) | add // [])
          + .proxyPrimary
          + .direct
          + .safetyDirect
          ${routeModeBlacklistTail}
        ' "${routeModeRulesFile}")
        ;;
      all-proxy)
        ROUTE_FINAL="proxy"
        DNS_FINAL="remote"
        ROUTE_MODE_ACTIVE=true
        CLEAR_DNS_RULES=true
        ROUTE_RULES_JSON=$(${jq} -c '
          .common
          + (.custom | map(select(.category == "proxy" or .category == "block") | .entries) | add // [])
          + .proxyPrimary
          + .safetyDirect
          ${routeModeBlacklistTail}
        ' "${routeModeRulesFile}")
        ;;
      all-bypass)
        ROUTE_FINAL="direct"
        DNS_FINAL="local"
        ROUTE_MODE_ACTIVE=true
        CLEAR_DNS_RULES=true
        ROUTE_RULES_JSON=$(${jq} -c '
          .common
          + (.custom | map(select(.category == "block") | .entries) | add // [])
          + .safetyDirect
          + .block
        ' "${routeModeRulesFile}")
        ;;
      *)
        ROUTE_MODE=""
        ;;
    esac
  '';

  writeProxychainsConfigBlock = ''
    {
      printf '%s\n' 'strict_chain'
      ${lib.optionalString perAppRoutingCfg.proxychains.quiet "printf '%s\\n' 'quiet_mode'"}
      ${lib.optionalString perAppRoutingCfg.proxychains.proxyDns "printf '%s\\n' 'proxy_dns'"}
      printf '%s\n' 'tcp_read_time_out 15000'
      printf '%s\n' 'tcp_connect_time_out 8000'
      printf '\n%s\n' '[ProxyList]'
      printf 'socks5 %s %s %s %s\n' \
        ${lib.escapeShellArg proxyCfg.listenAddress} \
        ${lib.escapeShellArg (toString proxyCfg.port)} \
        ${lib.escapeShellArg localProxyAuth.username} \
        "$LOCAL_PROXY_PASSWORD"
    } > "${runtimeProxychainsConfig}"
    ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "${runtimeProxychainsConfig}"
    chmod 640 "${runtimeProxychainsConfig}"
  '';

  mkStartScript =
    {
      name,
      runtimeDir,
      configFile,
      routingMark ? null,
      enableLocalProxyAuth ? false,
      xrayTunEgressBinding ? false,
      xrayTunDnsRuntime ? false,
      xraySidecarBasePort ? xraySidecarBasePorts.socks,
      xrayDnsBridgePort ? xrayDnsBridgePorts.socks,
    }:
    pkgs.writeShellScript name ''
      set -euo pipefail
      RUNTIME_DIR="${runtimeDir}"
      ROUTE_MODE_STATE_FILE="${routeModeStateFile}"
      BACKEND_JQ_FILTER=${lib.escapeShellArg backendJqFilterFile}
      XRAY_LOGLEVEL=""
      XRAY_TUN_BIND_INTERFACE=""
      XRAY_SINGLE_PROXY_TAG=""
      mkdir -p "$RUNTIME_DIR"
      OUTBOUNDS_JSON='[]'
      ROUTE_MODE=""
      ROUTE_FINAL=""
      DNS_FINAL=""
      ROUTE_RULES_JSON='[]'
      ROUTE_MODE_ACTIVE=false
      CLEAR_DNS_RULES=false
      ${hybridRuntimeHelpersBlock routingMark xraySidecarBasePort xrayDnsBridgePort}
      ${subscriptionCacheHelpersBlock}
      ${lib.optionalString enableLocalProxyAuth ''
        umask 077
        LOCAL_PROXY_PASSWORD="$(cat "${localProxyAuthPasswordSource}")"
        ${writeProxychainsConfigBlock}
      ''}
      ${lib.optionalString xrayEnabled ''
        if [ -r "${xrayLoglevelFile}" ]; then
          XRAY_LOGLEVEL="$(tr -d '\r\n[:space:]' < "${xrayLoglevelFile}" 2>/dev/null || true)"
        fi
      ''}
      ${lib.optionalString xrayTunEgressBinding ''
        XRAY_TUN_BIND_INTERFACE="$(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 mark ${toString globalTproxy.proxyMark} 2>/dev/null | ${pkgs.gawk}/bin/awk '
          /dev/ {
            for (i = 1; i <= NF; i++) {
              if ($i == "dev" && i + 1 <= NF) {
                print $(i + 1)
                exit
              }
            }
          }
        ')"
        if [ -z "$XRAY_TUN_BIND_INTERFACE" ]; then
          echo "proxy-suite: could not determine the default uplink interface for XRay TUN" >&2
          exit 1
        fi
      ''}

      ${routeModeCaseBlock}

      ${mkOutboundScript routingMark}
      ${lib.optionalString hybridEnabled "_proxy_suite_write_xray_sidecar_config"}

      ${jq} \
        --argjson obs "$OUTBOUNDS_JSON" \
        --argjson auth_enabled ${if enableLocalProxyAuth then "true" else "false"} \
        --arg user ${if enableLocalProxyAuth then lib.escapeShellArg localProxyAuth.username else "''"} \
        --arg password ${if enableLocalProxyAuth then "\"$LOCAL_PROXY_PASSWORD\"" else "''"} \
        --argjson route_enabled "$ROUTE_MODE_ACTIVE" \
        --argjson route_rules "$ROUTE_RULES_JSON" \
        --arg route_final "$ROUTE_FINAL" \
        --arg dns_final "$DNS_FINAL" \
        --argjson clear_dns_rules "$CLEAR_DNS_RULES" \
        --arg xray_loglevel "$XRAY_LOGLEVEL" \
        --arg xray_bind_interface "$XRAY_TUN_BIND_INTERFACE" \
        --arg xray_single_proxy_tag "$XRAY_SINGLE_PROXY_TAG" \
        --argjson xray_tun_dns_runtime ${if xrayTunDnsRuntime then "true" else "false"} \
        --arg xray_dns_local_client ${lib.escapeShellArg proxyCfg.dns.local.address} \
        --arg xray_dns_remote_client ${lib.escapeShellArg proxyCfg.dns.remote.address} \
        -f "$BACKEND_JQ_FILTER" \
        "${configFile}" > "$RUNTIME_DIR/config.json"
      ${lib.optionalString enableLocalProxyAuth ''
        chmod 600 "$RUNTIME_DIR/config.json"
      ''}

      ${
        if hybridEnabled then
          ''
            if [ -s "$RUNTIME_DIR/xray-sidecar.json" ]; then
              XRAY_SIDECAR_PID=""
              _proxy_suite_cleanup_xray_sidecar() {
                if [ -n "$XRAY_SIDECAR_PID" ]; then
                  kill "$XRAY_SIDECAR_PID" 2>/dev/null || true
                  wait "$XRAY_SIDECAR_PID" 2>/dev/null || true
                fi
              }
              trap _proxy_suite_cleanup_xray_sidecar EXIT
              trap 'exit 143' INT TERM

              ${xray} run -c "$RUNTIME_DIR/xray-sidecar.json" &
              XRAY_SIDECAR_PID="$!"
              ${pkgs.coreutils}/bin/sleep 0.2
              if ! kill -0 "$XRAY_SIDECAR_PID" 2>/dev/null; then
                XRAY_SIDECAR_STATUS=1
                wait "$XRAY_SIDECAR_PID" || XRAY_SIDECAR_STATUS="$?"
                exit "$XRAY_SIDECAR_STATUS"
              fi

              ${singBox} run -c "$RUNTIME_DIR/config.json" &
              SING_BOX_PID="$!"
              SING_BOX_STATUS=0
              wait "$SING_BOX_PID" || SING_BOX_STATUS="$?"
              exit "$SING_BOX_STATUS"
            fi

            exec ${singBox} run -c "$RUNTIME_DIR/config.json"
          ''
        else
          ''
            exec ${backendBin} run -c "$RUNTIME_DIR/config.json"
          ''
      }
    '';

  startSocks = mkStartScript {
    name = "proxy-suite-start-socks";
    runtimeDir = "/run/proxy-suite-socks";
    configFile = tproxyFile;
    routingMark = globalTproxy.proxyMark;
    enableLocalProxyAuth = localProxyAuthEnabled;
    xraySidecarBasePort = xraySidecarBasePorts.socks;
    xrayDnsBridgePort = xrayDnsBridgePorts.socks;
  };

  startTun = mkStartScript {
    name = "proxy-suite-start-tun";
    runtimeDir = "/run/proxy-suite-tun";
    configFile = tunFile;
    routingMark = if pureXrayEnabled then globalTproxy.proxyMark else null;
    xrayTunEgressBinding = xrayEnabled;
    xrayTunDnsRuntime = pureXrayEnabled;
    xraySidecarBasePort = xraySidecarBasePorts.tun;
    xrayDnsBridgePort = xrayDnsBridgePorts.tun;
  };

  startPerAppTun = mkStartScript {
    name = "proxy-suite-start-per-app-tun";
    runtimeDir = "/run/proxy-suite-per-app-tun";
    configFile = perAppTunFile;
    routingMark = if xrayEnabled || globalTproxy.enable then globalTproxy.proxyMark else null;
    xrayTunEgressBinding = xrayEnabled;
    xrayTunDnsRuntime = pureXrayEnabled;
    xraySidecarBasePort = xraySidecarBasePorts.perAppTun;
    xrayDnsBridgePort = xrayDnsBridgePorts.perAppTun;
  };
in
{
  inherit startSocks startTun startPerAppTun;
}
