# Generates the sing-box startup scripts and subscription management scripts.
{
  lib,
  pkgs,
  singBoxCfg,
  appRoutingTun,
  jq,
  python3,
  singBox,
  parserScriptsPythonPath,
  buildOutboundPy,
  fetchSubscriptionPy,
  tproxyFile,
  tunFile,
  appTunFile,
}:

let
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
    ''
      # subscription: ${sub.tag}
      CACHE_DIR="/var/lib/proxy-suite/subscriptions"
      CACHE_FILE="$CACHE_DIR/${lib.escapeShellArg sub.tag}.json"
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
        ${lib.optionalString (routingMark != null) ''
        SUB_JSON=$(${jq} --argjson m ${toString routingMark} 'map(. + {routing_mark: $m})' <<< "$SUB_JSON")
        ''}OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
      fi
    '';

  # Shell code that builds all outbounds, then optionally adds a selector/urltest wrapper.
  mkOutboundScript =
    routingMark:
    let
      outboundBlocks =
        if singBoxCfg.selection == "first" && singBoxCfg.outbounds != [ ] then
          # Only the first static outbound, tagged "proxy" so sing-box routes to it.
          mkOutboundBlock (builtins.head singBoxCfg.outbounds) routingMark "proxy"
        else
          lib.concatMapStrings (ob: mkOutboundBlock ob routingMark ob.tag) singBoxCfg.outbounds;

      subscriptionBlocks =
        lib.concatMapStrings (sub: mkSubscriptionBlock sub routingMark) singBoxCfg.subscriptions;

      wrapperBlock =
        if singBoxCfg.selection == "first" then
          # When there are no static outbounds, subscription outbounds keep their
          # real tags. Rename the first one to "proxy" so routing rules resolve.
          lib.optionalString (singBoxCfg.outbounds == [ ] && singBoxCfg.subscriptions != [ ]) ''
            FIRST_TAG=$(${jq} -r 'if length > 0 then .[0].tag else "" end' <<< "$OUTBOUNDS_JSON")
            if [ -n "$FIRST_TAG" ]; then
              OUTBOUNDS_JSON=$(${jq} --arg t "$FIRST_TAG" \
                'map(if .tag == $t then .tag = "proxy" else . end)' <<< "$OUTBOUNDS_JSON")
            fi
          ''
        else if singBoxCfg.selection == "selector" then
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

  mkStartScript =
    {
      name,
      runtimeDir,
      configFile,
      routingMark ? null,
    }:
    pkgs.writeShellScript name ''
      set -euo pipefail
      RUNTIME_DIR="${runtimeDir}"
      mkdir -p "$RUNTIME_DIR"
      OUTBOUNDS_JSON='[]'

      ${mkOutboundScript routingMark}

      ${jq} --argjson obs "$OUTBOUNDS_JSON" \
        '.outbounds = $obs + .outbounds' \
        "${configFile}" > "$RUNTIME_DIR/config.json"

      exec ${singBox} run -c "$RUNTIME_DIR/config.json"
    '';

  startSocks = mkStartScript {
    name = "proxy-suite-start-socks";
    runtimeDir = "/run/proxy-suite-socks";
    configFile = tproxyFile;
    routingMark = singBoxCfg.proxyMark;
  };

  startTun = mkStartScript {
    name = "proxy-suite-start-tun";
    runtimeDir = "/run/proxy-suite-tun";
    configFile = tunFile;
    routingMark = null;
  };

  startAppTun = mkStartScript {
    name = "proxy-suite-start-app-tun";
    runtimeDir = "/run/proxy-suite-app-tun";
    configFile = appTunFile;
    # Only needed when TProxy mode is enabled; otherwise avoid tagging app TUN
    # proxy outbounds with a host-global mark.
    routingMark = if singBoxCfg.tproxy.enable then singBoxCfg.proxyMark else null;
  };

  # Shell code to fetch a single subscription into the cache (used in update service).
  mkSubscriptionFetchBlock =
    sub:
    ''
      if ${mkSubscriptionFetchCommand sub} > "$CACHE_DIR/${lib.escapeShellArg sub.tag}.json.tmp"; then
        mv "$CACHE_DIR/${lib.escapeShellArg sub.tag}.json.tmp" \
           "$CACHE_DIR/${lib.escapeShellArg sub.tag}.json"
        echo "Updated subscription: ${sub.tag}"
      else
        rm -f "$CACHE_DIR/${lib.escapeShellArg sub.tag}.json.tmp"
        echo "proxy-suite: failed to update subscription '${sub.tag}'" >&2
        FAILED=1
      fi
    '';

  subscriptionUpdateScript = pkgs.writeShellScript "proxy-suite-subscription-update" ''
    set -euo pipefail
    CACHE_DIR="/var/lib/proxy-suite/subscriptions"
    mkdir -p "$CACHE_DIR"
    FAILED=0

    ${lib.concatMapStrings mkSubscriptionFetchBlock singBoxCfg.subscriptions}

    if [ "$FAILED" -eq 0 ]; then
      systemctl restart proxy-suite-socks
      systemctl is-active --quiet proxy-suite-tun && systemctl restart proxy-suite-tun || true
    fi
    exit "$FAILED"
  '';

  hasSubscriptions = singBoxCfg.subscriptions != [ ];
  subscriptionTagsList = lib.concatStringsSep " " (map (sub: lib.escapeShellArg sub.tag) singBoxCfg.subscriptions);
in
{
  inherit startSocks startTun startAppTun;
  inherit subscriptionUpdateScript hasSubscriptions subscriptionTagsList;
}
