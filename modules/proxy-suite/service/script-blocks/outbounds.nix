{
  lib,
  pkgs,
  singBoxCfg,
  proxyCfg,
  sshProxyCfg,
  warpCfg,
  pureXrayEnabled,
  hybridEnabled,
  collapseNamedOutbounds,
  selectionMode,
  backend,
  backendArg,
  xraySidecarRoutingMark,
  priorityOutboundFile,
  runtimeOutboundsDir,
  jq,
  python3,
  parserScriptsPythonPath,
  buildOutboundPy,
  mkSubscriptionBlock,
  mkSubscriptionLoadHelperBlock,
  runtimeSubscriptionsBlock,
}:

let
  sshProxyTag = "ssh-proxy";

  # sing-box domain strategies in XRay's names (UseIPv4v6 = prefer IPv4).
  xrayDomainStrategies = {
    prefer_ipv4 = "UseIPv4v6";
    prefer_ipv6 = "UseIPv6v4";
    ipv4_only = "UseIPv4";
    ipv6_only = "UseIPv6";
  };

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

  # Every outbound that comes from a URL goes through these, whether it was
  # declared in Nix or dropped into outbounds.d at runtime.
  mkUrlOutboundHelpersBlock =
    routingMark:
    let
      markArg = lib.optionalString (routingMark != null) " --routing-mark ${toString routingMark}";
      parse = backendFlag: markFlag: ''
        printf '%s' "$2" | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildOutboundPy} \
          ${backendFlag} --tag "$1"${markFlag}
      '';
      addBlock =
        if hybridEnabled then
          ''
            case "$pref" in
              xray)
                ob=$(_proxy_suite_parse_xray_url "$tag" "$url") || return 1
                _proxy_suite_add_xray_sidecar_ob "$ob" "$tag"
                ;;
              sing-box)
                ob=$(_proxy_suite_parse_sing_box_url "$tag" "$url") || return 1
                _proxy_suite_add_sing_box_ob "$ob"
                ;;
              *)
                if ob=$(_proxy_suite_parse_sing_box_url "$tag" "$url" 2>"$RUNTIME_DIR/sing-box-parser.err"); then
                  _proxy_suite_add_sing_box_ob "$ob"
                elif ob=$(_proxy_suite_parse_xray_url "$tag" "$url"); then
                  _proxy_suite_add_xray_sidecar_ob "$ob" "$tag"
                else
                  echo "proxy-suite: outbound '$tag' cannot be parsed by SingBox or XRay" >&2
                  if [ -s "$RUNTIME_DIR/sing-box-parser.err" ]; then
                    cat "$RUNTIME_DIR/sing-box-parser.err" >&2
                  fi
                  return 1
                fi
                ;;
            esac
          ''
        else
          ''
            ob=$(_proxy_suite_parse_url "$tag" "$url") || return 1
            OUTBOUNDS_JSON=$(${jq} --argjson ob "$ob" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
          '';
    in
    ''
      OUTBOUND_SOURCES_JSON='{}'

      _proxy_suite_record_tag_source() {
        OUTBOUND_SOURCES_JSON=$(${jq} --arg t "$1" --arg s "$2" '.[$t] = $s' <<< "$OUTBOUND_SOURCES_JSON")
      }

      # $1 source label, $2 array length before the add, $3 after. Subscriptions
      # append an unknown number of outbounds, so they label them by range.
      _proxy_suite_record_outbound_source() {
        [ "$3" -gt "$2" ] || return 0
        OUTBOUND_SOURCES_JSON=$(${jq} \
          --argjson sources "$OUTBOUND_SOURCES_JSON" --arg s "$1" \
          --argjson b "$2" --argjson a "$3" \
          'reduce .[$b:$a][].tag as $t ($sources; .[$t] = $s)' <<< "$OUTBOUNDS_JSON")
      }

      ${
        if hybridEnabled then
          ''
            _proxy_suite_parse_sing_box_url() {
              ${parse "--backend sing-box" markArg}
            }

            _proxy_suite_parse_xray_url() {
              ${parse "--backend xray" " --routing-mark ${toString xraySidecarRoutingMark}"}
            }
          ''
        else
          ''
            _proxy_suite_parse_url() {
              ${parse backendArg markArg}
            }
          ''
      }
      # $1 tag, $2 URL, $3 source label, $4 backend preference (auto|sing-box|xray).
      # Returns non-zero when the URL cannot be parsed; the caller decides whether
      # that is fatal.
      _proxy_suite_add_url_outbound() {
        local tag="$1" url="$2" source="$3" pref="''${4:-auto}" ob
        ${addBlock}
        _proxy_suite_record_tag_source "$tag" "$source"
      }

      # Every runtime outbound, as "<tag>\t<url file>" lines. proxy-ctl refuses
      # the reserved names, but the spool is group-writable, so check again here:
      # a second outbound tagged "proxy" would quietly shadow the real one.
      _proxy_suite_runtime_outbounds() {
        local f tag
        [ -d "${runtimeOutboundsDir}" ] || return 0
        for f in "${runtimeOutboundsDir}"/*.url; do
          [ -e "$f" ] || continue
          tag="''${f##*/}"
          tag="''${tag%.url}"
          case "$tag" in
            proxy | direct | block)
              echo "proxy-suite: warning: ignoring runtime outbound '$tag': reserved name" >&2
              continue
              ;;
          esac
          printf '%s\t%s\n' "$tag" "$f"
        done
      }
    '';

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
        _proxy_suite_record_tag_source ${lib.escapeShellArg tag} static
      ''
    else
      let
        urlSource =
          if ob.urlFile != null then ob.urlFile else pkgs.writeText "proxy-suite-url-${ob.tag}" ob.url;
      in
      ''
        # outbound: ${tag}
        _proxy_suite_add_url_outbound ${lib.escapeShellArg tag} "$(cat "${urlSource}")" static || exit 1
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
        _proxy_suite_record_tag_source ${lib.escapeShellArg tag} static
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
        _proxy_suite_record_tag_source ${lib.escapeShellArg tag} static
      ''
    else
      let
        urlSource =
          if ob.urlFile != null then ob.urlFile else pkgs.writeText "proxy-suite-url-${ob.tag}" ob.url;
      in
      ''
        # outbound: ${tag} (hybrid ${ob.backend})
        _proxy_suite_add_url_outbound ${lib.escapeShellArg tag} "$(cat "${urlSource}")" static ${ob.backend} || exit 1
      '';

  mkSshProxyOutboundBlock =
    routingMark:
    let
      singBoxOutbound = {
        type = "ssh";
        tag = sshProxyTag;
        server = sshProxyCfg.server.host;
        server_port = sshProxyCfg.server.port;
        user = sshProxyCfg.server.user;
      }
      // lib.optionalAttrs (sshProxyCfg.identityFile != null) {
        private_key_path = sshProxyCfg.identityFile;
      }
      // lib.optionalAttrs (sshProxyCfg.hostKey != [ ]) {
        host_key = sshProxyCfg.hostKey;
      }
      // lib.optionalAttrs (routingMark != null) {
        routing_mark = routingMark;
      };
      # XRay has no SSH outbound: it goes through the OpenSSH unit's listener.
      xraySockopt =
        lib.optionalAttrs (routingMark != null) { mark = routingMark; }
        // lib.optionalAttrs (sshProxyCfg.domainStrategy != null) {
          domainStrategy = xrayDomainStrategies.${sshProxyCfg.domainStrategy};
        };
      xrayOutbound = {
        protocol = "socks";
        tag = sshProxyTag;
        settings = {
          address = sshProxyCfg.listener.address;
          port = sshProxyCfg.listener.port;
        };
      }
      // lib.optionalAttrs (xraySockopt != { }) {
        streamSettings.sockopt = xraySockopt;
      };
      outbound = if pureXrayEnabled then xrayOutbound else singBoxOutbound;
      outboundJson = builtins.toJSON outbound;
      jsonFile = pkgs.writeText "proxy-suite-ob-ssh-proxy-${backend}.json" outboundJson;

      # Read at start so the known-hosts file stays out of the store.
      knownHostsTarget =
        if sshProxyCfg.server.port == 22 then
          sshProxyCfg.server.host
        else
          "[${sshProxyCfg.server.host}]:${toString sshProxyCfg.server.port}";
      hostKeyFileBlock = lib.optionalString (!pureXrayEnabled && sshProxyCfg.hostKeyFile != null) ''
        SSH_HOST_KEYS=$(${pkgs.openssh}/bin/ssh-keygen -F ${lib.escapeShellArg knownHostsTarget} \
          -f ${lib.escapeShellArg sshProxyCfg.hostKeyFile} \
          | ${jq} -R -s '[splits("\n")] | map(select(length > 0 and (startswith("#") | not))) | map(sub("^\\S+\\s+"; ""))')
        if [ "$(${jq} 'length' <<< "$SSH_HOST_KEYS")" -eq 0 ]; then
          echo "proxy-suite: no host keys for ${knownHostsTarget} in ${sshProxyCfg.hostKeyFile}" >&2
          exit 1
        fi
        OB_JSON=$(${jq} --argjson hk "$SSH_HOST_KEYS" '.host_key = $hk' <<< "$OB_JSON")
      '';
    in
    ''
      # outbound: ${sshProxyTag} (${if pureXrayEnabled then "OpenSSH SOCKS5 listener" else "native SSH"})
      OB_JSON=$(cat "${jsonFile}")
      ${hostKeyFileBlock}
      ${
        if hybridEnabled then
          ''_proxy_suite_add_sing_box_ob "$OB_JSON"''
        else
          ''OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")''
      }
      _proxy_suite_record_tag_source ${sshProxyTag} ssh
    '';

  # WARP runs in proxy-suite-warp-tunnel, which restarts it when the handshake stops being
  # answered. Every backend reaches it as a loopback SOCKS hop.
  mkWarpOutboundBlock =
    let
      outbound =
        if pureXrayEnabled then
          {
            protocol = "socks";
            tag = "warp";
            settings = {
              address = "127.0.0.1";
              port = warpCfg.tunnelPort;
            };
          }
        else
          {
            type = "socks";
            tag = "warp";
            server = "127.0.0.1";
            server_port = warpCfg.tunnelPort;
          };
    in
    ''
      # outbound: warp (SOCKS hop to proxy-suite-warp-tunnel)
      OB_JSON=${lib.escapeShellArg (builtins.toJSON outbound)}
      ${
        if hybridEnabled then
          ''_proxy_suite_add_sing_box_ob "$OB_JSON"''
        else
          ''OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")''
      }
      _proxy_suite_record_tag_source warp warp
    '';

  mkBackendOutboundBlock = if hybridEnabled then mkHybridOutboundBlock else mkOutboundBlock;

  runtimeOutboundsBlock = ''
    # outbounds added at runtime
    while IFS=$'\t' read -r RUNTIME_OB_TAG RUNTIME_OB_SRC; do
      [ -n "$RUNTIME_OB_TAG" ] || continue
      _proxy_suite_add_url_outbound "$RUNTIME_OB_TAG" "$(cat "$RUNTIME_OB_SRC")" runtime \
        || echo "proxy-suite: warning: ignoring runtime outbound '$RUNTIME_OB_TAG'" >&2
    done < <(_proxy_suite_runtime_outbounds)
  '';

  requireOutboundsBlock = ''
    if [ "$(${jq} 'length' <<< "$OUTBOUNDS_JSON")" -eq 0 ]; then
      echo "proxy-suite: no proxy outbounds are available; declare one, or add one with 'proxy-ctl proxy outbounds add'" >&2
      exit 1
    fi
  '';

  # The pin names a user-facing tag, so it is resolved before the wrapper block
  # renames anything. A pin that no longer matches any outbound - a subscription
  # entry that went away, say - is dropped rather than left to break the config.
  pinBlock = ''
    OUTBOUND_TAGS_JSON=$(${jq} -c '[.[].tag]' <<< "$OUTBOUNDS_JSON")
    PRIORITY_OUTBOUND=""
    if [ -r "${priorityOutboundFile}" ]; then
      PRIORITY_OUTBOUND="$(tr -d '\r\n[:space:]' < "${priorityOutboundFile}" 2>/dev/null || true)"
    fi
    if [ -n "$PRIORITY_OUTBOUND" ] \
      && ! ${jq} -e --arg t "$PRIORITY_OUTBOUND" 'index($t) != null' <<< "$OUTBOUND_TAGS_JSON" >/dev/null; then
      echo "proxy-suite: warning: pinned outbound '$PRIORITY_OUTBOUND' is not available; picking automatically" >&2
      PRIORITY_OUTBOUND=""
    fi
  '';

  # proxy-ctl reads this unprivileged: tags, where each came from, and the pin.
  inventoryBlock = ''
    ${jq} -n \
      --argjson tags "$OUTBOUND_TAGS_JSON" \
      --argjson sources "$OUTBOUND_SOURCES_JSON" \
      --arg pinned "$PRIORITY_OUTBOUND" \
      --arg selection ${lib.escapeShellArg selectionMode} \
      '{tags: $tags, sources: $sources, pinned: $pinned, selection: $selection}' \
      > "$RUNTIME_DIR/outbounds.json"
    chmod 644 "$RUNTIME_DIR/outbounds.json"
  '';

  mkOutboundScript =
    routingMark:
    let
      outboundBlocks = lib.concatMapStrings (
        ob: mkBackendOutboundBlock ob routingMark ob.tag
      ) proxyCfg.outbounds;

      subscriptionBlocks = lib.concatMapStrings (
        sub: mkSubscriptionBlock sub routingMark
      ) proxyCfg.subscriptions;

      sshProxyBlock = lib.optionalString sshProxyCfg.asOutbound (mkSshProxyOutboundBlock routingMark);
      warpBlock = lib.optionalString (warpCfg.enable && warpCfg.asOutbound) mkWarpOutboundBlock;

      wrapperBlock =
        if pureXrayEnabled && selectionMode == "urltest" then
          ''
            OUTBOUNDS_JSON=$(${jq} 'map(.tag = ("proxy-suite-ob-" + .tag))' <<< "$OUTBOUNDS_JSON")
            # XRay has no selector: a pin degrades the balancer to the one outbound,
            # which is the same path a single-outbound config already takes.
            if [ -n "$PRIORITY_OUTBOUND" ]; then
              XRAY_SINGLE_PROXY_TAG="proxy-suite-ob-$PRIORITY_OUTBOUND"
            elif [ "$(${jq} 'length' <<< "$OUTBOUNDS_JSON")" -eq 1 ]; then
              XRAY_SINGLE_PROXY_TAG="$(${jq} -r '.[0].tag' <<< "$OUTBOUNDS_JSON")"
            fi
          ''
        else if collapseNamedOutbounds then
          ''
            PROXY_TAG="$PRIORITY_OUTBOUND"
            if [ -z "$PROXY_TAG" ]; then
              PROXY_TAG=$(${jq} -r '.[0].tag' <<< "$OUTBOUNDS_JSON")
            fi
            OUTBOUNDS_JSON=$(${jq} --arg t "$PROXY_TAG" \
              'map(if .tag == $t then .tag = "proxy" else . end)' <<< "$OUTBOUNDS_JSON")
          ''
        else if selectionMode == "selector" then
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            DEFAULT_TAG="$PRIORITY_OUTBOUND"
            if [ -z "$DEFAULT_TAG" ]; then
              DEFAULT_TAG=$(${jq} -r '.[0].tag' <<< "$OUTBOUNDS_JSON")
            fi
            WRAPPER=$(${jq} -n \
              --argjson tags "$TAGS" \
              --arg default "$DEFAULT_TAG" \
              '{type:"selector",tag:"proxy",outbounds:$tags,default:$default}')
            OUTBOUNDS_JSON=$(${jq} --argjson w "$WRAPPER" '[$w] + .' <<< "$OUTBOUNDS_JSON")
          ''
        else
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            if [ -n "$PRIORITY_OUTBOUND" ]; then
              # A pin beats latency ranking: the same outbounds, behind a selector
              # the Clash API can also switch live.
              WRAPPER=$(${jq} -n \
                --argjson tags "$TAGS" \
                --arg default "$PRIORITY_OUTBOUND" \
                '{type:"selector",tag:"proxy",outbounds:$tags,default:$default}')
            else
              WRAPPER=$(${jq} -n \
                --argjson tags "$TAGS" \
                --arg url ${lib.escapeShellArg proxyCfg.urlTest.url} \
                --arg interval ${lib.escapeShellArg proxyCfg.urlTest.interval} \
                --argjson tolerance ${toString singBoxCfg.urlTest.tolerance} \
                '{type:"urltest",tag:"proxy",outbounds:$tags,url:$url,interval:$interval,tolerance:$tolerance}')
            fi
            OUTBOUNDS_JSON=$(${jq} --argjson w "$WRAPPER" '[$w] + .' <<< "$OUTBOUNDS_JSON")
          '';
      # Real exits for autoProxy, taken after the wrapper may have renamed one to
      # "proxy".
      exitTagsBlock = ''
        EXIT_TAGS_JSON=$(${jq} -c '[.[] | select(.type != "selector" and .type != "urltest") | .tag]' <<< "$OUTBOUNDS_JSON")
      '';
    in
    mkUrlOutboundHelpersBlock routingMark
    + mkSubscriptionLoadHelperBlock routingMark
    + outboundBlocks
    + subscriptionBlocks
    + runtimeSubscriptionsBlock
    + runtimeOutboundsBlock
    + sshProxyBlock
    + warpBlock
    + requireOutboundsBlock
    + pinBlock
    + inventoryBlock
    + wrapperBlock
    + exitTagsBlock;
in
{
  inherit mkOutboundScript rawOutboundJson;
}
