# Generates proxy backend startup scripts and subscription management scripts.
{
  lib,
  pkgs,
  singBoxCfg,
  proxyCfg,
  proxyEnabled,
  singBoxEnabled,
  xrayEnabled,
  hybridEnabled,
  pureXrayEnabled,
  activeBackend,
  perAppRoutingCfg,
  userControlCfg,
  perAppRoutingTun,
  selectionMode,
  collapseNamedOutbounds,
  hasSubscriptions,
  jq,
  python3,
  singBox,
  xray,
  parserScriptsPythonPath,
  buildOutboundPy,
  fetchSubscriptionPy,
  tproxyFile,
  tunFile,
  perAppTunFile,
  routeModeRulesFile,
}:

let
  globalTproxy = proxyCfg.tproxy;
  systemctl = "${pkgs.systemd}/bin/systemctl";
  backend = if activeBackend == null then "sing-box" else activeBackend;
  mainBackend = if pureXrayEnabled then "xray" else "sing-box";
  subscriptionBackend =
    if hybridEnabled then
      "hybrid"
    else
      mainBackend;
  backendArg = "--backend ${mainBackend}";
  subscriptionBackendArg = "--backend ${subscriptionBackend}";
  backendBin = if pureXrayEnabled then xray else singBox;
  localProxyAuth = proxyCfg.auth;
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
  subscriptionCacheDir = "/var/lib/proxy-suite/subscriptions/${backend}";
  routeModeStateFile = "/run/proxy-suite/route-mode";
  xrayLoglevelFile = "/run/proxy-suite/xray-loglevel";
  runtimeProxychainsConfig = "/run/proxy-suite-socks/proxychains.conf";
  xraySidecarRoutingMark = globalTproxy.proxyMark;

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
        | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${fetchSubscriptionPy} ${subscriptionBackendArg} --tag-prefix ${lib.escapeShellArg sub.tag}
    '';

  subscriptionCacheHelpersBlock = lib.optionalString hasSubscriptions ''
    _proxy_suite_valid_subscription_cache() {
      [ -s "$1" ] && ${jq} -e ${
        lib.escapeShellArg (
          if hybridEnabled then
            ''type == "object" and (.singBox | type == "array") and (.xray | type == "array")''
          else
            ''type == "array"''
        )
      } "$1" >/dev/null 2>&1
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

  routingMarkJq =
    routingMark:
    if routingMark == null then
      ""
    else if pureXrayEnabled then
      " | .streamSettings.sockopt.mark = ${toString routingMark}"
    else
      " | .routing_mark = ${toString routingMark}";

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

  mkSubscriptionBlock =
    sub: routingMark:
    let
      cacheFile = mkSubscriptionCacheFile sub;
      markFilter = routingMarkJq routingMark;
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
      ${
        if hybridEnabled then
          ''
            if [ -f "$CACHE_FILE" ]; then
              SUB_SING_BOX_JSON=$(${jq} -c '.singBox' "$CACHE_FILE")
              ${
                lib.optionalString (routingMark != null) ''
                  SUB_SING_BOX_JSON=$(${jq} 'map(.${markFilter})' <<< "$SUB_SING_BOX_JSON")
                ''
              }OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_SING_BOX_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
              while IFS= read -r SUB_XRAY_OB; do
                SUB_XRAY_TAG="$(${jq} -r '.tag' <<< "$SUB_XRAY_OB")"
                _proxy_suite_add_xray_sidecar_ob "$SUB_XRAY_OB" "$SUB_XRAY_TAG"
              done < <(${jq} -c '.xray[]' "$CACHE_FILE")
            fi
          ''
        else
          ''
            if [ -f "$CACHE_FILE" ]; then
              SUB_JSON=$(cat "$CACHE_FILE")
              ${
                lib.optionalString (routingMark != null) ''
                  SUB_JSON=$(${jq} 'map(.${markFilter})' <<< "$SUB_JSON")
                ''
              }OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
            fi
          ''
      }
    '';

  xrayUrltestTagFilter = ''
    OUTBOUNDS_JSON=$(${jq} 'map(.tag = ("proxy-suite-ob-" + .tag))' <<< "$OUTBOUNDS_JSON")
    if [ "$(${jq} 'length' <<< "$OUTBOUNDS_JSON")" -eq 1 ]; then
      XRAY_SINGLE_PROXY_TAG="$(${jq} -r '.[0].tag' <<< "$OUTBOUNDS_JSON")"
    fi
  '';

  hybridRuntimeHelpersBlock =
    routingMark: xraySidecarBasePort: xrayDnsBridgePort:
    lib.optionalString hybridEnabled ''
      XRAY_OUTBOUNDS_JSON='[]'
      XRAY_INBOUNDS_JSON='[]'
      XRAY_ROUTE_RULES_JSON='[]'
      XRAY_SIDECAR_NEXT_PORT=${toString xraySidecarBasePort}
      XRAY_SIDECAR_DNS_PORT=${toString xrayDnsBridgePort}

      _proxy_suite_add_sing_box_ob() {
        local ob="$1"
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$ob" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      }

      _proxy_suite_next_xray_sidecar_port() {
        local port="$XRAY_SIDECAR_NEXT_PORT"
        XRAY_SIDECAR_NEXT_PORT=$((XRAY_SIDECAR_NEXT_PORT + 1))
        printf '%s\n' "$port"
      }

      _proxy_suite_add_xray_sidecar_ob() {
        local ob="$1" tag="$2" port auth inbound_tag sing_ob inbound route_rule
        port="$(_proxy_suite_next_xray_sidecar_port)"
        auth="proxy-suite-xray-$port"
        inbound_tag="$tag-inbound"
        ob=$(${jq} \
          --arg tag "$tag" \
          --argjson mark ${toString xraySidecarRoutingMark} \
          '.tag = $tag
           | .streamSettings = (.streamSettings // {})
           | .streamSettings.sockopt = (.streamSettings.sockopt // {})
           | .streamSettings.sockopt.mark = $mark
           | .streamSettings.sockopt.domainStrategy = (.streamSettings.sockopt.domainStrategy // "UseIP")' \
          <<< "$ob")
        XRAY_OUTBOUNDS_JSON=$(${jq} --argjson ob "$ob" '. + [$ob]' <<< "$XRAY_OUTBOUNDS_JSON")
        inbound=$(${jq} -n \
          --arg tag "$inbound_tag" \
          --arg auth "$auth" \
          --argjson port "$port" \
          '{tag:$tag,listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"password",udp:true,accounts:[{user:$auth,pass:$auth}]}}')
        XRAY_INBOUNDS_JSON=$(${jq} --argjson inbound "$inbound" '. + [$inbound]' <<< "$XRAY_INBOUNDS_JSON")
        route_rule=$(${jq} -n \
          --arg inbound "$inbound_tag" \
          --arg outbound "$tag" \
          '{type:"field",inboundTag:[$inbound],outboundTag:$outbound}')
        XRAY_ROUTE_RULES_JSON=$(${jq} --argjson rule "$route_rule" '. + [$rule]' <<< "$XRAY_ROUTE_RULES_JSON")
        sing_ob=$(${jq} -n \
          --arg tag "$tag" \
          --arg auth "$auth" \
          --argjson port "$port" \
          '{type:"socks",tag:$tag,server:"127.0.0.1",server_port:$port,version:"5",username:$auth,password:$auth${
            lib.optionalString (routingMark != null) ",routing_mark:${toString routingMark}"
          }}')
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$sing_ob" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      }

      _proxy_suite_write_xray_sidecar_config() {
        if [ "$(${jq} 'length' <<< "$XRAY_OUTBOUNDS_JSON")" -eq 0 ]; then
          return 0
        fi
        ${jq} -n \
          --arg loglevel "$XRAY_LOGLEVEL" \
          --arg bind_interface "$XRAY_TUN_BIND_INTERFACE" \
          --argjson dns_port "$XRAY_SIDECAR_DNS_PORT" \
          --argjson inbounds "$XRAY_INBOUNDS_JSON" \
          --argjson outbounds "$XRAY_OUTBOUNDS_JSON" \
          --argjson route_rules "$XRAY_ROUTE_RULES_JSON" \
          '
          def bind_xray_sidecar($interface):
            if $interface == "" then
              .
            else
              .streamSettings = (.streamSettings // {})
              | .streamSettings.sockopt = (.streamSettings.sockopt // {})
              | if (.streamSettings.sockopt.interface? // "") == "" then
                  .streamSettings.sockopt.interface = $interface
                else
                  .
                end
            end;
          {
            log: {
              loglevel: (if $loglevel == "" then "warning" else $loglevel end),
              access: "none"
            },
            dns: {
              servers: [
                {
                  address: "127.0.0.1",
                  port: $dns_port,
                  queryStrategy: "UseIP",
                  skipFallBack: true
                }
              ]
            },
            inbounds: $inbounds,
            outbounds: (($outbounds | map(bind_xray_sidecar($bind_interface))) + [{protocol:"freedom",tag:"direct"}]),
            routing: {
              domainStrategy: "AsIs",
              rules: ($route_rules + [{type:"field",ip:["127.0.0.1"],port:$dns_port,outboundTag:"direct"}])
            }
          }' > "$RUNTIME_DIR/xray-sidecar.json"
      }
    '';

  mkOutboundScript =
    routingMark:
    let
      outboundBlocks =
        if collapseNamedOutbounds && proxyCfg.outbounds != [ ] then
          (if hybridEnabled then mkHybridOutboundBlock else mkOutboundBlock)
            (builtins.head proxyCfg.outbounds)
            routingMark
            "proxy"
        else
          lib.concatMapStrings (
            ob: (if hybridEnabled then mkHybridOutboundBlock else mkOutboundBlock) ob routingMark ob.tag
          ) proxyCfg.outbounds;

      subscriptionBlocks = lib.concatMapStrings (
        sub: mkSubscriptionBlock sub routingMark
      ) proxyCfg.subscriptions;

      requireOutboundsBlock = ''
        if [ "$(${jq} 'length' <<< "$OUTBOUNDS_JSON")" -eq 0 ]; then
          echo "proxy-suite: no proxy outbounds are available; check static outbound definitions and subscription caches" >&2
          exit 1
        fi
      '';

      wrapperBlock =
        if pureXrayEnabled && selectionMode == "urltest" then
          xrayUrltestTagFilter
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

  restartActiveConfigConsumersBlock =
    lib.concatMapStrings
      (svc: ''
        if ${systemctl} is-active --quiet ${svc}; then
          ${systemctl} restart ${svc}
        fi
      '')
      [
        "proxy-suite-socks"
        "proxy-suite-tun"
        "proxy-suite-per-app-tun"
      ];

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

  mkBackendJqFilter =
    if pureXrayEnabled then
      ''
        def xray_bind_outbound($interface):
          if $interface == "" or .protocol == "blackhole" or .protocol == "dns" then
            .
          else
            .streamSettings = (.streamSettings // {})
            | .streamSettings.sockopt = (.streamSettings.sockopt // {})
            | if (.streamSettings.sockopt.interface? // "") == "" then
                .streamSettings.sockopt.interface = $interface
              else
                .
              end
          end;
        def xray_proxy_rule_target($single_tag):
          if $single_tag != "" then
            {outboundTag:$single_tag}
          else
            {balancerTag:"proxy"}
          end;
        def xray_rewrite_proxy_rule($single_tag):
          if $single_tag != "" and (.balancerTag? // "") == "proxy" then
            .outboundTag = $single_tag | del(.balancerTag)
          else
            .
          end;
        def xray_preserved_rules:
          [.routing.rules[]
           | select(((.ruleTag? // "") == "dns-hijack") or ((.ruleTag? // "") == "dns-upstream-direct"))];
        def xray_final_rule($tag; $single_tag):
          if $tag == "proxy" and "${selectionMode}" == "urltest" then
            {type:"field",network:"tcp,udp",ruleTag:"final-default"} + xray_proxy_rule_target($single_tag)
          else
            {type:"field",network:"tcp,udp",ruleTag:"final-default",outboundTag:$tag}
          end;
        def xray_dns_server_order($dns_final):
          if $dns_final == "" then
            .dns.servers
          else
            ([.dns.servers[] | select((.tag? // "") == "fakedns")]
             + [.dns.servers[] | select((.tag? // "") == $dns_final)]
             + [.dns.servers[] | select((.tag? // "") != "fakedns" and (.tag? // "") != $dns_final)])
          end;
        def xray_tun_dns_addresses($dns_final; $local_addr; $remote_addr):
          if $dns_final == "local" then
            [$local_addr, $remote_addr]
          elif $dns_final == "remote" then
            [$remote_addr, $local_addr]
          else
            [$remote_addr, $local_addr]
          end;
        .outbounds = (($obs + .outbounds) | map(xray_bind_outbound($xray_bind_interface)))
          | if $xray_loglevel == "" then . else .log.loglevel = $xray_loglevel end
          | if $auth_enabled then
              (.inbounds[] | select(.protocol == "socks" and .tag == "mixed-in") | .settings.auth) = "password"
              | (.inbounds[] | select(.protocol == "socks" and .tag == "mixed-in") | .settings.accounts) = [{user:$user,pass:$password}]
            else . end
          | if $xray_tun_dns_runtime then
              .dns.servers = xray_dns_server_order($dns_final)
              | if $dns_final == "" then
                  .
                else
                  (.inbounds[] | select(.protocol == "tun" and .tag == "tun-in") | .settings.dns) = xray_tun_dns_addresses($dns_final; $xray_dns_local_client; $xray_dns_remote_client)
                end
            else . end
          | if $route_enabled then
              .routing.rules = (xray_preserved_rules + $route_rules + [xray_final_rule($route_final; $xray_single_proxy_tag)])
            else . end
          | if $xray_single_proxy_tag == "" then
              .
            else
              .routing.rules |= map(xray_rewrite_proxy_rule($xray_single_proxy_tag))
              | del(.routing.balancers)
              | del(.observatory)
            end
      ''
    else
      ''
        def sing_box_preserved_rules:
          [.route.rules[]
           | select(((.action? // "") == "hijack-dns")
             and (((.inbound? // []) | index("xray-dns-in")) != null))];
        .outbounds = $obs + .outbounds
          | if $auth_enabled then
              (.inbounds[] | select(.type == "mixed" and .tag == "mixed-in") | .users) = [{username:$user,password:$password}]
            else . end
          | if $route_enabled then
              .route.rules = (sing_box_preserved_rules + $route_rules)
              | .route.final = $route_final
              | .dns.final = $dns_final
              | if $clear_dns_rules then .dns.rules = [] else . end
            else . end
      '';
  backendJqFilterFile = pkgs.writeText "proxy-suite-${backend}-backend-filter.jq" mkBackendJqFilter;

  mkStartScript =
    {
      name,
      runtimeDir,
      configFile,
      routingMark ? null,
      enableLocalProxyAuth ? false,
      xrayTunEgressBinding ? false,
      xrayTunDnsRuntime ? false,
      xraySidecarBasePort ? 33080,
      xrayDnsBridgePort ? 18533,
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
    xraySidecarBasePort = 33080;
    xrayDnsBridgePort = 18533;
  };

  startTun = mkStartScript {
    name = "proxy-suite-start-tun";
    runtimeDir = "/run/proxy-suite-tun";
    configFile = tunFile;
    routingMark = if pureXrayEnabled then globalTproxy.proxyMark else null;
    xrayTunEgressBinding = xrayEnabled;
    xrayTunDnsRuntime = pureXrayEnabled;
    xraySidecarBasePort = 33180;
    xrayDnsBridgePort = 18534;
  };

  startPerAppTun = mkStartScript {
    name = "proxy-suite-start-per-app-tun";
    runtimeDir = "/run/proxy-suite-per-app-tun";
    configFile = perAppTunFile;
    routingMark = if xrayEnabled || globalTproxy.enable then globalTproxy.proxyMark else null;
    xrayTunEgressBinding = xrayEnabled;
    xrayTunDnsRuntime = pureXrayEnabled;
    xraySidecarBasePort = 33280;
    xrayDnsBridgePort = 18535;
  };

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
    ${lib.concatMapStrings mkSubscriptionFetchBlock proxyCfg.subscriptions}

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
    builtins.toJSON (map (sub: sub.tag) proxyCfg.subscriptions)
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
    subscriptionCacheDir
    runtimeProxychainsConfig
    ;
}
