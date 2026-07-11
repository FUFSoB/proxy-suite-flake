# Outbound construction script fragments for backend startup scripts.
{
  lib,
  pkgs,
  singBoxCfg,
  proxyCfg,
  pureXrayEnabled,
  hybridEnabled,
  collapseNamedOutbounds,
  selectionMode,
  backend,
  backendArg,
  xraySidecarRoutingMark,
  jq,
  python3,
  parserScriptsPythonPath,
  buildOutboundPy,
  mkSubscriptionBlock,
}:

let
  rawOutboundJson =
    ob: tag: routingMark:
    let
      backendRaw =
        if pureXrayEnabled then
          ob.xrayJson
        else if ob.singBoxJson != null then
          ob.singBoxJson
        else
          ob.json;
      markAttrs =
        if routingMark == null then
          { }
        else if pureXrayEnabled then
          { streamSettings.sockopt.mark = routingMark; }
        else
          { routing_mark = routingMark; };
      taggedRaw = backendRaw // {
        inherit tag;
      };
    in
    if pureXrayEnabled then lib.recursiveUpdate taggedRaw markAttrs else taggedRaw // markAttrs;

  mkOutboundBlock =
    ob: routingMark: tag:
    let
      backendRaw =
        if pureXrayEnabled then
          ob.xrayJson
        else if ob.singBoxJson != null then
          ob.singBoxJson
        else
          ob.json;
    in
    if backendRaw != null then
      let
        outboundJson = builtins.toJSON (rawOutboundJson ob tag routingMark);
        jsonFile = pkgs.writeText "proxy-suite-ob-${tag}.json" outboundJson;
      in
      ''
        # outbound: ${tag} (static ${backend} json)
        OB_JSON=$(cat "${jsonFile}")
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      ''
    else
      let
        urlSource =
          if ob.urlFile != null then ob.urlFile else pkgs.writeText "proxy-suite-url-${ob.tag}" ob.url;
      in
      ''
        # outbound: ${tag}
        URL=$(cat "${urlSource}")
        OB_JSON=$(printf '%s' "$URL" | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildOutboundPy} ${backendArg} --tag ${lib.escapeShellArg tag}${
          lib.optionalString (routingMark != null) " --routing-mark ${toString routingMark}"
        })
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      '';

  singBoxRawOutboundJson =
    ob: tag: routingMark:
    let
      backendRaw = if ob.singBoxJson != null then ob.singBoxJson else ob.json;
      markAttrs = lib.optionalAttrs (routingMark != null) { routing_mark = routingMark; };
    in
    backendRaw // { inherit tag; } // markAttrs;

  xrayRawOutboundJson =
    ob: tag:
    lib.recursiveUpdate (ob.xrayJson // { inherit tag; }) {
      streamSettings.sockopt = {
        mark = xraySidecarRoutingMark;
        domainStrategy = "UseIP";
      };
    };

  mkHybridOutboundBlock =
    ob: routingMark: tag:
    if ob.xrayJson != null then
      let
        outboundJson = builtins.toJSON (xrayRawOutboundJson ob tag);
        jsonFile = pkgs.writeText "proxy-suite-xray-sidecar-ob-${tag}.json" outboundJson;
      in
      ''
        # outbound: ${tag} (hybrid XRay json sidecar)
        OB_JSON=$(cat "${jsonFile}")
        _proxy_suite_add_xray_sidecar_ob "$OB_JSON" ${lib.escapeShellArg tag}
      ''
    else if ob.singBoxJson != null || ob.json != null then
      let
        outboundJson = builtins.toJSON (singBoxRawOutboundJson ob tag routingMark);
        jsonFile = pkgs.writeText "proxy-suite-sing-box-ob-${tag}.json" outboundJson;
      in
      ''
        # outbound: ${tag} (hybrid SingBox json)
        OB_JSON=$(cat "${jsonFile}")
        _proxy_suite_add_sing_box_ob "$OB_JSON"
      ''
    else
      let
        urlSource =
          if ob.urlFile != null then ob.urlFile else pkgs.writeText "proxy-suite-url-${ob.tag}" ob.url;
        singBoxCommand = ''
          printf '%s' "$URL" | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildOutboundPy} --backend sing-box --tag ${lib.escapeShellArg tag}${
            lib.optionalString (routingMark != null) " --routing-mark ${toString routingMark}"
          }
        '';
        xrayCommand = ''
          printf '%s' "$URL" | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildOutboundPy} --backend xray --tag ${lib.escapeShellArg tag} --routing-mark ${toString xraySidecarRoutingMark}
        '';
      in
      if ob.backend == "xray" then
        ''
          # outbound: ${tag} (hybrid forced XRay sidecar)
          URL=$(cat "${urlSource}")
          OB_JSON=$(${xrayCommand})
          _proxy_suite_add_xray_sidecar_ob "$OB_JSON" ${lib.escapeShellArg tag}
        ''
      else if ob.backend == "sing-box" then
        ''
          # outbound: ${tag} (hybrid forced SingBox)
          URL=$(cat "${urlSource}")
          OB_JSON=$(${singBoxCommand})
          _proxy_suite_add_sing_box_ob "$OB_JSON"
        ''
      else
        ''
          # outbound: ${tag} (hybrid auto)
          URL=$(cat "${urlSource}")
          if OB_JSON=$(${singBoxCommand} 2>"$RUNTIME_DIR/sing-box-parser.err"); then
            _proxy_suite_add_sing_box_ob "$OB_JSON"
          else
            SING_BOX_PARSE_ERROR="$(cat "$RUNTIME_DIR/sing-box-parser.err" 2>/dev/null || true)"
            if OB_JSON=$(${xrayCommand}); then
              _proxy_suite_add_xray_sidecar_ob "$OB_JSON" ${lib.escapeShellArg tag}
            else
              echo "proxy-suite: outbound '${tag}' cannot be parsed by SingBox or XRay" >&2
              if [ -n "$SING_BOX_PARSE_ERROR" ]; then
                printf '%s\n' "$SING_BOX_PARSE_ERROR" >&2
              fi
              exit 1
            fi
          fi
        '';

  mkBackendOutboundBlock = if hybridEnabled then mkHybridOutboundBlock else mkOutboundBlock;

  requireOutboundsBlock = ''
    if [ "$(${jq} 'length' <<< "$OUTBOUNDS_JSON")" -eq 0 ]; then
      echo "proxy-suite: no proxy outbounds are available; check static outbound definitions and subscription caches" >&2
      exit 1
    fi
  '';

  mkOutboundScript =
    routingMark:
    let
      outboundBlocks =
        if collapseNamedOutbounds && proxyCfg.outbounds != [ ] then
          mkBackendOutboundBlock (builtins.head proxyCfg.outbounds) routingMark "proxy"
        else
          lib.concatMapStrings (ob: mkBackendOutboundBlock ob routingMark ob.tag) proxyCfg.outbounds;

      subscriptionBlocks = lib.concatMapStrings (
        sub: mkSubscriptionBlock sub routingMark
      ) proxyCfg.subscriptions;

      wrapperBlock =
        if pureXrayEnabled && selectionMode == "urltest" then
          ''
            OUTBOUNDS_JSON=$(${jq} 'map(.tag = ("proxy-suite-ob-" + .tag))' <<< "$OUTBOUNDS_JSON")
            if [ "$(${jq} 'length' <<< "$OUTBOUNDS_JSON")" -eq 1 ]; then
              XRAY_SINGLE_PROXY_TAG="$(${jq} -r '.[0].tag' <<< "$OUTBOUNDS_JSON")"
            fi
          ''
        else if collapseNamedOutbounds then
          lib.optionalString (proxyCfg.outbounds == [ ] && proxyCfg.subscriptions != [ ]) ''
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
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            WRAPPER=$(${jq} -n \
              --argjson tags "$TAGS" \
              --arg url ${lib.escapeShellArg proxyCfg.urlTest.url} \
              --arg interval ${lib.escapeShellArg proxyCfg.urlTest.interval} \
              --argjson tolerance ${toString singBoxCfg.urlTest.tolerance} \
              '{type:"urltest",tag:"proxy",outbounds:$tags,url:$url,interval:$interval,tolerance:$tolerance}')
            OUTBOUNDS_JSON=$(${jq} --argjson w "$WRAPPER" '[$w] + .' <<< "$OUTBOUNDS_JSON")
          '';
    in
    outboundBlocks + subscriptionBlocks + requireOutboundsBlock + wrapperBlock;
in
{
  inherit mkOutboundScript rawOutboundJson;
}
