# Generates the sing-box startup scripts and subscription management scripts.
{
  lib,
  pkgs,
  singBoxCfg,
  perAppRoutingCfg,
  userControlCfg,
  perAppRoutingTun,
  selectionMode,
  collapseNamedOutbounds,
  hasSubscriptions,
  jq,
  python3,
  singBox,
  parserScriptsPythonPath,
  buildOutboundPy,
  fetchSubscriptionPy,
  tproxyFile,
  tunFile,
  perAppTunFile,
  routeModeRulesFile,
}:

let
  globalTproxy = singBoxCfg.tproxy;
  localProxyAuth = singBoxCfg.auth;
  localProxyAuthEnabled =
    localProxyAuth.username != null
    && (localProxyAuth.password != null || localProxyAuth.passwordFile != null);
  localProxyAuthPasswordSource =
    if localProxyAuth.passwordFile != null then
      localProxyAuth.passwordFile
    else if localProxyAuth.password != null then
      pkgs.writeText "proxy-suite-local-proxy-password" localProxyAuth.password
    else
      null;
  subscriptionCacheDir = "/var/lib/proxy-suite/subscriptions";
  routeModeStateFile = "/run/proxy-suite/route-mode";
  runtimeProxychainsConfig = "/run/proxy-suite-socks/proxychains.conf";

  mkSubscriptionCacheFile = sub: "${subscriptionCacheDir}/${sub.tag}.json";

  mkSubscriptionUrlSource =
    sub:
    if sub.urlFile != null then
      sub.urlFile
    else
      pkgs.writeText "proxy-suite-sub-url-${sub.tag}" sub.url;

  mkSubscriptionFetchCommand =
    sub:
    let
      urlSource = mkSubscriptionUrlSource sub;
    in
    ''
      printf '%s' "$(cat "${urlSource}")" \
        | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${fetchSubscriptionPy} --tag-prefix ${lib.escapeShellArg sub.tag}
    '';

  # Build the shell code block for a single outbound entry.
  # tag overrides ob.tag (used in "first" mode to force tag = "proxy").
  # routingMark is null or an int; added to outbound JSON if set.
  mkOutboundBlock =
    ob: routingMark: tag:
    let
      markArg = lib.optionalString (routingMark != null) " --routing-mark ${toString routingMark}";
    in
    if ob.json != null then
      let
        outboundJson = builtins.toJSON (
          ob.json // { tag = tag; } // lib.optionalAttrs (routingMark != null) { routing_mark = routingMark; }
        );
        jsonFile = pkgs.writeText "proxy-suite-ob-${tag}.json" outboundJson;
      in
      ''
        # outbound: ${tag} (static json)
        OB_JSON=$(cat "${jsonFile}")
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      ''
    else
      let
        urlSource =
          if ob.urlFile != null then
            ob.urlFile
          else
            # Literal URL – write to nix store so the script can cat it.
            # Less secret than urlFile, but convenient for non-sensitive configs.
            pkgs.writeText "proxy-suite-url-${ob.tag}" ob.url;
      in
      ''
        # outbound: ${tag}
        URL=$(cat "${urlSource}")
        OB_JSON=$(printf '%s' "$URL" | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildOutboundPy} --tag ${lib.escapeShellArg tag}${markArg})
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      '';

  # Build the shell code block for a single subscription entry.
  # Fetches subscription into the cache on first run; subsequent starts use the cache.
  mkSubscriptionBlock =
    sub: routingMark:
    let
      cacheFile = mkSubscriptionCacheFile sub;
    in
    ''
      # subscription: ${sub.tag}
      CACHE_DIR="${subscriptionCacheDir}"
      CACHE_FILE="${cacheFile}"
      if [ ! -f "$CACHE_FILE" ]; then
        mkdir -p "$CACHE_DIR"
        if ${mkSubscriptionFetchCommand sub} > "$CACHE_FILE.tmp"; then
          mv "$CACHE_FILE.tmp" "$CACHE_FILE"
        else
          rm -f "$CACHE_FILE.tmp"
          echo "proxy-suite: warning: could not fetch subscription '${sub.tag}'" >&2
        fi
      fi
      if [ -f "$CACHE_FILE" ]; then
        SUB_JSON=$(cat "$CACHE_FILE")
        ${
          lib.optionalString (routingMark != null) ''
            SUB_JSON=$(${jq} --argjson m ${toString routingMark} 'map(. + {routing_mark: $m})' <<< "$SUB_JSON")
          ''
        }OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
      fi
    '';

  # Shell code that builds all outbounds, then optionally adds a selector/urltest wrapper.
  mkOutboundScript =
    routingMark:
    let
      outboundBlocks =
        if collapseNamedOutbounds && singBoxCfg.outbounds != [ ] then
          # Only the first static outbound, tagged "proxy" so sing-box routes to it.
          mkOutboundBlock (builtins.head singBoxCfg.outbounds) routingMark "proxy"
        else
          lib.concatMapStrings (ob: mkOutboundBlock ob routingMark ob.tag) singBoxCfg.outbounds;

      subscriptionBlocks = lib.concatMapStrings (
        sub: mkSubscriptionBlock sub routingMark
      ) singBoxCfg.subscriptions;

      wrapperBlock =
        if collapseNamedOutbounds then
          # When there are no static outbounds, subscription outbounds keep their
          # real tags. Rename the first one to "proxy" so routing rules resolve.
          lib.optionalString (singBoxCfg.outbounds == [ ] && singBoxCfg.subscriptions != [ ]) ''
            FIRST_TAG=$(${jq} -r 'if length > 0 then .[0].tag else "" end' <<< "$OUTBOUNDS_JSON")
            if [ -n "$FIRST_TAG" ]; then
              OUTBOUNDS_JSON=$(${jq} --arg t "$FIRST_TAG" \
                'map(if .tag == $t then .tag = "proxy" else . end)' <<< "$OUTBOUNDS_JSON")
            fi
          ''
        else if selectionMode == "selector" then
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            FIRST=$(${jq} -r '.[0].tag' <<< "$OUTBOUNDS_JSON")
            WRAPPER=$(${jq} -n \
              --argjson tags "$TAGS" \
              --arg default "$FIRST" \
              '{type:"selector",tag:"proxy",outbounds:$tags,default:$default}')
            OUTBOUNDS_JSON=$(${jq} --argjson w "$WRAPPER" '[$w] + .' <<< "$OUTBOUNDS_JSON")
          ''
        else
          # urltest
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            WRAPPER=$(${jq} -n \
              --argjson tags "$TAGS" \
              --arg url ${lib.escapeShellArg singBoxCfg.urlTest.url} \
              --arg interval ${lib.escapeShellArg singBoxCfg.urlTest.interval} \
              --argjson tolerance ${toString singBoxCfg.urlTest.tolerance} \
              '{type:"urltest",tag:"proxy",outbounds:$tags,url:$url,interval:$interval,tolerance:$tolerance}')
            OUTBOUNDS_JSON=$(${jq} --argjson w "$WRAPPER" '[$w] + .' <<< "$OUTBOUNDS_JSON")
          '';
    in
    outboundBlocks + subscriptionBlocks + wrapperBlock;

  writeProxychainsConfigBlock = ''
    {
      printf '%s\n' 'strict_chain'
      ${lib.optionalString perAppRoutingCfg.proxychains.quiet "printf '%s\\n' 'quiet_mode'"}
      ${lib.optionalString perAppRoutingCfg.proxychains.proxyDns "printf '%s\\n' 'proxy_dns'"}
      printf '%s\n' 'tcp_read_time_out 15000'
      printf '%s\n' 'tcp_connect_time_out 8000'
      printf '\n%s\n' '[ProxyList]'
      printf 'socks5 %s %s %s %s\n' \
        ${lib.escapeShellArg singBoxCfg.listenAddress} \
        ${lib.escapeShellArg (toString singBoxCfg.port)} \
        ${lib.escapeShellArg localProxyAuth.username} \
        "$LOCAL_PROXY_PASSWORD"
    } > "${runtimeProxychainsConfig}"
    ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "${runtimeProxychainsConfig}"
    chmod 640 "${runtimeProxychainsConfig}"
  '';

  modeBaseline = if singBoxCfg.proxyByDefault then "blacklist" else "whitelist";

  mkStartScript =
    {
      name,
      runtimeDir,
      configFile,
      routingMark ? null,
      enableLocalProxyAuth ? false,
    }:
    pkgs.writeShellScript name ''
      set -euo pipefail
      RUNTIME_DIR="${runtimeDir}"
      ROUTE_MODE_STATE_FILE="${routeModeStateFile}"
      mkdir -p "$RUNTIME_DIR"
      OUTBOUNDS_JSON='[]'
      ROUTE_MODE=""
      ROUTE_FINAL=""
      DNS_FINAL=""
      ROUTE_RULES_JSON=""
      CLEAR_DNS_RULES=0
      ${lib.optionalString enableLocalProxyAuth ''
        umask 077
        LOCAL_PROXY_PASSWORD="$(cat "${localProxyAuthPasswordSource}")"
        ${writeProxychainsConfigBlock}
      ''}

      if [ -r "$ROUTE_MODE_STATE_FILE" ]; then
        ROUTE_MODE="$(tr -d '\r\n[:space:]' < "$ROUTE_MODE_STATE_FILE" 2>/dev/null || true)"
      fi
      case "$ROUTE_MODE" in
        blacklist)
          ROUTE_FINAL="proxy"
          DNS_FINAL="remote"
          ROUTE_RULES_JSON=$(${jq} -c '
            .common
            + (.custom | map(.entries) | add // [])
            + .proxyPrimary
            + .direct
            + .safetyDirect
            + .block
            + .proxyGeo
          ' "${routeModeRulesFile}")
          ;;
        whitelist)
          ROUTE_FINAL="direct"
          DNS_FINAL="local"
          ROUTE_RULES_JSON=$(${jq} -c '
            .common
            + (.custom | map(.entries) | add // [])
            + .proxyPrimary
            + .direct
            + .safetyDirect
            + .block
            + .proxyGeo
          ' "${routeModeRulesFile}")
          ;;
        all-proxy)
          ROUTE_FINAL="proxy"
          DNS_FINAL="remote"
          CLEAR_DNS_RULES=1
          ROUTE_RULES_JSON=$(${jq} -c '
            .common
            + (.custom | map(select(.category == "proxy" or .category == "block") | .entries) | add // [])
            + .proxyPrimary
            + .safetyDirect
            + .block
            + .proxyGeo
          ' "${routeModeRulesFile}")
          ;;
        all-bypass)
          ROUTE_FINAL="direct"
          DNS_FINAL="local"
          CLEAR_DNS_RULES=1
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

      ${mkOutboundScript routingMark}

      ${
        if enableLocalProxyAuth then
          ''
            if [ -n "$ROUTE_MODE" ]; then
              if [ "$CLEAR_DNS_RULES" -eq 1 ]; then
                ${jq} \
                  --argjson obs "$OUTBOUNDS_JSON" \
                  --arg user ${lib.escapeShellArg localProxyAuth.username} \
                  --arg password "$LOCAL_PROXY_PASSWORD" \
                  --argjson route_rules "$ROUTE_RULES_JSON" \
                  --arg route_final "$ROUTE_FINAL" \
                  --arg dns_final "$DNS_FINAL" \
                  '.outbounds = $obs + .outbounds
                    | (.inbounds[] | select(.type == "mixed" and .tag == "mixed-in") | .users) = [{username:$user,password:$password}]
                    | .route.rules = $route_rules
                    | .route.final = $route_final
                    | .dns.rules = []
                    | .dns.final = $dns_final' \
                  "${configFile}" > "$RUNTIME_DIR/config.json"
              else
                ${jq} \
                  --argjson obs "$OUTBOUNDS_JSON" \
                  --arg user ${lib.escapeShellArg localProxyAuth.username} \
                  --arg password "$LOCAL_PROXY_PASSWORD" \
                  --argjson route_rules "$ROUTE_RULES_JSON" \
                  --arg route_final "$ROUTE_FINAL" \
                  --arg dns_final "$DNS_FINAL" \
                  '.outbounds = $obs + .outbounds
                    | (.inbounds[] | select(.type == "mixed" and .tag == "mixed-in") | .users) = [{username:$user,password:$password}]
                    | .route.rules = $route_rules
                    | .route.final = $route_final
                    | .dns.final = $dns_final' \
                  "${configFile}" > "$RUNTIME_DIR/config.json"
              fi
            else
              ${jq} \
                --argjson obs "$OUTBOUNDS_JSON" \
                --arg user ${lib.escapeShellArg localProxyAuth.username} \
                --arg password "$LOCAL_PROXY_PASSWORD" \
                '.outbounds = $obs + .outbounds
                  | (.inbounds[] | select(.type == "mixed" and .tag == "mixed-in") | .users) = [{username:$user,password:$password}]' \
                "${configFile}" > "$RUNTIME_DIR/config.json"
            fi
            chmod 600 "$RUNTIME_DIR/config.json"
          ''
        else
          ''
            if [ -n "$ROUTE_MODE" ]; then
              if [ "$CLEAR_DNS_RULES" -eq 1 ]; then
                ${jq} \
                  --argjson obs "$OUTBOUNDS_JSON" \
                  --argjson route_rules "$ROUTE_RULES_JSON" \
                  --arg route_final "$ROUTE_FINAL" \
                  --arg dns_final "$DNS_FINAL" \
                  '.outbounds = $obs + .outbounds
                    | .route.rules = $route_rules
                    | .route.final = $route_final
                    | .dns.rules = []
                    | .dns.final = $dns_final' \
                  "${configFile}" > "$RUNTIME_DIR/config.json"
              else
                ${jq} \
                  --argjson obs "$OUTBOUNDS_JSON" \
                  --argjson route_rules "$ROUTE_RULES_JSON" \
                  --arg route_final "$ROUTE_FINAL" \
                  --arg dns_final "$DNS_FINAL" \
                  '.outbounds = $obs + .outbounds
                    | .route.rules = $route_rules
                    | .route.final = $route_final
                    | .dns.final = $dns_final' \
                  "${configFile}" > "$RUNTIME_DIR/config.json"
              fi
            else
              ${jq} --argjson obs "$OUTBOUNDS_JSON" \
                '.outbounds = $obs + .outbounds' \
                "${configFile}" > "$RUNTIME_DIR/config.json"
            fi
          ''
      }

      exec ${singBox} run -c "$RUNTIME_DIR/config.json"
    '';

  startSocks = mkStartScript {
    name = "proxy-suite-start-socks";
    runtimeDir = "/run/proxy-suite-socks";
    configFile = tproxyFile;
    routingMark = globalTproxy.proxyMark;
    enableLocalProxyAuth = localProxyAuthEnabled;
  };

  startTun = mkStartScript {
    name = "proxy-suite-start-tun";
    runtimeDir = "/run/proxy-suite-tun";
    configFile = tunFile;
    routingMark = null;
  };

  startPerAppTun = mkStartScript {
    name = "proxy-suite-start-per-app-tun";
    runtimeDir = "/run/proxy-suite-per-app-tun";
    configFile = perAppTunFile;
    # Only needed when TProxy mode is enabled; otherwise avoid tagging app TUN
    # proxy outbounds with a host-global mark.
    routingMark = if globalTproxy.enable then globalTproxy.proxyMark else null;
  };

  # Shell code to fetch a single subscription into the cache (used in update service).
  mkSubscriptionFetchBlock =
    sub:
    let
      cacheFile = mkSubscriptionCacheFile sub;
    in
    ''
      if ${mkSubscriptionFetchCommand sub} > "${cacheFile}.tmp"; then
        mv "${cacheFile}.tmp" "${cacheFile}"
        echo "Updated subscription: ${sub.tag}"
      else
        rm -f "${cacheFile}.tmp"
        echo "proxy-suite: failed to update subscription '${sub.tag}'" >&2
        FAILED=1
      fi
    '';

  subscriptionUpdateScript = pkgs.writeShellScript "proxy-suite-subscription-update" ''
    set -euo pipefail
    CACHE_DIR="${subscriptionCacheDir}"
    mkdir -p "$CACHE_DIR"
    FAILED=0
    SOCKS_WAS_ACTIVE=0
    TUN_WAS_ACTIVE=0
    PER_APP_TUN_WAS_ACTIVE=0

    systemctl is-active --quiet proxy-suite-socks && SOCKS_WAS_ACTIVE=1 || true
    systemctl is-active --quiet proxy-suite-tun && TUN_WAS_ACTIVE=1 || true
    systemctl is-active --quiet proxy-suite-per-app-tun && PER_APP_TUN_WAS_ACTIVE=1 || true

    ${lib.concatMapStrings mkSubscriptionFetchBlock singBoxCfg.subscriptions}

    if [ "$FAILED" -eq 0 ]; then
      if [ "$SOCKS_WAS_ACTIVE" -eq 1 ]; then
        systemctl restart proxy-suite-socks
      fi
      if [ "$TUN_WAS_ACTIVE" -eq 1 ]; then
        systemctl restart proxy-suite-tun
      fi
      if [ "$PER_APP_TUN_WAS_ACTIVE" -eq 1 ]; then
        systemctl restart proxy-suite-per-app-tun
      fi
    fi
    exit "$FAILED"
  '';

  setRouteModeScript = pkgs.writeShellScript "proxy-suite-set-route-mode" ''
    set -euo pipefail
    mode="''${1:-}"

    case "$mode" in
      default)
        ;;
      whitelist)
        ;;
      blacklist)
        ;;
      all-proxy)
        ;;
      all-bypass)
        ;;
      *)
        echo "proxy-suite: route mode must be default, whitelist, blacklist, all-proxy, or all-bypass" >&2
        exit 1
        ;;
    esac

    mkdir -p "$(dirname "${routeModeStateFile}")"
    if [ "$mode" = "default" ]; then
      rm -f "${routeModeStateFile}"
    else
      printf '%s\n' "$mode" > "${routeModeStateFile}"
    fi

    SOCKS_WAS_ACTIVE=0
    TUN_WAS_ACTIVE=0
    PER_APP_TUN_WAS_ACTIVE=0

    systemctl is-active --quiet proxy-suite-socks && SOCKS_WAS_ACTIVE=1 || true
    systemctl is-active --quiet proxy-suite-tun && TUN_WAS_ACTIVE=1 || true
    systemctl is-active --quiet proxy-suite-per-app-tun && PER_APP_TUN_WAS_ACTIVE=1 || true

    if [ "$SOCKS_WAS_ACTIVE" -eq 1 ]; then
      systemctl restart proxy-suite-socks
    fi
    if [ "$TUN_WAS_ACTIVE" -eq 1 ]; then
      systemctl restart proxy-suite-tun
    fi
    if [ "$PER_APP_TUN_WAS_ACTIVE" -eq 1 ]; then
      systemctl restart proxy-suite-per-app-tun
    fi
  '';

  subscriptionTagsFile = pkgs.writeText "proxy-suite-subscription-tags.json" (
    builtins.toJSON (map (sub: sub.tag) singBoxCfg.subscriptions)
  );
in
{
  inherit startSocks startTun startPerAppTun;
  inherit
    routeModeStateFile
    setRouteModeScript
    subscriptionUpdateScript
    hasSubscriptions
    subscriptionTagsFile
    runtimeProxychainsConfig
    ;
}
