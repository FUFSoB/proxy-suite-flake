# Backend startup script derivations.
{ ctx }:

let
  inherit (ctx)
    lib
    pkgs
    proxyCfg
    perAppRoutingCfg
    userControlCfg
    userControlAllows
    globalTproxy
    xrayEnabled
    hybridEnabled
    pureXrayEnabled
    constants
    zapretCutoffProxyFallback
    jq
    singBox
    xray
    backendBin
    routeModeStateFile
    routeModeRulesFile
    xrayLoglevelFile
    runtimeProxychainsConfig
    localProxyAuth
    localProxyAuthEnabled
    localProxyAuthPasswordSource
    backendJqFilterFile
    hybridRuntimeHelpersBlock
    subscriptionCacheHelpersBlock
    mkOutboundScript
    tproxyFile
    tunFile
    perAppTunFile
    ;
  inherit (constants)
    autoProxyStateDir
    outboundTestPort
    xrayDnsBridgePorts
    xraySidecarPorts
    ;

  autoProxyRender = import ../autoproxy-render.nix {
    inherit pkgs;
    inherit (constants) serviceUser ifPrivileged;
  };
  runBackend = constants.runAsServiceUser pkgs constants.backendCaps;
  userControlGroup = lib.escapeShellArg userControlCfg.group;
  chgrp = "${pkgs.coreutils}/bin/chgrp";

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

  # Every route mode is the same four assignments over one jq program on the rule buckets.
  routeModeArms = [
    {
      mode = "blacklist";
      final = "proxy";
      dns = "remote";
      rules = ''
        .common
        + (.custom | map(.entries) | add // [])
        + .proxyPrimary
        + .direct
        + .safetyDirect
        ${routeModeBlacklistTail}
      '';
    }
    {
      mode = "whitelist";
      final = "direct";
      dns = "local";
      rules = ''
        .common
        + (.custom | map(.entries) | add // [])
        + .proxyPrimary
        + .direct
        + .safetyDirect
        ${routeModeBlacklistTail}
      '';
    }
    {
      # Only the proxy and block lists are kept: everything else follows the final action.
      mode = "all-proxy";
      final = "proxy";
      dns = "remote";
      clearDns = true;
      rules = ''
        .common
        + (.custom | map(select(.category == "proxy" or .category == "block") | .entries) | add // [])
        + .proxyPrimary
        + .safetyDirect
        ${routeModeBlacklistTail}
      '';
    }
    {
      mode = "all-bypass";
      final = "direct";
      dns = "local";
      clearDns = true;
      rules = ''
        .common
        + (.custom | map(select(.category == "block") | .entries) | add // [])
        + .safetyDirect
        + .block
      '';
    }
  ];

  # Written out line by line: the block lands inside a `case`, where the indentation of an
  # interpolated multi-line value would otherwise be lost.
  mkRouteModeArm =
    arm:
    lib.concatStringsSep "\n" (
      [
        "  ${arm.mode})"
        "    ROUTE_FINAL=\"${arm.final}\""
        "    DNS_FINAL=\"${arm.dns}\""
        "    ROUTE_MODE_ACTIVE=true"
      ]
      ++ lib.optional (arm.clearDns or false) "    CLEAR_DNS_RULES=true"
      ++ [ "    ROUTE_RULES_JSON=$(${jq} -c '" ]
      ++ map (line: if line == "" then "" else "      ${line}") (
        lib.splitString "\n" (lib.removeSuffix "\n" arm.rules)
      )
      ++ [
        "    ' \"${routeModeRulesFile}\")"
        "    ;;"
      ]
    );

  routeModeCaseBlock = ''
    if [ -r "$ROUTE_MODE_STATE_FILE" ]; then
      ROUTE_MODE="$(tr -d '\r\n[:space:]' < "$ROUTE_MODE_STATE_FILE" 2>/dev/null || true)"
    fi
    case "$ROUTE_MODE" in${lib.concatMapStrings (arm: "\n" + mkRouteModeArm arm) routeModeArms}
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
    ${constants.ifPrivileged ''${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "${runtimeProxychainsConfig}"''}
    chmod 640 "${runtimeProxychainsConfig}"
  '';

  mkStartScript =
    {
      runtimeDir,
      configFile,
      routingMark ? null,
      enableLocalProxyAuth ? false,
      xrayTunDnsRuntime ? false,
      xraySidecarPort ? xraySidecarPorts.socks,
      xrayDnsBridgePort ? xrayDnsBridgePorts.socks,
      enableAutoProxy ? false,
      enableOutboundTest ? false,
      enableZapretCutoff ? false,
      excludeServiceUserFromTun ? false,
    }:
    pkgs.writeShellScript "proxy-suite-core" ''
      set -euo pipefail
      RUNTIME_DIR="${runtimeDir}"
      ROUTE_MODE_STATE_FILE="${routeModeStateFile}"
      BACKEND_JQ_FILTER=${lib.escapeShellArg backendJqFilterFile}
      XRAY_LOGLEVEL=""
      XRAY_SINGLE_PROXY_TAG=""
      mkdir -p "$RUNTIME_DIR"
      OUTBOUNDS_JSON='[]'
      ROUTE_MODE=""
      ROUTE_FINAL=""
      DNS_FINAL=""
      ROUTE_RULES_JSON='[]'
      ROUTE_MODE_ACTIVE=false
      CLEAR_DNS_RULES=false
      ${hybridRuntimeHelpersBlock routingMark xraySidecarPort xrayDnsBridgePort}
      ${subscriptionCacheHelpersBlock}
      ${lib.optionalString enableLocalProxyAuth ''
        LOCAL_PROXY_PASSWORD="$(cat "${localProxyAuthPasswordSource}")"
        # The umask stays in the subshell: left set, it also narrowed everything
        # written below, and autoProxy's state.json is group-readable by design.
        (
          umask 077
          ${writeProxychainsConfigBlock}
        )
      ''}
      ${lib.optionalString xrayEnabled ''
        if [ -r "${xrayLoglevelFile}" ]; then
          XRAY_LOGLEVEL="$(tr -d '\r\n[:space:]' < "${xrayLoglevelFile}" 2>/dev/null || true)"
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
        # 0751: sing-box, running as ${constants.serviceUser}, reaches the rules/ inside;
        # 0771 with userControl's autoProxy scope, whose group queues learn requests there.
        install -d -m ${if userControlAllows "autoProxy" then "0771" else "0751"} "$AUTOPROXY_DIR"
        [ -s "$AUTOPROXY_DIR/state.json" ] || echo '{"domains":{},"hosts":{},"exits":{},"backlog":{}}' > "$AUTOPROXY_DIR/state.json"

        # direct is always exit 0; state is keyed by tag, so shifting indices are
        # harmless. Disabled outbounds are no exit: the prober drops what was learned
        # through them.
        PROBE_EXITS_JSON=$(${jq} -c \
          --argjson max ${toString proxyCfg.autoProxy.maxExits} \
          --argjson base ${toString proxyCfg.autoProxy.probeBasePort} \
          --argjson disabled "''${DISABLED_TAGS_JSON:-[]}" \
          --arg dir "$AUTOPROXY_DIR" '
          (["direct"] + map(select(. != "direct" and (. as $t | $disabled | index([$t]) | not))))[0:$max]
          | to_entries
          | map({i: .key, tag: .value, port: ($base + .key),
                 rule_set: ("autoproxy-" + (.key | tostring)),
                 path: ($dir + "/rules/rs-" + (.key | tostring) + ".json")})
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
        # XRay's urltest wrapper prefixes them all, and a
        # hybrid XRay outbound is a sing-box socks hop whose real server is the sidecar's.
        # A loopback hop (the WARP tunnel, XRay's SSH listener) has no server worth timing.
        ENDPOINTS_TMP="$RUNTIME_DIR/outbound-endpoints.json.tmp"
        ${jq} -c --argjson sidecar "''${XRAY_OUTBOUNDS_JSON:-[]}" '
          def endpoint:
            if .server then {server, port: .server_port}
            elif .settings.address then {server: .settings.address, port: .settings.port}
            elif .settings.vnext then {server: .settings.vnext[0].address, port: .settings.vnext[0].port}
            elif .settings.servers then {server: .settings.servers[0].address, port: .settings.servers[0].port}
            else null end;
          def udp: (.type // .protocol) as $t | (["hysteria", "hysteria2", "tuic"] | index($t) != null) or .quic? == true;
          ($sidecar | map({key: .tag, value: .}) | from_entries) as $real
          | [.[] | select(.type != "selector" and .type != "urltest")
             | (.tag | ltrimstr("proxy-suite-ob-")) as $tag
             | ($real[.tag] // .) | select(endpoint != null and (endpoint.server | test("^(127\\.|::1$|localhost$)") | not))
             | {key: $tag, value: (endpoint + {network: (if udp then "udp" else "tcp" end)})}]
          | from_entries
        ' <<< "$OUTBOUNDS_JSON" > "$ENDPOINTS_TMP"
        # Where each proxy server is: not credentials, but not for every local user either.
        ${
          if userControlCfg.enable || localProxyAuthEnabled then
            ''
              ${constants.ifPrivileged ''${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "$ENDPOINTS_TMP"''}
              chmod 640 "$ENDPOINTS_TMP"
            ''
          else
            ''chmod 600 "$ENDPOINTS_TMP"''
        }
        mv "$ENDPOINTS_TMP" "$RUNTIME_DIR/outbound-endpoints.json"

        # proxy-ctl's share links: the URL each outbound was given, and its backend JSON.
        # Credentials: root and the userControl group only.
        SHARE_TMP="$RUNTIME_DIR/outbound-share.json.tmp"
        (umask 077 && ${jq} -c --argjson sidecar "''${XRAY_OUTBOUNDS_JSON:-[]}" \
          --argjson urls "$OUTBOUND_URLS_JSON" --argjson subs "$SUBSCRIPTION_URLS_JSON" '
          ($sidecar | map({key: .tag, value: .}) | from_entries) as $real
          | {outbounds: ([.[] | select(.type != "selector" and .type != "urltest")
               | (.tag | ltrimstr("proxy-suite-ob-")) as $tag
               | {key: $tag, value: {url: $urls[$tag], outbound: (($real[$tag] // $real[.tag] // .) | .tag = $tag)}}]
               | from_entries),
             subscriptions: $subs}
        ' <<< "$OUTBOUNDS_JSON" > "$SHARE_TMP")
        ${lib.optionalString (userControlAllows "secrets") ''${chgrp} ${userControlGroup} "$SHARE_TMP"''}
        chmod ${if userControlAllows "secrets" then "640" else "600"} "$SHARE_TMP"
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
          ${jq} -n --argjson tags "$EXIT_TAGS_JSON" \
            --arg url ${lib.escapeShellArg proxyCfg.urlTest.url} '
            {port: ${toString outboundTestPort}, selector: "proxy-suite-test", url: $url,
             outbounds: ($tags | map({key: ., value: .}) | from_entries)}
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
          # The cutoff unit owns the directory's mode (the group asks for probes there).
          mkdir -p "$(dirname "$CUTOFF_RULE_SET")"
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
        --arg xray_single_proxy_tag "$XRAY_SINGLE_PROXY_TAG" \
        --argjson xray_selectable "$SELECTABLE_TAGS_JSON" \
        --argjson xray_tun_dns_runtime ${if xrayTunDnsRuntime then "true" else "false"} \
        -f "$BACKEND_JQ_FILTER" \
        "${configFile}" > "$RUNTIME_DIR/config.json"
      ${lib.optionalString excludeServiceUserFromTun ''
        # proxy-suite's own daemons (the inbound XRay, replies to its clients included)
        # stay out of the TUN; the uid is only known on this host.
        SERVICE_UID=$(${pkgs.coreutils}/bin/id -u ${constants.serviceUser})
        ${jq} --argjson uid "$SERVICE_UID" '(.inbounds[] | select(.type == "tun") | .exclude_uid) = [$uid]' \
          "$RUNTIME_DIR/config.json" > "$RUNTIME_DIR/config.json.next"
        mv "$RUNTIME_DIR/config.json.next" "$RUNTIME_DIR/config.json"
      ''}
      # Credentials, read by the backend running as ${constants.serviceUser}. With
      # userControl its group reads them too; a file has one group, so the daemon
      # reads as owner then.
      for backend_config in "$RUNTIME_DIR/config.json" "$RUNTIME_DIR/xray-sidecar.json"; do
        [ -e "$backend_config" ] || continue
        ${
          if userControlAllows "secrets" then
            ''
              ${pkgs.coreutils}/bin/chown ${constants.serviceUser}:${userControlGroup} "$backend_config"
              chmod 440 "$backend_config"
            ''
          else
            ''
              ${constants.ifPrivileged ''${chgrp} ${constants.serviceUser} "$backend_config"''}
              chmod 640 "$backend_config"
            ''
        }
      done
      FAKE_IP_CACHE=$(${jq} -r '.experimental.cache_file.path? // empty' "$RUNTIME_DIR/config.json")
      if [ -n "$FAKE_IP_CACHE" ]; then
        install -d -m 0700 ${constants.ifPrivileged "-o ${constants.serviceUser} -g ${constants.serviceUser} "}"$(dirname "$FAKE_IP_CACHE")"
      fi

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
    runtimeDir = "${constants.runtimeDir}/proxy-suite-socks";
    configFile = tproxyFile;
    # Rootless hosts cannot set SO_MARK, and have no TProxy rules to escape anyway.
    routingMark = if constants.privileged then globalTproxy.proxyMark else null;
    enableLocalProxyAuth = localProxyAuthEnabled;
    # TProxy takes the system resolver's own upstream queries too, so a proxy server's name
    # has to resolve inside XRay, as under the TUN.
    xrayTunDnsRuntime = pureXrayEnabled && globalTproxy.enable;
    xraySidecarPort = xraySidecarPorts.socks;
    xrayDnsBridgePort = xrayDnsBridgePorts.socks;
    # Only the socks unit: relayed traffic reaches it, and the prober needs one home.
    enableAutoProxy = proxyCfg.autoProxy.enable && !pureXrayEnabled;
    enableZapretCutoff = zapretCutoffProxyFallback && !pureXrayEnabled;
    enableOutboundTest = true;
  };

  startTun = mkStartScript {
    runtimeDir = "${constants.runtimeDir}/proxy-suite-tun";
    configFile = tunFile;
    routingMark = if pureXrayEnabled then globalTproxy.proxyMark else null;
    xrayTunDnsRuntime = pureXrayEnabled;
    xraySidecarPort = xraySidecarPorts.tun;
    xrayDnsBridgePort = xrayDnsBridgePorts.tun;
    # Pure XRay's TUN routes by ip rules instead: see xrayTunUpScript.
    excludeServiceUserFromTun = !pureXrayEnabled;
  };

  startPerAppTun = mkStartScript {
    runtimeDir = "${constants.runtimeDir}/proxy-suite-per-app-tun";
    configFile = perAppTunFile;
    routingMark = if xrayEnabled || globalTproxy.enable then globalTproxy.proxyMark else null;
    xrayTunDnsRuntime = pureXrayEnabled;
    xraySidecarPort = xraySidecarPorts.perAppTun;
    xrayDnsBridgePort = xrayDnsBridgePorts.perAppTun;
  };
in
{
  inherit startSocks startTun startPerAppTun;
}
