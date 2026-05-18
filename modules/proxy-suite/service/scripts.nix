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
  systemctl = "${pkgs.systemd}/bin/systemctl";
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

  subscriptionCacheHelpersBlock = lib.optionalString hasSubscriptions ''
    _proxy_suite_valid_subscription_cache() {
      [ -s "$1" ] && ${jq} -e 'type == "array"' "$1" >/dev/null 2>&1
    }

    _proxy_suite_commit_subscription_cache() {
      local tmp="$1" target="$2" tag="$3"
      if _proxy_suite_valid_subscription_cache "$tmp"; then
        mv "$tmp" "$target"
        return 0
      fi
      rm -f "$tmp"
      echo "proxy-suite: warning: subscription '$tag' produced an invalid cache; ignoring it" >&2
      return 1
    }

    _proxy_suite_drop_invalid_subscription_cache() {
      local target="$1" tag="$2"
      if [ -f "$target" ] && ! _proxy_suite_valid_subscription_cache "$target"; then
        rm -f "$target"
        echo "proxy-suite: warning: removed invalid subscription cache for '$tag'" >&2
      fi
    }
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
      _proxy_suite_drop_invalid_subscription_cache "$CACHE_FILE" ${lib.escapeShellArg sub.tag}
      if [ ! -f "$CACHE_FILE" ]; then
        mkdir -p "$CACHE_DIR"
        if ${mkSubscriptionFetchCommand sub} > "$CACHE_FILE.tmp"; then
          _proxy_suite_commit_subscription_cache "$CACHE_FILE.tmp" "$CACHE_FILE" ${lib.escapeShellArg sub.tag} || true
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

      requireOutboundsBlock = ''
        if [ "$(${jq} 'length' <<< "$OUTBOUNDS_JSON")" -eq 0 ]; then
          echo "proxy-suite: no proxy outbounds are available; check static outbound definitions and subscription caches" >&2
          exit 1
        fi
      '';

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
    outboundBlocks + subscriptionBlocks + requireOutboundsBlock + wrapperBlock;

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

  restartActiveConfigConsumersBlock = lib.concatMapStrings (svc: ''
    if ${systemctl} is-active --quiet ${svc}; then
      ${systemctl} restart ${svc}
    fi
  '') [
    "proxy-suite-socks"
    "proxy-suite-tun"
    "proxy-suite-per-app-tun"
  ];

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
      ROUTE_RULES_JSON='[]'
      ROUTE_MODE_ACTIVE=false
      CLEAR_DNS_RULES=false
      ${subscriptionCacheHelpersBlock}
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
          ROUTE_MODE_ACTIVE=true
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
          ROUTE_MODE_ACTIVE=true
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
          ROUTE_MODE_ACTIVE=true
          CLEAR_DNS_RULES=true
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

      ${mkOutboundScript routingMark}

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
        '.outbounds = $obs + .outbounds
          | if $auth_enabled then
              (.inbounds[] | select(.type == "mixed" and .tag == "mixed-in") | .users) = [{username:$user,password:$password}]
            else . end
          | if $route_enabled then
              .route.rules = $route_rules
              | .route.final = $route_final
              | .dns.final = $dns_final
              | if $clear_dns_rules then .dns.rules = [] else . end
            else . end' \
        "${configFile}" > "$RUNTIME_DIR/config.json"
      ${lib.optionalString enableLocalProxyAuth ''
        chmod 600 "$RUNTIME_DIR/config.json"
      ''}

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
        if _proxy_suite_commit_subscription_cache "${cacheFile}.tmp" "${cacheFile}" ${lib.escapeShellArg sub.tag}; then
          echo "Updated subscription: ${sub.tag}"
        else
          FAILED=1
        fi
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
    ${subscriptionCacheHelpersBlock}
    ${lib.concatMapStrings mkSubscriptionFetchBlock singBoxCfg.subscriptions}

    if [ "$FAILED" -eq 0 ]; then
      ${restartActiveConfigConsumersBlock}
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

    ${restartActiveConfigConsumersBlock}
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
