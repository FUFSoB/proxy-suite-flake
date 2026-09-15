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
  zapretCutoffProxyFallback,
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
    autoProxyStateDir
    outboundTestPort
    xrayDnsBridgePorts
    xraySidecarBasePorts
    ;

  autoProxyRender = import ../autoproxy-render.nix { inherit pkgs; };
  runBackend = constants.runAsServiceUser pkgs constants.backendCaps;

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
        ${lib.escapeShellArg proxyCfg.listener.address} \
        ${lib.escapeShellArg (toString proxyCfg.listener.port)} \
        ${lib.escapeShellArg localProxyAuth.username} \
        "$LOCAL_PROXY_PASSWORD"
    } > "${runtimeProxychainsConfig}"
    ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "${runtimeProxychainsConfig}"
    chmod 640 "${runtimeProxychainsConfig}"
  '';

  mkStartScript =
    {
      runtimeDir,
      configFile,
      routingMark ? null,
      enableLocalProxyAuth ? false,
      xrayTunEgressBinding ? false,
      xrayTunDnsRuntime ? false,
      xraySidecarBasePort ? xraySidecarBasePorts.socks,
      xrayDnsBridgePort ? xrayDnsBridgePorts.socks,
      enableAutoProxy ? false,
      enableOutboundTest ? false,
      enableZapretCutoff ? false,
    }:
    pkgs.writeShellScript "proxy-suite-core" ''
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

      # autoProxy: a loopback listener and a learned rule-set per exit, generated here
      # because subscription tags only exist at runtime.
      PROBE_INBOUNDS_JSON='[]'
      PROBE_PIN_RULES_JSON='[]'
      AUTOPROXY_RULE_SETS_JSON='[]'
      AUTOPROXY_RULES_JSON='[]'
      ${lib.optionalString enableAutoProxy ''
        AUTOPROXY_DIR=${lib.escapeShellArg autoProxyStateDir}
        # 0751: sing-box, running as ${constants.serviceUser}, reads the rule-sets inside.
        install -d -m 0751 "$AUTOPROXY_DIR"
        [ -s "$AUTOPROXY_DIR/state.json" ] || echo '{"domains":{},"hosts":{},"exits":{},"backlog":{}}' > "$AUTOPROXY_DIR/state.json"

        # direct is always exit 0; state is keyed by tag, so shifting indices are
        # harmless.
        PROBE_EXITS_JSON=$(${jq} -c \
          --argjson max ${toString proxyCfg.autoProxy.maxExits} \
          --argjson base ${toString proxyCfg.autoProxy.probeBasePort} \
          --arg dir "$AUTOPROXY_DIR" '
          (["direct"] + map(select(. != "direct")))[0:$max]
          | to_entries
          | map({i: .key, tag: .value, port: ($base + .key),
                 rule_set: ("autoproxy-" + (.key | tostring)),
                 path: ($dir + "/rs-" + (.key | tostring) + ".json")})
        ' <<< "$EXIT_TAGS_JSON")
        printf '%s\n' "$PROBE_EXITS_JSON" > "$RUNTIME_DIR/probe-exits.json"
        # proxy-ctl reads it unprivileged; it holds tags and loopback ports only.
        chmod 644 "$RUNTIME_DIR/probe-exits.json"
        ${autoProxyRender} "$RUNTIME_DIR/probe-exits.json" "$AUTOPROXY_DIR/state.json"

        PROBE_INBOUNDS_JSON=$(${jq} -c 'map({type: "mixed", tag: ("probe-in-" + (.i | tostring)),
          listen: "127.0.0.1", listen_port: .port})' <<< "$PROBE_EXITS_JSON")
        PROBE_PIN_RULES_JSON=$(${jq} -c 'map({inbound: ["probe-in-" + (.i | tostring)],
          outbound: .tag})' <<< "$PROBE_EXITS_JSON")
        AUTOPROXY_RULE_SETS_JSON=$(${jq} -c 'map({type: "local", format: "source",
          tag: .rule_set, path: .path})' <<< "$PROBE_EXITS_JSON")
        # all-bypass means everything direct; learned exits must not override it.
        if [ "$ROUTE_MODE" != all-bypass ]; then
          AUTOPROXY_RULES_JSON=$(${jq} -c 'map({rule_set: [.rule_set], outbound: .tag})' <<< "$PROBE_EXITS_JSON")
        fi
      ''}

      ${lib.optionalString enableOutboundTest ''
        # proxy-ctl proxy outbounds test. Servers for its ping, keyed by the user's tag:
        # the wrapper may have renamed one outbound "proxy" or prefixed them all, and a
        # hybrid XRay outbound is a sing-box socks hop whose real server is the sidecar's.
        # A loopback hop (the WARP tunnel, XRay's SSH listener) has no server worth timing.
        ENDPOINTS_TMP="$RUNTIME_DIR/outbound-endpoints.json.tmp"
        ${jq} -c --argjson sidecar "''${XRAY_OUTBOUNDS_JSON:-[]}" --arg collapsed "''${PROXY_TAG:-}" '
          def endpoint:
            if .server then {server, port: .server_port}
            elif .settings.address then {server: .settings.address, port: .settings.port}
            elif .settings.vnext then {server: .settings.vnext[0].address, port: .settings.vnext[0].port}
            elif .settings.servers then {server: .settings.servers[0].address, port: .settings.servers[0].port}
            else null end;
          def udp: (.type // .protocol) as $t | (["hysteria", "hysteria2", "tuic"] | index($t) != null) or .quic? == true;
          ($sidecar | map({key: .tag, value: .}) | from_entries) as $real
          | [.[] | select(.type != "selector" and .type != "urltest")
             | (.tag | ltrimstr("proxy-suite-ob-") | if . == "proxy" then $collapsed else . end) as $tag
             | ($real[.tag] // .) | select(endpoint != null and (endpoint.server | test("^(127\\.|::1$|localhost$)") | not))
             | {key: $tag, value: (endpoint + {network: (if udp then "udp" else "tcp" end)})}]
          | from_entries
        ' <<< "$OUTBOUNDS_JSON" > "$ENDPOINTS_TMP"
        # Where each proxy server is: not credentials, but not for every local user either.
        ${
          if userControlCfg.allow != [ ] || localProxyAuthEnabled then
            ''
              ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "$ENDPOINTS_TMP"
              chmod 640 "$ENDPOINTS_TMP"
            ''
          else
            ''chmod 600 "$ENDPOINTS_TMP"''
        }
        mv "$ENDPOINTS_TMP" "$RUNTIME_DIR/outbound-endpoints.json"

        # proxy-ctl's share links: the URL each outbound was given, and its backend JSON.
        # Credentials, so root only, whatever userControl allows.
        SHARE_TMP="$RUNTIME_DIR/outbound-share.json.tmp"
        (umask 077 && ${jq} -c --argjson sidecar "''${XRAY_OUTBOUNDS_JSON:-[]}" --arg collapsed "''${PROXY_TAG:-}" \
          --argjson urls "$OUTBOUND_URLS_JSON" --argjson subs "$SUBSCRIPTION_URLS_JSON" '
          ($sidecar | map({key: .tag, value: .}) | from_entries) as $real
          | {outbounds: ([.[] | select(.type != "selector" and .type != "urltest")
               | (.tag | ltrimstr("proxy-suite-ob-") | if . == "proxy" then $collapsed else . end) as $tag
               | {key: $tag, value: {url: $urls[$tag], outbound: (($real[$tag] // $real[.tag] // .) | .tag = $tag)}}]
               | from_entries),
             subscriptions: $subs}
        ' <<< "$OUTBOUNDS_JSON" > "$SHARE_TMP")
        chmod 600 "$SHARE_TMP"
        mv "$SHARE_TMP" "$RUNTIME_DIR/outbound-share.json"

        ${lib.optionalString (!pureXrayEnabled) ''
          # Delay and download: a loopback listener pinned to a selector over every real
          # exit, switched one outbound at a time through the Clash API.
          OUTBOUNDS_JSON=$(${jq} -c --argjson tags "$EXIT_TAGS_JSON" \
            '. + [{type: "selector", tag: "proxy-suite-test", outbounds: $tags}]' <<< "$OUTBOUNDS_JSON")
          PROBE_INBOUNDS_JSON=$(${jq} -c '. + [{type: "mixed", tag: "proxy-suite-test-in",
            listen: "127.0.0.1", listen_port: ${toString outboundTestPort}}]' <<< "$PROBE_INBOUNDS_JSON")
          PROBE_PIN_RULES_JSON=$(${jq} -c \
            '. + [{inbound: ["proxy-suite-test-in"], outbound: "proxy-suite-test"}]' <<< "$PROBE_PIN_RULES_JSON")
          ${jq} -n --argjson tags "$EXIT_TAGS_JSON" --arg collapsed "''${PROXY_TAG:-}" \
            --arg url ${lib.escapeShellArg proxyCfg.urlTest.url} '
            {port: ${toString outboundTestPort}, selector: "proxy-suite-test", url: $url,
             outbounds: ($tags | map({key: (if . == "proxy" then $collapsed else . end), value: .}) | from_entries)}
          ' > "$RUNTIME_DIR/outbound-test.json"
          # Tags and a loopback port only.
          chmod 644 "$RUNTIME_DIR/outbound-test.json"
        ''}
      ''}

      ${lib.optionalString enableZapretCutoff ''
        # zapret2's cutoff probe lists the prefixes of cut-off networks no whitelisted
        # name gets through; the proxy carries those. sing-box refuses a missing
        # rule-set path and reloads the file when the probe renames a new one in.
        if [ "$ROUTE_MODE" != all-bypass ]; then
          CUTOFF_RULE_SET=${lib.escapeShellArg "${constants.zapret2CutoffDir}/proxy.json"}
          install -d -m 0755 "$(dirname "$CUTOFF_RULE_SET")"
          [ -s "$CUTOFF_RULE_SET" ] || echo '{"version":1,"rules":[]}' > "$CUTOFF_RULE_SET"
          chmod 644 "$CUTOFF_RULE_SET"
          AUTOPROXY_RULE_SETS_JSON=$(${jq} -c --arg p "$CUTOFF_RULE_SET" \
            '. + [{type: "local", format: "source", tag: "zapret-cutoff", path: $p}]' <<< "$AUTOPROXY_RULE_SETS_JSON")
          AUTOPROXY_RULES_JSON=$(${jq} -c '. + [{rule_set: ["zapret-cutoff"], outbound: "proxy"}]' <<< "$AUTOPROXY_RULES_JSON")
        fi
      ''}

      ${jq} \
        --argjson obs "$OUTBOUNDS_JSON" \
        --argjson probe_inbounds "$PROBE_INBOUNDS_JSON" \
        --argjson probe_pin_rules "$PROBE_PIN_RULES_JSON" \
        --argjson autoproxy_rule_sets "$AUTOPROXY_RULE_SETS_JSON" \
        --argjson autoproxy_rules "$AUTOPROXY_RULES_JSON" \
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
      # The backend runs as ${constants.serviceUser}: its configs are group-readable.
      for backend_config in "$RUNTIME_DIR/config.json" "$RUNTIME_DIR/xray-sidecar.json"; do
        [ -e "$backend_config" ] || continue
        ${pkgs.coreutils}/bin/chgrp ${constants.serviceUser} "$backend_config"
        chmod ${if enableLocalProxyAuth then "640" else "g+r"} "$backend_config"
      done

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

              ${runBackend} ${xray} run -c "$RUNTIME_DIR/xray-sidecar.json" &
              XRAY_SIDECAR_PID="$!"
              ${pkgs.coreutils}/bin/sleep 0.2
              if ! kill -0 "$XRAY_SIDECAR_PID" 2>/dev/null; then
                XRAY_SIDECAR_STATUS=1
                wait "$XRAY_SIDECAR_PID" || XRAY_SIDECAR_STATUS="$?"
                exit "$XRAY_SIDECAR_STATUS"
              fi

              ${runBackend} ${singBox} run -c "$RUNTIME_DIR/config.json" &
              SING_BOX_PID="$!"
              # Either one going away breaks the outbounds: exit, and let systemd restart both.
              SING_BOX_STATUS=0
              wait -n "$XRAY_SIDECAR_PID" "$SING_BOX_PID" || SING_BOX_STATUS="$?"
              exit "$(( SING_BOX_STATUS == 0 ? 1 : SING_BOX_STATUS ))"
            fi

            exec ${runBackend} ${singBox} run -c "$RUNTIME_DIR/config.json"
          ''
        else
          ''
            exec ${runBackend} ${backendBin} run -c "$RUNTIME_DIR/config.json"
          ''
      }
    '';

  startSocks = mkStartScript {
    runtimeDir = "/run/proxy-suite-socks";
    configFile = tproxyFile;
    routingMark = globalTproxy.proxyMark;
    enableLocalProxyAuth = localProxyAuthEnabled;
    xraySidecarBasePort = xraySidecarBasePorts.socks;
    xrayDnsBridgePort = xrayDnsBridgePorts.socks;
    # Only the socks unit: relayed traffic reaches it, and the prober needs one home.
    enableAutoProxy = proxyCfg.autoProxy.enable && !pureXrayEnabled;
    enableZapretCutoff = zapretCutoffProxyFallback && !pureXrayEnabled;
    enableOutboundTest = true;
  };

  startTun = mkStartScript {
    runtimeDir = "/run/proxy-suite-tun";
    configFile = tunFile;
    routingMark = if pureXrayEnabled then globalTproxy.proxyMark else null;
    xrayTunEgressBinding = xrayEnabled;
    xrayTunDnsRuntime = pureXrayEnabled;
    xraySidecarBasePort = xraySidecarBasePorts.tun;
    xrayDnsBridgePort = xrayDnsBridgePorts.tun;
  };

  startPerAppTun = mkStartScript {
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
