{
  lib,
  pkgs,
  singBoxCfg,
  proxyCfg,
  sshProxyCfg,
  warpCfg,
  awgOutbounds,
  constants,
  pureXrayEnabled,
  hybridEnabled,
  collapseNamedOutbounds,
  selectionMode,
  backend,
  backendArg,
  xraySidecarRoutingMark,
  pinnedOutboundFile,
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
      backendRaw = if pureXrayEnabled then ob.xrayJson else ob.singBoxJson;
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
      # Raw JSON gets the tag and the routing mark a Nix-declared one gets (rawOutboundJson).
      singBoxMark = lib.optionalString (routingMark != null) " | .routing_mark = ${toString routingMark}";
      xrayMark = lib.optionalString (
        routingMark != null
      ) " | .streamSettings.sockopt.mark = ${toString routingMark}";
      jsonAddBlock =
        if hybridEnabled then
          ''
            case "$kind" in
              xray) _proxy_suite_add_xray_sidecar_ob "$ob" "$tag" ;;
              sing-box) _proxy_suite_add_sing_box_ob "$(${jq} -c '.${singBoxMark}' <<< "$ob")" ;;
              *) echo "proxy-suite: outbound '$tag' is neither sing-box nor XRay JSON" >&2; return 1 ;;
            esac
          ''
        else
          let
            want = if pureXrayEnabled then "xray" else "sing-box";
          in
          ''
            if [ "$kind" != ${want} ]; then
              echo "proxy-suite: outbound '$tag' is not ${want} JSON" >&2
              return 1
            fi
            OUTBOUNDS_JSON=$(${jq} --argjson ob "$ob" '. + [$ob${
              if pureXrayEnabled then xrayMark else singBoxMark
            }]' <<< "$OUTBOUNDS_JSON")
          '';
    in
    ''
      OUTBOUND_SOURCES_JSON='{}'
      # What proxy-ctl shares back: tag -> the URL it was given, sub tag -> its URL.
      OUTBOUND_URLS_JSON='{}'
      SUBSCRIPTION_URLS_JSON='{}'

      _proxy_suite_record_tag_source() {
        OUTBOUND_SOURCES_JSON=$(${jq} --arg t "$1" --arg s "$2" '.[$t] = $s' <<< "$OUTBOUND_SOURCES_JSON")
      }

      # $1 sub tag, $2 file holding its URL, $3 its links file (absent for a cache
      # written before links existed: those entries share as JSON until the next update).
      _proxy_suite_record_subscription_share() {
        SUBSCRIPTION_URLS_JSON=$(${jq} --arg t "$1" --rawfile u "$2" '.[$t] = ($u | rtrimstr("\n"))' <<< "$SUBSCRIPTION_URLS_JSON")
        if [ -s "$3" ]; then
          OUTBOUND_URLS_JSON=$(${jq} --slurpfile l "$3" '. + $l[0]' <<< "$OUTBOUND_URLS_JSON") || true
        fi
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
              ${parse "--backend xray" (
                lib.optionalString (xraySidecarRoutingMark != null) " --routing-mark ${toString xraySidecarRoutingMark}"
              )}
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
        OUTBOUND_URLS_JSON=$(${jq} --arg t "$tag" --arg u "$url" '.[$t] = $u' <<< "$OUTBOUND_URLS_JSON")
      }

      # $1 tag, $2 file holding one sing-box or XRay outbound, $3 source label.
      _proxy_suite_add_json_outbound() {
        local tag="$1" source="$3" ob kind
        ob=$(${jq} -ce --arg t "$tag" 'select(type == "object") | .tag = $t' "$2" 2>/dev/null) || return 1
        kind=$(${jq} -r 'if has("protocol") then "xray" elif has("type") then "sing-box" else "" end' <<< "$ob")
        ${jsonAddBlock}
        _proxy_suite_record_tag_source "$tag" "$source"
      }

      # Every runtime outbound, as "<tag>\t<file>" lines: <tag>.url or <tag>.json. proxy-ctl refuses
      # the reserved names, but the spool is group-writable, so check again here:
      # a second outbound tagged "proxy" would quietly shadow the real one.
      _proxy_suite_runtime_outbounds() {
        local f tag
        [ -d "${runtimeOutboundsDir}" ] || return 0
        for f in "${runtimeOutboundsDir}"/*.url "${runtimeOutboundsDir}"/*.json; do
          [ -e "$f" ] || continue
          tag="''${f##*/}"
          tag="''${tag%.*}"
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
    if (if pureXrayEnabled then ob.xrayJson else ob.singBoxJson) != null then
      let
        outboundJson = builtins.toJSON (rawOutboundJson ob tag routingMark);
        jsonFile = pkgs.writeText "proxy-suite-core" outboundJson;
      in
      ''
        # outbound: ${tag} (static ${backend} json)
        OB_JSON=$(cat "${jsonFile}")
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
        _proxy_suite_record_tag_source ${lib.escapeShellArg tag} static
      ''
    else
      let
        urlSource = if ob.urlFile != null then ob.urlFile else pkgs.writeText "proxy-suite-core" ob.url;
      in
      ''
        # outbound: ${tag}
        _proxy_suite_add_url_outbound ${lib.escapeShellArg tag} "$(cat "${urlSource}")" static || exit 1
      '';

  singBoxRawOutboundJson =
    ob: tag: routingMark:
    ob.singBoxJson // { inherit tag; } // lib.optionalAttrs (routingMark != null) { routing_mark = routingMark; };

  mkHybridOutboundBlock =
    ob: routingMark: tag:
    if ob.xrayJson != null then
      let
        # The sidecar helper adds the tag, its mark, and UseIP unless one is set.
        outboundJson = builtins.toJSON ob.xrayJson;
        jsonFile = pkgs.writeText "proxy-suite-core" outboundJson;
      in
      ''
        # outbound: ${tag} (hybrid XRay json sidecar)
        OB_JSON=$(cat "${jsonFile}")
        _proxy_suite_add_xray_sidecar_ob "$OB_JSON" ${lib.escapeShellArg tag}
        _proxy_suite_record_tag_source ${lib.escapeShellArg tag} static
      ''
    else if ob.singBoxJson != null then
      let
        outboundJson = builtins.toJSON (singBoxRawOutboundJson ob tag routingMark);
        jsonFile = pkgs.writeText "proxy-suite-core" outboundJson;
      in
      ''
        # outbound: ${tag} (hybrid SingBox json)
        OB_JSON=$(cat "${jsonFile}")
        _proxy_suite_add_sing_box_ob "$OB_JSON"
        _proxy_suite_record_tag_source ${lib.escapeShellArg tag} static
      ''
    else
      let
        urlSource = if ob.urlFile != null then ob.urlFile else pkgs.writeText "proxy-suite-core" ob.url;
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
      jsonFile = pkgs.writeText "proxy-suite-core" outboundJson;

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
      ${lib.optionalString (!pureXrayEnabled && sshProxyCfg.identityFile != null) ''
        # sing-box opens the key as ${constants.serviceUser}, which cannot read a key in a
        # home directory: it gets a copy only root and its group can read.
        SSH_IDENTITY="$RUNTIME_DIR/ssh-identity"
        install -m 0640 ${constants.ifPrivileged "-g ${constants.serviceUser} "}${lib.escapeShellArg sshProxyCfg.identityFile} "$SSH_IDENTITY"
        OB_JSON=$(${jq} --arg key "$SSH_IDENTITY" '.private_key_path = $key' <<< "$OB_JSON")
      ''}
      ${hostKeyFileBlock}
      ${
        if hybridEnabled then
          ''_proxy_suite_add_sing_box_ob "$OB_JSON"''
        else
          ''OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")''
      }
      _proxy_suite_record_tag_source ${sshProxyTag} ssh
    '';

  # Outbounds whose JSON is known at build time: every backend takes it as is.
  mkFixedOutboundBlock = comment: source: outbound: ''
    # outbound: ${outbound.tag} (${comment})
    OB_JSON=${lib.escapeShellArg (builtins.toJSON outbound)}
    ${
      if hybridEnabled then
        ''_proxy_suite_add_sing_box_ob "$OB_JSON"''
      else
        ''OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")''
    }
    _proxy_suite_record_tag_source ${lib.escapeShellArg outbound.tag} ${source}
  '';

  # WARP and "singBox" or "userspace" AmneziaWG profiles run in a tunnel unit, which restarts them when the
  # handshake stops being answered. Every backend reaches it as a loopback SOCKS hop.
  mkTunnelOutboundBlock =
    unit: source: tag: port:
    mkFixedOutboundBlock "SOCKS hop to ${unit}" source (
      if pureXrayEnabled then
        {
          protocol = "socks";
          inherit tag;
          settings = {
            address = "127.0.0.1";
            inherit port;
          };
        }
      else
        {
          type = "socks";
          inherit tag;
          server = "127.0.0.1";
          server_port = port;
        }
    );

  # An "interface" AmneziaWG profile: the outbound binds to the interface, which has no routes.
  # sing-box resolves its destinations through it too; XRay resolves as usual.
  mkInterfaceOutboundBlock =
    routingMark: ob:
    mkFixedOutboundBlock "bound to ${ob.interface}" "awg" (
      if pureXrayEnabled then
        {
          protocol = "freedom";
          inherit (ob) tag;
          streamSettings.sockopt = {
            inherit (ob) interface;
          }
          // lib.optionalAttrs (routingMark != null) { mark = routingMark; };
        }
      else
        {
          type = "direct";
          inherit (ob) tag;
          bind_interface = ob.interface;
          domain_resolver = constants.awgDnsServerTag ob.tag;
        }
        // lib.optionalAttrs (routingMark != null) { routing_mark = routingMark; }
    );

  mkAwgOutboundBlock =
    routingMark: ob:
    if ob.kind == "interface" then
      mkInterfaceOutboundBlock routingMark ob
    else
      mkTunnelOutboundBlock "proxy-suite-awg-${ob.name}" "awg" ob.tag ob.tunnelPort;

  mkBackendOutboundBlock = if hybridEnabled then mkHybridOutboundBlock else mkOutboundBlock;

  runtimeOutboundsBlock = ''
    # outbounds added at runtime, and the hop each one chains through (<tag>.detour)
    RUNTIME_DETOURS_JSON='{}'
    while IFS=$'\t' read -r RUNTIME_OB_TAG RUNTIME_OB_SRC; do
      [ -n "$RUNTIME_OB_TAG" ] || continue
      case "$RUNTIME_OB_SRC" in
        *.json) _proxy_suite_add_json_outbound "$RUNTIME_OB_TAG" "$RUNTIME_OB_SRC" runtime ;;
        *) _proxy_suite_add_url_outbound "$RUNTIME_OB_TAG" "$(cat "$RUNTIME_OB_SRC")" runtime ;;
      esac || { echo "proxy-suite: warning: ignoring runtime outbound '$RUNTIME_OB_TAG'" >&2; continue; }
      if [ -s "${runtimeOutboundsDir}/$RUNTIME_OB_TAG.detour" ]; then
        RUNTIME_DETOURS_JSON=$(${jq} -c --arg t "$RUNTIME_OB_TAG" --rawfile h "${runtimeOutboundsDir}/$RUNTIME_OB_TAG.detour" \
          '.[$t] = ($h | rtrimstr("\n"))' <<< "$RUNTIME_DETOURS_JSON")
      fi
    done < <(_proxy_suite_runtime_outbounds)
  '';

  # Declared detours, resolved once every outbound - subscription entries included - exists.
  detourMap =
    entries: lib.listToAttrs (map (e: lib.nameValuePair e.tag e.detour) (lib.filter (e: e.detour != null) entries));
  detours = {
    outbounds = detourMap proxyCfg.outbounds;
    subscriptions = detourMap proxyCfg.subscriptions;
  };
  detourKind =
    if hybridEnabled then
      "hybrid"
    else if pureXrayEnabled then
      "xray"
    else
      "sing-box";
  # Always there: `proxy-ctl proxy outbounds add --detour` chains runtime outbounds too. A
  # declared chain that cannot be built fails the start. A runtime one is left out with a
  # warning, like any other runtime outbound that does not come up, rather than going out
  # unchained; whatever chained through it is checked again.
  detourBlock = ''
    # outbound chaining
    DETOURS_JSON=$(${jq} -c --argjson runtime "$RUNTIME_DETOURS_JSON" '.outbounds = $runtime + .outbounds' \
      <<< ${lib.escapeShellArg (builtins.toJSON detours)})
    while [ "$DETOURS_JSON" != '{"outbounds":{},"subscriptions":{}}' ]; do
      DETOUR_RESULT=$(${jq} -c --argjson xob "${
        if hybridEnabled then "$XRAY_OUTBOUNDS_JSON" else "[]"
      }" '{outbounds: ., xray: $xob}' <<< "$OUTBOUNDS_JSON" \
        | ${jq} -c -f ${
          builtins.path {
            name = "proxy-suite-outbound-detours";
            path = ../../outbound-detours.jq;
          }
        } \
          --argjson d "$DETOURS_JSON" \
          --argjson sources "$OUTBOUND_SOURCES_JSON" \
          --arg kind ${detourKind})
      DETOUR_DROP=$(${jq} -c --argjson sources "$OUTBOUND_SOURCES_JSON" \
        '[.errors[] | select($sources[.tag] == "runtime")] | unique_by(.tag)' <<< "$DETOUR_RESULT")
      if ${jq} -e --argjson sources "$OUTBOUND_SOURCES_JSON" 'any(.errors[]; $sources[.tag] != "runtime")' <<< "$DETOUR_RESULT" >/dev/null; then
        ${jq} -r '.errors[] | "proxy-suite: " + .message' <<< "$DETOUR_RESULT" >&2
        exit 1
      fi
      if [ "$DETOUR_DROP" = '[]' ]; then
        OUTBOUNDS_JSON=$(${jq} -c '.outbounds' <<< "$DETOUR_RESULT")
        ${lib.optionalString hybridEnabled ''XRAY_OUTBOUNDS_JSON=$(${jq} -c '.xray' <<< "$DETOUR_RESULT")''}
        break
      fi
      ${jq} -r '.[] | "proxy-suite: warning: ignoring runtime outbound '"'"'\(.tag)'"'"': \(.message)"' <<< "$DETOUR_DROP" >&2
      OUTBOUNDS_JSON=$(${jq} -c --argjson drop "$DETOUR_DROP" '[.[] | select(.tag as $t | $drop | any(.tag == $t) | not)]' <<< "$OUTBOUNDS_JSON")
      ${lib.optionalString hybridEnabled ''XRAY_OUTBOUNDS_JSON=$(${jq} -c --argjson drop "$DETOUR_DROP" '[.[] | select(.tag as $t | $drop | any(.tag == $t) | not)]' <<< "$XRAY_OUTBOUNDS_JSON")''}
      DETOURS_JSON=$(${jq} -c --argjson drop "$DETOUR_DROP" '.outbounds |= with_entries(select(.key as $t | $drop | any(.tag == $t) | not))' <<< "$DETOURS_JSON")
    done
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

    # `proxy-ctl proxy outbounds disable` leaves <tag>.disabled next to the runtime entries:
    # the outbound stays, so rules and chains naming it still work, but nothing picks it on
    # its own - selection, autoProxy and a pin. Markers for tags that are gone are ignored.
    DISABLED_TAGS_JSON='[]'
    if [ -d "${runtimeOutboundsDir}" ]; then
      for DISABLED_MARKER in "${runtimeOutboundsDir}"/*.disabled; do
        [ -e "$DISABLED_MARKER" ] || continue
        DISABLED_TAG="''${DISABLED_MARKER##*/}"
        DISABLED_TAGS_JSON=$(${jq} -c --arg t "''${DISABLED_TAG%.disabled}" '. + [$t]' <<< "$DISABLED_TAGS_JSON")
      done
    fi
    DISABLED_TAGS_JSON=$(${jq} -c --argjson tags "$OUTBOUND_TAGS_JSON" 'map(select(. as $t | $tags | index([$t]))) | unique' <<< "$DISABLED_TAGS_JSON")

    PINNED_OUTBOUND=""
    if [ -r "${pinnedOutboundFile}" ]; then
      PINNED_OUTBOUND="$(tr -d '\r\n[:space:]' < "${pinnedOutboundFile}" 2>/dev/null || true)"
    fi
    if [ -n "$PINNED_OUTBOUND" ] \
      && ! ${jq} -e --arg t "$PINNED_OUTBOUND" 'index($t) != null' <<< "$OUTBOUND_TAGS_JSON" >/dev/null; then
      echo "proxy-suite: warning: pinned outbound '$PINNED_OUTBOUND' is not available; picking automatically" >&2
      PINNED_OUTBOUND=""
    fi
    if [ -n "$PINNED_OUTBOUND" ] \
      && ${jq} -e --arg t "$PINNED_OUTBOUND" 'index($t) != null' <<< "$DISABLED_TAGS_JSON" >/dev/null; then
      echo "proxy-suite: warning: pinned outbound '$PINNED_OUTBOUND' is disabled; picking automatically" >&2
      PINNED_OUTBOUND=""
    fi
  '';

  # What selection may pick on its own: all but proxy.selectionExclude and disabled
  # outbounds. A pin still reaches the excluded ones, and a selector switched by hand both.
  selectableBlock = ''
    SELECTABLE_TAGS_JSON=$(${jq} -c --argjson ex ${lib.escapeShellArg (builtins.toJSON proxyCfg.selectionExclude)} \
      --argjson disabled "$DISABLED_TAGS_JSON" \
      'map(select(. as $t | ($ex + $disabled) | index([$t]) | not))' <<< "$OUTBOUND_TAGS_JSON")
    if [ -z "$PINNED_OUTBOUND" ] && [ "$(${jq} 'length' <<< "$SELECTABLE_TAGS_JSON")" -eq 0 ]; then
      echo "proxy-suite: every outbound is in proxy.selectionExclude or disabled, so there is nothing to select; pin one, enable one (proxy-ctl proxy outbounds enable), or exclude fewer" >&2
      exit 1
    fi
  '';

  # proxy-ctl reads this unprivileged: tags, where each came from, the pin, what each one
  # chains through, what selection leaves alone, and what was disabled.
  inventoryBlock = ''
    ${jq} -n \
      --argjson tags "$OUTBOUND_TAGS_JSON" \
      --argjson sources "$OUTBOUND_SOURCES_JSON" \
      --arg pinned "$PINNED_OUTBOUND" \
      --arg selection ${lib.escapeShellArg selectionMode} \
      --argjson obs "$OUTBOUNDS_JSON" \
      --argjson xobs "${if hybridEnabled then "$XRAY_OUTBOUNDS_JSON" else "[]"}" \
      --argjson selectable "$SELECTABLE_TAGS_JSON" \
      --argjson disabled "$DISABLED_TAGS_JSON" \
      '{tags: $tags, sources: $sources, pinned: $pinned, selection: $selection,
        detours: ([($xobs + $obs)[] | (.detour // .streamSettings.sockopt.dialerProxy?) as $h
          | select($h != null) | {key: .tag, value: $h}] | from_entries),
        excluded: ($tags - $selectable), disabled: $disabled}' \
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
      warpBlock = lib.optionalString (warpCfg.enable && warpCfg.asOutbound == "singBox") (
        mkTunnelOutboundBlock "proxy-suite-warp-tunnel" "warp" "warp" warpCfg.tunnelPort
      );
      awgBlocks = lib.concatMapStrings (mkAwgOutboundBlock routingMark) awgOutbounds;

      wrapperBlock =
        if pureXrayEnabled && selectionMode == "urltest" then
          ''
            OUTBOUNDS_JSON=$(${jq} 'map(.tag = ("proxy-suite-ob-" + .tag)
              | if .streamSettings.sockopt.dialerProxy? then .streamSettings.sockopt.dialerProxy |= "proxy-suite-ob-" + . else . end)' <<< "$OUTBOUNDS_JSON")
            # XRay has no selector: a pin degrades the balancer to the one outbound,
            # which is the same path a single-outbound config already takes.
            if [ -n "$PINNED_OUTBOUND" ]; then
              XRAY_SINGLE_PROXY_TAG="proxy-suite-ob-$PINNED_OUTBOUND"
            elif [ "$(${jq} 'length' <<< "$SELECTABLE_TAGS_JSON")" -eq 1 ]; then
              XRAY_SINGLE_PROXY_TAG="proxy-suite-ob-$(${jq} -r '.[0]' <<< "$SELECTABLE_TAGS_JSON")"
            fi
          ''
        else if collapseNamedOutbounds then
          ''
            PROXY_TAG="$PINNED_OUTBOUND"
            if [ -z "$PROXY_TAG" ]; then
              PROXY_TAG=$(${jq} -r '.[0]' <<< "$SELECTABLE_TAGS_JSON")
            fi
            # Every tag stays, so rules naming another outbound still reach it; "proxy"
            # only stands for the pick.
            ${
              if pureXrayEnabled then
                ''XRAY_SINGLE_PROXY_TAG="$PROXY_TAG"''
              else
                ''OUTBOUNDS_JSON=$(${jq} --arg t "$PROXY_TAG" '[{type:"selector",tag:"proxy",outbounds:[$t],default:$t}] + .' <<< "$OUTBOUNDS_JSON")''
            }
          ''
        else if selectionMode == "selector" then
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            DEFAULT_TAG="$PINNED_OUTBOUND"
            if [ -z "$DEFAULT_TAG" ]; then
              DEFAULT_TAG=$(${jq} -r '.[0]' <<< "$SELECTABLE_TAGS_JSON")
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
            if [ -n "$PINNED_OUTBOUND" ]; then
              # A pin beats latency ranking: the same outbounds, behind a selector
              # the Clash API can also switch live.
              WRAPPER=$(${jq} -n \
                --argjson tags "$TAGS" \
                --arg default "$PINNED_OUTBOUND" \
                '{type:"selector",tag:"proxy",outbounds:$tags,default:$default}')
            else
              WRAPPER=$(${jq} -n \
                --argjson tags "$SELECTABLE_TAGS_JSON" \
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
    + awgBlocks
    + detourBlock
    + requireOutboundsBlock
    + pinBlock
    + selectableBlock
    + inventoryBlock
    + wrapperBlock
    + exitTagsBlock;
in
{
  inherit mkOutboundScript rawOutboundJson;
  # For the checks: which outbounds a pin and selection may take.
  selectionBlocks = pinBlock + selectableBlock + inventoryBlock;
}
