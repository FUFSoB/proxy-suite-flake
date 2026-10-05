{
  lib,
  pkgs,
  singBoxCfg,
  proxyCfg,
  sshProxyCfg,
  warpCfg,
  torCfg,
  whitelistBypassJoiners,
  awgOutbounds,
  awgRuntimeOutbounds ? false,
  awgRuntimeIfaceOutbounds ? false,
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
  laterTags ? [ ],
  # The backends, to check a runtime JSON outbound with before it joins the config.
  singBoxBin ? null,
  xrayBin ? null,
}:

let
  # A value in a shell comment, on that one line: a newline in a tag (types.str) would end
  # the comment and run the rest as root.
  oneLine = value: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] (toString value);

  sshProxyTag = "ssh-proxy";
  torOutboundEnabled = torCfg != null && torCfg.enable && torCfg.asOutbound;
  groupsJq = builtins.path {
    name = "proxy-suite-outbound-groups";
    path = ../../outbound-groups.jq;
  };
  # `proxy-ctl proxy pin <tag> --in <group>`: one file per group, next to the top-level pin.
  groupPinsDir = "${dirOf pinnedOutboundFile}/group-pins";

  # The keys of an outbound that point the backend at a local file or program, comma-joined;
  # a sing-box tor outbound as "type: tor". proxy_url_parsers.local_file_keys and proxy-ctl's
  # _local_file_keys apply the same rule. A non-ASCII key counts as well: Go's JSON
  # decoding matches field names under Unicode case folding ("maſterKeyLog" is masterKeyLog).
  localFileKeysJq = ''
    [(if .type == "tor" then "type: tor" else empty end),
     (.. | objects | keys[] | ascii_downcase
      | select((explode | any(. > 127)) or endswith("file") or (endswith("path") and . != "path")
          or endswith("directory") or IN("masterkeylog", "torrc", "extra_args")))]
    | unique | join(", ")
  '';

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
                _proxy_suite_check_url_outbound xray "$ob" "$tag" "$source" || return 1
                _proxy_suite_add_xray_sidecar_ob "$ob" "$tag"
                ;;
              sing-box)
                ob=$(_proxy_suite_parse_sing_box_url "$tag" "$url") || return 1
                _proxy_suite_check_url_outbound sing-box "$ob" "$tag" "$source" || return 1
                _proxy_suite_add_sing_box_ob "$ob"
                ;;
              *)
                # Created 0600 first: the parser's error can quote the link's id or password,
                # and the runtime directory is world-listable.
                (umask 077 && : > "$RUNTIME_DIR/sing-box-parser.err")
                # One sing-box parses but refuses still gets XRay's turn.
                if ob=$(_proxy_suite_parse_sing_box_url "$tag" "$url" 2>"$RUNTIME_DIR/sing-box-parser.err") &&
                  _proxy_suite_check_url_outbound sing-box "$ob" "$tag" "$source" 2>/dev/null; then
                  _proxy_suite_add_sing_box_ob "$ob"
                elif ob=$(_proxy_suite_parse_xray_url "$tag" "$url"); then
                  _proxy_suite_check_url_outbound xray "$ob" "$tag" "$source" || return 1
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
            _proxy_suite_check_url_outbound ${
              if pureXrayEnabled then "xray" else "sing-box"
            } "$ob" "$tag" "$source" || return 1
            OUTBOUNDS_JSON=$(${jq} --slurpfile ob <(printf '%s' "$ob") '. + $ob' <<< "$OUTBOUNDS_JSON")
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
            OUTBOUNDS_JSON=$(${jq} --slurpfile ob <(printf '%s' "$ob") '. + [$ob[0]${
              if pureXrayEnabled then xrayMark else singBoxMark
            }]' <<< "$OUTBOUNDS_JSON")
          '';
    in
    ''
      ${constants.readSourceFunction pkgs}
      OUTBOUND_SOURCES_JSON='{}'
      # What proxy-ctl shares back: tag -> the URL it was given, sub tag -> its URL.
      OUTBOUND_URLS_JSON='{}'
      SUBSCRIPTION_URLS_JSON='{}'

      _proxy_suite_record_tag_source() {
        OUTBOUND_SOURCES_JSON=$(${jq} --arg t "$1" --arg s "$2" '.[$t] = $s' <<< "$OUTBOUND_SOURCES_JSON")
      }

      # $1 tag, $2 loopback SOCKS port, $3 source label: mkTunnelOutboundBlock, for a port
      # only known at runtime (an AmneziaWG outbound added with proxy-ctl).
      _proxy_suite_add_socks_hop() {
        local ob
        # A runtime one's port comes from the group-writable spool: any other JSON would
        # reach the config as it is.
        case "$2" in
          "" | *[!0-9]*) return 1 ;;
        esac
        [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || return 1
        # The tunnel's listener takes the hop login (constants.ensureHopLogin).
        ${constants.ensureHopLogin pkgs}
        ob=$(${jq} -nc --arg t "$1" --argjson p "$2" --arg u ${constants.hopUser} \
          --rawfile pw ${lib.escapeShellArg constants.hopLoginFile} ${
            lib.escapeShellArg (
              if pureXrayEnabled then
                ''{protocol: "socks", tag: $t, settings: {address: "127.0.0.1", port: $p, user: $u, pass: ($pw | rtrimstr("\n"))}}''
              else
                ''{type: "socks", tag: $t, server: "127.0.0.1", server_port: $p, username: $u, password: ($pw | rtrimstr("\n"))}''
            )
          }) || return 1
        ${
          if hybridEnabled then
            ''_proxy_suite_add_sing_box_ob "$ob"''
          else
            ''OUTBOUNDS_JSON=$(${jq} --slurpfile ob <(printf '%s' "$ob") '. + $ob' <<< "$OUTBOUNDS_JSON")''
        }
        _proxy_suite_record_tag_source "$1" "$3"
      }

      ${lib.optionalString awgRuntimeIfaceOutbounds ''
        # $1 tag, $2 its slot: an AmneziaWG outbound added at runtime on an interface of its
        # own, as mkInterfaceOutboundBlock has it. sing-box resolves through the interface
        # with a server the backend filter adds for awg-dns-<tag>; XRay resolves as usual.
        _proxy_suite_add_awg_interface() {
          local ob
          case "$2" in
            "" | *[!0-9]*) return 1 ;;
          esac
          [ "$2" -lt ${toString constants.awgRuntimeIfaceSlots} ] || return 1
          ob=$(${jq} -nc --arg t "$1" --arg i "${constants.awgRuntimeIfacePrefix}$2" ${
            lib.escapeShellArg (
              if pureXrayEnabled then
                ''{protocol: "freedom", tag: $t, streamSettings: {sockopt: ({interface: $i}${
                  lib.optionalString (routingMark != null) " + {mark: ${toString routingMark}}"
                })}}''
              else
                ''{type: "direct", tag: $t, bind_interface: $i, domain_resolver: ("${constants.awgDnsServerTag ""}" + $t)}${
                  lib.optionalString (routingMark != null) " + {routing_mark: ${toString routingMark}}"
                }''
            )
          }) || return 1
          ${
            if hybridEnabled then
              ''_proxy_suite_add_sing_box_ob "$ob"''
            else
              ''OUTBOUNDS_JSON=$(${jq} --slurpfile ob <(printf '%s' "$ob") '. + $ob' <<< "$OUTBOUNDS_JSON")''
          }
          _proxy_suite_record_tag_source "$1" awg
        }
      ''}

      # $1 sub tag, $2 file holding its URL, $3 its links file (absent for a cache
      # written before links existed: those entries share as JSON until the next update).
      _proxy_suite_record_subscription_share() {
        SUBSCRIPTION_URLS_JSON=$(${jq} --arg t "$1" --rawfile u <(_proxy_suite_read_source "$2") '.[$t] = ($u | rtrimstr("\n"))' <<< "$SUBSCRIPTION_URLS_JSON")
        # Only the entries merged (_proxy_suite_record_outbound_source ran first): one left
        # out for a taken tag would otherwise put its link on that tag's outbound.
        if [ -s "$3" ]; then
          OUTBOUND_URLS_JSON=$(${jq} --slurpfile l "$3" --arg s "sub:$1" \
            --slurpfile sources <(printf '%s' "$OUTBOUND_SOURCES_JSON") \
            '. + ($l[0] | with_entries(select($sources[0][.key] == $s)))' <<< "$OUTBOUND_URLS_JSON") || true
        fi
      }

      # $1 source label, $2 array length before the add, $3 after. Subscriptions
      # append an unknown number of outbounds, so they label them by range.
      # Here and below, whatever grows with the outbounds goes to jq through a file, not
      # --argjson: a big subscription outgrows the kernel's 128 KiB limit on one argument.
      _proxy_suite_record_outbound_source() {
        [ "$3" -gt "$2" ] || return 0
        OUTBOUND_SOURCES_JSON=$(${jq} \
          --slurpfile sources <(printf '%s' "$OUTBOUND_SOURCES_JSON") --arg s "$1" \
          --argjson b "$2" --argjson a "$3" \
          'reduce .[$b:$a][].tag as $t ($sources[0]; .[$t] = $s)' <<< "$OUTBOUNDS_JSON")
      }

      ${
        if hybridEnabled then
          ''
            _proxy_suite_parse_sing_box_url() {
              ${parse "--backend sing-box" markArg}
            }

            _proxy_suite_parse_xray_url() {
              ${parse "--backend xray" (
                lib.optionalString (
                  xraySidecarRoutingMark != null
                ) " --routing-mark ${toString xraySidecarRoutingMark}"
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
      # $1 kind, $2 the outbound parsed from a URL, $3 tag, $4 source label: a runtime one
      # through the backend's own check, as for runtime JSON.
      _proxy_suite_check_url_outbound() {
        [ "$4" = runtime ] || return 0
        _proxy_suite_check_json_outbound "$1" "$2" && return 0
        echo "proxy-suite: runtime outbound '$3' is not one the backend takes" >&2
        return 1
      }

      # $1 tag, $2 URL, $3 source label, $4 backend preference (auto|sing-box|xray).
      # Returns non-zero when the URL cannot be parsed; the caller decides whether
      # that is fatal.
      _proxy_suite_add_url_outbound() {
        local tag="$1" url="$2" source="$3" pref="''${4:-auto}" ob
        ${addBlock}
        _proxy_suite_record_tag_source "$tag" "$source"
        OUTBOUND_URLS_JSON=$(${jq} --arg t "$tag" --rawfile u <(printf '%s' "$url") '.[$t] = $u' <<< "$OUTBOUND_URLS_JSON")
      }

      # $1 kind, $2 the outbound: whether its backend takes it, as one it refuses would fail
      # the whole start. Alone (its references dropped), as the service user, from stdin.
      _proxy_suite_check_json_outbound() {
        local kind="$1" ob="$2" as=()
        [ "$(${pkgs.coreutils}/bin/id -u)" = 0 ] && as=(${constants.runAsServiceUser pkgs [ ]})
        case "$kind" in
          ${lib.optionalString (singBoxBin != null) ''
            sing-box)
              ${jq} -c '{outbounds: [del(.detour, .domain_resolver) | select(.type != "selector" and .type != "urltest")]}' <<< "$ob" \
                | "''${as[@]}" ${singBoxBin} check -c /dev/stdin >/dev/null 2>&1
              ;;
          ''}
          ${lib.optionalString (xrayBin != null) ''
            xray)
              ${jq} -c '{outbounds: [del(.proxySettings) | del(.streamSettings.sockopt.dialerProxy)]}' <<< "$ob" \
                | "''${as[@]}" ${xrayBin} run -test -format json -c stdin: >/dev/null 2>&1
              ;;
          ''}
          *) return 0 ;;
        esac
      }

      # $1 tag, $2 file holding one sing-box or XRay outbound, $3 source label.
      _proxy_suite_add_json_outbound() {
        local tag="$1" source="$3" ob kind unsafe
        ob=$(${jq} -ce --arg t "$tag" 'select(type == "object") | .tag = $t' <(_proxy_suite_read_source "$2") 2>/dev/null) || return 1
        # The runtime spool is group-writable, and the backend holds CAP_NET_ADMIN and the
        # daemon user's files: a sing-box tor outbound's executable_path is a program it runs
        # with them, a *_path or *File one it reads, XRay's masterKeyLog one it writes. Only a
        # declared outbound may name those.
        if [ "$source" = runtime ]; then
          unsafe=$(${jq} -r ${lib.escapeShellArg localFileKeysJq} <<< "$ob")
          if [ -n "$unsafe" ]; then
            echo "proxy-suite: runtime outbound '$tag' names local files or programs ($unsafe); declare it in proxy.outbounds instead" >&2
            return 1
          fi
        fi
        kind=$(${jq} -r 'if has("protocol") then "xray" elif has("type") then "sing-box" else "" end' <<< "$ob")
        if [ "$source" = runtime ] && ! _proxy_suite_check_json_outbound "$kind" "$ob"; then
          echo "proxy-suite: runtime outbound '$tag' is not one the backend takes (a field misspelt, or one it no longer has)" >&2
          return 1
        fi
        ${jsonAddBlock}
        _proxy_suite_record_tag_source "$tag" "$source"
      }

      # Every runtime outbound, as "<tag>\t<file>" lines: <tag>.url, <tag>.json or <tag>.awg (an
      # AmneziaWG config, behind a tunnel on the port in <tag>.port). proxy-ctl refuses
      # the reserved names, but the spool is group-writable, so check again here:
      # a second outbound tagged "proxy" would quietly shadow the real one.
      _proxy_suite_runtime_outbounds() {
        local f tag
        [ -d "${runtimeOutboundsDir}" ] || return 0
        for f in "${runtimeOutboundsDir}"/*.url "${runtimeOutboundsDir}"/*.json${lib.optionalString awgRuntimeOutbounds ''"${runtimeOutboundsDir}"/*.awg''}; do
          [ -f "$f" ] && [ ! -L "$f" ] || continue
          tag="''${f##*/}"
          tag="''${tag%.*}"
          # A tab or newline in a name would split the line into entries of its own.
          if [[ ! $tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo "proxy-suite: warning: ignoring a runtime outbound whose name is not a valid tag" >&2
            continue
          fi
          case "$tag" in
            # proxy-suite-*: the test selector and the pin selectors the start script adds;
            # priority.json is the priority overrides, not an outbound.
            proxy | direct | block | priority | proxy-suite-*${lib.optionalString torOutboundEnabled " | tor"})
              [ "$f" = "${runtimeOutboundsDir}/priority.json" ] && continue
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
        # outbound: ${oneLine tag} (static ${backend} json)
        OB_JSON=$(cat "${jsonFile}")
        OUTBOUNDS_JSON=$(${jq} --slurpfile ob <(printf '%s' "$OB_JSON") '. + $ob' <<< "$OUTBOUNDS_JSON")
        _proxy_suite_record_tag_source ${lib.escapeShellArg tag} static
      ''
    else
      let
        urlSource = if ob.urlFile != null then ob.urlFile else pkgs.writeText "proxy-suite-core" ob.url;
      in
      ''
        # outbound: ${oneLine tag}
        _proxy_suite_add_url_outbound ${lib.escapeShellArg tag} "$(cat ${lib.escapeShellArg urlSource})" static || exit 1
      '';

  singBoxRawOutboundJson =
    ob: tag: routingMark:
    ob.singBoxJson
    // {
      inherit tag;
    }
    // lib.optionalAttrs (routingMark != null) { routing_mark = routingMark; };

  mkHybridOutboundBlock =
    ob: routingMark: tag:
    if ob.xrayJson != null then
      let
        # The sidecar helper adds the tag, its mark, and UseIP unless one is set.
        outboundJson = builtins.toJSON ob.xrayJson;
        jsonFile = pkgs.writeText "proxy-suite-core" outboundJson;
      in
      ''
        # outbound: ${oneLine tag} (hybrid XRay json sidecar)
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
        # outbound: ${oneLine tag} (hybrid SingBox json)
        OB_JSON=$(cat "${jsonFile}")
        _proxy_suite_add_sing_box_ob "$OB_JSON"
        _proxy_suite_record_tag_source ${lib.escapeShellArg tag} static
      ''
    else
      let
        urlSource = if ob.urlFile != null then ob.urlFile else pkgs.writeText "proxy-suite-core" ob.url;
      in
      ''
        # outbound: ${oneLine tag} (hybrid ${ob.backend})
        _proxy_suite_add_url_outbound ${lib.escapeShellArg tag} "$(cat ${lib.escapeShellArg urlSource})" static ${ob.backend} || exit 1
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
          echo "proxy-suite: no host keys for "${lib.escapeShellArg knownHostsTarget}" in "${lib.escapeShellArg sshProxyCfg.hostKeyFile} >&2
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
        install -m ${
          if constants.privileged then "0640" else "0600"
        } ${constants.ifPrivileged "-g ${constants.serviceUser} "}${lib.escapeShellArg sshProxyCfg.identityFile} "$SSH_IDENTITY"
        OB_JSON=$(${jq} --arg key "$SSH_IDENTITY" '.private_key_path = $key' <<< "$OB_JSON")
      ''}
      ${hostKeyFileBlock}
      ${
        if hybridEnabled then
          ''_proxy_suite_add_sing_box_ob "$OB_JSON"''
        else
          ''OUTBOUNDS_JSON=$(${jq} --slurpfile ob <(printf '%s' "$OB_JSON") '. + $ob' <<< "$OUTBOUNDS_JSON")''
      }
      _proxy_suite_record_tag_source ${sshProxyTag} ssh
    '';

  # Outbounds whose JSON is known at build time: every backend takes it as is.
  mkFixedOutboundBlock = comment: source: outbound: ''
    # outbound: ${oneLine outbound.tag} (${comment})
    OB_JSON=${lib.escapeShellArg (builtins.toJSON outbound)}
    ${
      if hybridEnabled then
        ''_proxy_suite_add_sing_box_ob "$OB_JSON"''
      else
        ''OUTBOUNDS_JSON=$(${jq} --slurpfile ob <(printf '%s' "$OB_JSON") '. + $ob' <<< "$OUTBOUNDS_JSON")''
    }
    _proxy_suite_record_tag_source ${lib.escapeShellArg outbound.tag} ${source}
  '';

  # As mkFixedOutboundBlock, with the hop login added at start: it is drawn per boot, and
  # the password reaches jq from its file, never argv.
  mkHopOutboundBlock = comment: source: outbound: ''
    # outbound: ${oneLine outbound.tag} (${comment})
    ${constants.ensureHopLogin pkgs}
    OB_JSON=$(${jq} -c --arg u ${constants.hopUser} --rawfile pw ${lib.escapeShellArg constants.hopLoginFile} ${
      lib.escapeShellArg (
        if pureXrayEnabled then
          ''.settings += {user: $u, pass: ($pw | rtrimstr("\n"))}''
        else
          ''. + {username: $u, password: ($pw | rtrimstr("\n"))}''
      )
    } <<< ${lib.escapeShellArg (builtins.toJSON outbound)})
    ${
      if hybridEnabled then
        ''_proxy_suite_add_sing_box_ob "$OB_JSON"''
      else
        ''OUTBOUNDS_JSON=$(${jq} --slurpfile ob <(printf '%s' "$OB_JSON") '. + $ob' <<< "$OUTBOUNDS_JSON")''
    }
    _proxy_suite_record_tag_source ${lib.escapeShellArg outbound.tag} ${source}
  '';

  # WARP and "singBox" or "userspace" AmneziaWG profiles run in a tunnel unit, which restarts them when the
  # handshake stops being answered. Every backend reaches it as a loopback SOCKS hop.
  # Every hop but Tor's takes the hop login (constants.ensureHopLogin); Tor has none to take.
  mkTunnelOutboundBlock =
    unit: source: tag: port:
    (if source == "tor" then mkFixedOutboundBlock else mkHopOutboundBlock) "SOCKS hop to ${unit}" source
      (
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
        // lib.optionalAttrs (ob.domainStrategy != null) {
          settings.domainStrategy =
            {
              prefer_ipv4 = "UseIPv4v6";
              prefer_ipv6 = "UseIPv6v4";
              ipv4_only = "UseIPv4";
              ipv6_only = "UseIPv6";
            }
            .${ob.domainStrategy};
        }
      else
        {
          type = "direct";
          inherit (ob) tag;
          bind_interface = ob.interface;
          domain_resolver =
            if ob.domainStrategy == null then
              constants.awgDnsServerTag ob.tag
            else
              {
                server = constants.awgDnsServerTag ob.tag;
                strategy = ob.domainStrategy;
              };
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

  # Tags a runtime outbound may not take: the outbounds added after it, the groups (declared
  # and runtime), and the backend template's own. Those already in (declared, subscriptions,
  # an earlier runtime one under another extension) are checked as it comes.
  runtimeTakenTags = laterTags ++ lib.optional pureXrayEnabled "dns-out";
  runtimeOutboundsBlock = ''
    # outbounds added at runtime, and the hop each one chains through (<tag>.detour)
    RUNTIME_DETOURS_JSON='{}'
    RUNTIME_TAKEN_JSON=$(
      for f in "${runtimeOutboundsDir}"/*.group; do
        [ -e "$f" ] || continue
        f="''${f##*/}"
        printf '%s\n' "''${f%.group}"
      done | ${jq} -R . | ${jq} -cs --argjson fixed ${lib.escapeShellArg (builtins.toJSON runtimeTakenTags)} '. + $fixed'
    )
    while IFS=$'\t' read -r RUNTIME_OB_TAG RUNTIME_OB_SRC; do
      [ -n "$RUNTIME_OB_TAG" ] || continue
      # A duplicate tag fails the backend's start, every outbound with it: this one goes.
      if {
        printf '%s\n' "''${OUTBOUNDS_JSON:-[]}"
        ${lib.optionalString hybridEnabled ''printf '%s\n' "''${XRAY_OUTBOUNDS_JSON:-[]}"''}
      } | ${jq} -e -s --arg t "$RUNTIME_OB_TAG" --argjson taken "$RUNTIME_TAKEN_JSON" \
        '(add | [.[].tag]) + $taken | index([$t]) != null' >/dev/null 2>&1; then
        echo "proxy-suite: warning: ignoring runtime outbound '$RUNTIME_OB_TAG': the tag is taken" >&2
        continue
      fi
      case "$RUNTIME_OB_SRC" in
        *.json) _proxy_suite_add_json_outbound "$RUNTIME_OB_TAG" "$RUNTIME_OB_SRC" runtime ;;
        # Its tunnel (proxy-suite-awg-tunnel@<tag>) checks the port again before listening.
        *.awg)
          ${lib.optionalString awgRuntimeIfaceOutbounds ''
            if [ -e "${runtimeOutboundsDir}/$RUNTIME_OB_TAG.iface" ]; then
              _proxy_suite_add_awg_interface "$RUNTIME_OB_TAG" "$(_proxy_suite_read_source "${runtimeOutboundsDir}/$RUNTIME_OB_TAG.iface" 2>/dev/null | head -n 1)"
            else
          ''}
          _proxy_suite_add_socks_hop "$RUNTIME_OB_TAG" "$(_proxy_suite_read_source "${runtimeOutboundsDir}/$RUNTIME_OB_TAG.port" 2>/dev/null | head -n 1)" runtime
          ${lib.optionalString awgRuntimeIfaceOutbounds "fi"}
          ;;
        *) _proxy_suite_add_url_outbound "$RUNTIME_OB_TAG" "$(_proxy_suite_read_source "$RUNTIME_OB_SRC")" runtime ;;
      esac || { echo "proxy-suite: warning: ignoring runtime outbound '$RUNTIME_OB_TAG'" >&2; continue; }
      if [ -s "${runtimeOutboundsDir}/$RUNTIME_OB_TAG.detour" ]; then
        RUNTIME_DETOURS_JSON=$(${jq} -c --arg t "$RUNTIME_OB_TAG" --rawfile h <(_proxy_suite_read_source "${runtimeOutboundsDir}/$RUNTIME_OB_TAG.detour") \
          '.[$t] = ($h | rtrimstr("\n"))' <<< "$RUNTIME_DETOURS_JSON")
      fi
    done < <(_proxy_suite_runtime_outbounds)
  '';

  # Declared detours, resolved once every outbound - subscription entries included - exists.
  detourMap =
    entries:
    lib.listToAttrs (
      map (e: lib.nameValuePair e.tag e.detour) (lib.filter (e: e.detour != null) entries)
    );
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
    DETOURS_JSON=$(${jq} -c --slurpfile runtime <(printf '%s' "$RUNTIME_DETOURS_JSON") '.outbounds = $runtime[0] + .outbounds' \
      <<< ${lib.escapeShellArg (builtins.toJSON detours)})
    while [ "$DETOURS_JSON" != '{"outbounds":{},"subscriptions":{}}' ]; do
      # The filter reads $sources as the object itself, so the program unwraps the slurped one.
      DETOUR_RESULT=$(${jq} -c --slurpfile xob <(printf '%s' "${
        if hybridEnabled then "$XRAY_OUTBOUNDS_JSON" else "[]"
      }") '{outbounds: ., xray: $xob[0]}' <<< "$OUTBOUNDS_JSON" \
        | ${jq} -c -f <(printf '%s' '$sources[0] as $sources | '; cat ${
          builtins.path {
            name = "proxy-suite-outbound-detours";
            path = ../../outbound-detours.jq;
          }
        }) \
          --argjson d "$DETOURS_JSON" \
          --slurpfile sources <(printf '%s' "$OUTBOUND_SOURCES_JSON") \
          --arg kind ${detourKind})
      DETOUR_DROP=$(${jq} -c --slurpfile sources <(printf '%s' "$OUTBOUND_SOURCES_JSON") \
        '[.errors[] | select($sources[0][.tag] == "runtime")] | unique_by(.tag)' <<< "$DETOUR_RESULT")
      if ${jq} -e --slurpfile sources <(printf '%s' "$OUTBOUND_SOURCES_JSON") 'any(.errors[]; $sources[0][.tag] != "runtime")' <<< "$DETOUR_RESULT" >/dev/null; then
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
  tagsBlock = ''
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
    DISABLED_TAGS_JSON=$(${jq} -c --slurpfile tags <(printf '%s' "$OUTBOUND_TAGS_JSON") 'map(select(. as $t | $tags[0] | index([$t]))) | unique' <<< "$DISABLED_TAGS_JSON")
  '';

  # proxy.groups and those `proxy-ctl proxy groups add` left as <tag>.group next to the runtime
  # outbounds (a declared one wins), resolved against the outbounds this start has: members
  # from subscriptions and patterns only exist now. The group outbounds join the rest; what
  # the top level picks among is ungrouped outbounds and outermost groups, by priority.
  groupsBlock =
    let
      declared = lib.mapAttrs (_: g: {
        inherit (g)
          outbounds
          subscriptions
          match
          strategy
          failback
          interval
          ;
      }) proxyCfg.groups;
    in
    ''
      GROUPS_CONFIG_JSON=${lib.escapeShellArg (builtins.toJSON declared)}
      PRIORITY_JSON=${lib.escapeShellArg (builtins.toJSON proxyCfg.priority)}
      GROUP_PINS_JSON='{}'
      ${lib.optionalString (!pureXrayEnabled) ''
        if [ -d "${runtimeOutboundsDir}" ]; then
          for GROUP_FILE in "${runtimeOutboundsDir}"/*.group; do
            [ -e "$GROUP_FILE" ] || continue
            GROUP_NAME="''${GROUP_FILE##*/}"
            GROUP_NAME="''${GROUP_NAME%.group}"
            # As proxy-ctl names them; the spool is group-writable, and a group tagged "proxy"
            # would shadow the real selector.
            case "$GROUP_NAME" in
              proxy | direct | block | proxy-suite-*${lib.optionalString torOutboundEnabled " | tor"} | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
                echo "proxy-suite: warning: ignoring runtime group '$GROUP_NAME': reserved or invalid name" >&2
                continue
                ;;
            esac
            if ${jq} -e --arg g "$GROUP_NAME" 'has($g)' <<< "$GROUPS_CONFIG_JSON" >/dev/null; then
              echo "proxy-suite: warning: ignoring runtime group '$GROUP_NAME': proxy.groups declares it" >&2
              continue
            fi
            if ! GROUP_JSON=$(_proxy_suite_read_source "$GROUP_FILE" | ${jq} -ce '
              {outbounds: (.outbounds // []), subscriptions: (.subscriptions // []), match: (.match // []),
               strategy: (.strategy // "failover"), failback: (.failback != false), interval: (.interval // null),
               runtime: true}
              | select(.strategy | IN("failover", "urltest", "selector"))
              | select([.outbounds, .subscriptions, .match] | all(type == "array" and all(type == "string")))
              | select(.interval == null or (.interval | type == "string" and test("^([0-9]+(\\.[0-9]+)?(ns|us|ms|s|m|h))+$")))'); then
              echo "proxy-suite: warning: ignoring runtime group '$GROUP_NAME': not a valid group" >&2
              continue
            fi
            GROUPS_CONFIG_JSON=$(${jq} -c --arg g "$GROUP_NAME" --argjson v "$GROUP_JSON" '.[$g] = $v' <<< "$GROUPS_CONFIG_JSON")
          done
          if [ -f "${runtimeOutboundsDir}/priority.json" ]; then
            if RUNTIME_PRIORITY_JSON=$(_proxy_suite_read_source "${runtimeOutboundsDir}/priority.json" \
              | ${jq} -ce 'select(type == "object" and all(.[]; type == "number")) | map_values(floor)'); then
              PRIORITY_JSON=$(${jq} -c --argjson r "$RUNTIME_PRIORITY_JSON" '. + $r' <<< "$PRIORITY_JSON")
            else
              echo "proxy-suite: warning: ignoring ${runtimeOutboundsDir}/priority.json: not {tag: number}" >&2
            fi
          fi
        fi
        if [ -d "${groupPinsDir}" ]; then
          for GROUP_PIN_FILE in "${groupPinsDir}"/*; do
            [ -f "$GROUP_PIN_FILE" ] || continue
            GROUP_PINS_JSON=$(${jq} -c --arg g "''${GROUP_PIN_FILE##*/}" \
              --arg t "$(tr -d '\r\n[:space:]' < "$GROUP_PIN_FILE" 2>/dev/null || true)" '.[$g] = $t' <<< "$GROUP_PINS_JSON")
          done
        fi
      ''}
      # A runtime outbound may have taken a group's name: the outbound stays.
      while IFS= read -r GROUP_NAME; do
        echo "proxy-suite: warning: ignoring group '$GROUP_NAME': an outbound has that tag" >&2
        GROUPS_CONFIG_JSON=$(${jq} -c --arg g "$GROUP_NAME" 'del(.[$g])' <<< "$GROUPS_CONFIG_JSON")
      done < <(${jq} -r --slurpfile tags <(printf '%s' "$OUTBOUND_TAGS_JSON") 'keys[] | select(. as $g | $tags[0] | index([$g]))' <<< "$GROUPS_CONFIG_JSON")
      # A runtime group inside itself is left out, like any runtime outbound that cannot be
      # built; only a loop among declared groups fails the start.
      while :; do
        GROUPS_RESULT=$(${jq} -nc --slurpfile tags <(printf '%s' "$OUTBOUND_TAGS_JSON") \
          --slurpfile sources <(printf '%s' "''${OUTBOUND_SOURCES_JSON:-{\}}") \
          '{tags: $tags[0], sources: $sources[0]}' \
          | ${jq} -c -f ${groupsJq} \
            --argjson groups "$GROUPS_CONFIG_JSON" \
            --argjson priority "$PRIORITY_JSON" \
            --argjson disabled "$DISABLED_TAGS_JSON" \
            --argjson pins "$GROUP_PINS_JSON" \
            --arg url ${lib.escapeShellArg proxyCfg.urlTest.url} \
            --arg interval ${lib.escapeShellArg proxyCfg.urlTest.interval} \
            --argjson tolerance ${toString singBoxCfg.urlTest.tolerance} \
            --argjson watched "''${GROUPS_WATCHED:-true}")
        GROUPS_LOOP_DROP=$(${jq} -c --argjson g "$GROUPS_CONFIG_JSON" '[.loops[] | select($g[.].runtime == true)]' <<< "$GROUPS_RESULT")
        [ "$GROUPS_LOOP_DROP" != '[]' ] || break
        ${jq} -r '.[] | "proxy-suite: warning: ignoring runtime group '"'"'\(.)'"'"': it contains itself"' <<< "$GROUPS_LOOP_DROP" >&2
        GROUPS_CONFIG_JSON=$(${jq} -c --argjson drop "$GROUPS_LOOP_DROP" 'with_entries(select(.key as $k | $drop | index([$k]) | not))' <<< "$GROUPS_CONFIG_JSON")
      done
      ${jq} -r '.warnings[] | "proxy-suite: warning: " + .' <<< "$GROUPS_RESULT" >&2
      if ${jq} -e '.errors != []' <<< "$GROUPS_RESULT" >/dev/null; then
        ${jq} -r '.errors[] | "proxy-suite: " + .' <<< "$GROUPS_RESULT" >&2
        exit 1
      fi
      GROUP_TAGS_JSON=$(${jq} -c '.groups | keys_unsorted' <<< "$GROUPS_RESULT")
      GROUPS_INFO_JSON=$(${jq} -c '.groups' <<< "$GROUPS_RESULT")
      TOP_TAGS_JSON=$(${jq} -c '.top' <<< "$GROUPS_RESULT")
      OUTBOUNDS_JSON=$(${jq} -c --slurpfile g <(${jq} -c '.outbounds' <<< "$GROUPS_RESULT") '. + $g[0]' <<< "$OUTBOUNDS_JSON")
    '';

  pinBlock = ''
    PINNED_OUTBOUND=""
    if [ -r "${pinnedOutboundFile}" ]; then
      PINNED_OUTBOUND="$(tr -d '\r\n[:space:]' < "${pinnedOutboundFile}" 2>/dev/null || true)"
    fi
    if [ -n "$PINNED_OUTBOUND" ] \
      && ! ${jq} -e --arg t "$PINNED_OUTBOUND" --argjson groups "$GROUP_TAGS_JSON" '. + $groups | index([$t]) != null' <<< "$OUTBOUND_TAGS_JSON" >/dev/null; then
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
  # Tor is only for what is routed to it, unless it is the one outbound there is.
  selectableBlock = ''
    SELECTABLE_TAGS_JSON=$(${jq} -c --argjson ex ${lib.escapeShellArg (builtins.toJSON proxyCfg.selectionExclude)} \
      --argjson disabled "$DISABLED_TAGS_JSON" \
      '${lib.optionalString torOutboundEnabled "(if length > 1 then [\"tor\"] else [] end) as $tor | "}map(select(. as $t | ($ex + $disabled${lib.optionalString torOutboundEnabled " + $tor"}) | index([$t]) | not))' <<< "$TOP_TAGS_JSON")
    if [ -z "$PINNED_OUTBOUND" ] && [ "$(${jq} 'length' <<< "$SELECTABLE_TAGS_JSON")" -eq 0 ]; then
      echo "proxy-suite: every outbound is in proxy.selectionExclude or disabled, so there is nothing to select; pin one, enable one (proxy-ctl proxy outbounds enable), or exclude fewer" >&2
      exit 1
    fi
  '';

  # proxy-ctl reads this unprivileged: tags, where each came from, the pin, what each one
  # chains through, what selection leaves alone, and what was disabled.
  inventoryBlock = ''
    ${jq} -n \
      --slurpfile tags <(printf '%s' "$OUTBOUND_TAGS_JSON") \
      --slurpfile sources <(printf '%s' "$OUTBOUND_SOURCES_JSON") \
      --arg pinned "$PINNED_OUTBOUND" \
      --arg selection ${lib.escapeShellArg selectionMode} \
      --slurpfile obs <(printf '%s' "$OUTBOUNDS_JSON") \
      --slurpfile xobs <(printf '%s' "${if hybridEnabled then "$XRAY_OUTBOUNDS_JSON" else "[]"}") \
      --slurpfile selectable <(printf '%s' "$SELECTABLE_TAGS_JSON") \
      --argjson disabled "$DISABLED_TAGS_JSON" \
      --slurpfile groups <(printf '%s' "$GROUPS_INFO_JSON") \
      --slurpfile top <(printf '%s' "$TOP_TAGS_JSON") \
      --argjson priority "$PRIORITY_JSON" \
      --arg url ${lib.escapeShellArg proxyCfg.urlTest.url} \
      '$tags[0] as $tags | $sources[0] as $sources | $selectable[0] as $selectable
      | $groups[0] as $groups | $top[0] as $top
      | {tags: $tags, sources: $sources, pinned: $pinned, selection: $selection,
        detours: ([($xobs[0] + $obs[0])[] | (.detour // .streamSettings.sockopt.dialerProxy?) as $h
          | select($h != null) | {key: .tag, value: $h}] | from_entries),
        excluded: ($top - $selectable), disabled: $disabled,
        groups: $groups, top: $top, priority: $priority, url: $url}' \
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
        lib.concatMapStrings (
          d: mkTunnelOutboundBlock d.tunnelUnit "warp" d.tag d.tunnelPort
        ) warpCfg.devices
      );
      torBlock = lib.optionalString torOutboundEnabled (
        mkTunnelOutboundBlock "proxy-suite-tor" "tor" "tor" torCfg.socksPort
      );
      whitelistBypassBlocks = lib.concatMapStrings (
        j: mkTunnelOutboundBlock "proxy-suite-wb-joiner-${j.tag}" "whitelist-bypass" j.tag j.port
      ) whitelistBypassJoiners;
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
        else if selectionMode == "failover" then
          ''
            # Every tag, so a pin reaches any of them live; proxy-suite-outbound-groups moves
            # it along the selectable ones, cutting what the failed one still carried.
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            DEFAULT_TAG="$PINNED_OUTBOUND"
            if [ -z "$DEFAULT_TAG" ]; then
              DEFAULT_TAG=$(${jq} -r '.[0]' <<< "$SELECTABLE_TAGS_JSON")
            fi
            if [ -z "$PINNED_OUTBOUND" ] && [ "''${GROUPS_WATCHED:-true}" != true ]; then
              # No Clash API here for the watcher to drive: sing-box's own urltest instead.
              WRAPPER=$(${jq} -n \
                --slurpfile tags <(printf '%s' "$SELECTABLE_TAGS_JSON") \
                --arg url ${lib.escapeShellArg proxyCfg.urlTest.url} \
                --argjson tolerance ${toString singBoxCfg.urlTest.tolerance} \
                '{type:"urltest",tag:"proxy",outbounds:$tags[0],url:$url,interval:"30s",tolerance:$tolerance}')
            else
              WRAPPER=$(${jq} -n \
                --slurpfile tags <(printf '%s' "$TAGS") \
                --arg default "$DEFAULT_TAG" \
                '{type:"selector",tag:"proxy",outbounds:$tags[0],default:$default,interrupt_exist_connections:true}')
            fi
            OUTBOUNDS_JSON=$(${jq} --slurpfile w <(printf '%s' "$WRAPPER") '$w + .' <<< "$OUTBOUNDS_JSON")
          ''
        else if selectionMode == "selector" then
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            DEFAULT_TAG="$PINNED_OUTBOUND"
            if [ -z "$DEFAULT_TAG" ]; then
              DEFAULT_TAG=$(${jq} -r '.[0]' <<< "$SELECTABLE_TAGS_JSON")
            fi
            WRAPPER=$(${jq} -n \
              --slurpfile tags <(printf '%s' "$TAGS") \
              --arg default "$DEFAULT_TAG" \
              '{type:"selector",tag:"proxy",outbounds:$tags[0],default:$default}')
            OUTBOUNDS_JSON=$(${jq} --slurpfile w <(printf '%s' "$WRAPPER") '$w + .' <<< "$OUTBOUNDS_JSON")
          ''
        else
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            if [ -n "$PINNED_OUTBOUND" ]; then
              # A pin beats latency ranking: the same outbounds, behind a selector
              # the Clash API can also switch live.
              WRAPPER=$(${jq} -n \
                --slurpfile tags <(printf '%s' "$TAGS") \
                --arg default "$PINNED_OUTBOUND" \
                '{type:"selector",tag:"proxy",outbounds:$tags[0],default:$default}')
            else
              WRAPPER=$(${jq} -n \
                --slurpfile tags <(printf '%s' "$SELECTABLE_TAGS_JSON") \
                --arg url ${lib.escapeShellArg proxyCfg.urlTest.url} \
                --arg interval ${lib.escapeShellArg proxyCfg.urlTest.interval} \
                --argjson tolerance ${toString singBoxCfg.urlTest.tolerance} \
                '{type:"urltest",tag:"proxy",outbounds:$tags[0],url:$url,interval:$interval,tolerance:$tolerance}')
            fi
            OUTBOUNDS_JSON=$(${jq} --slurpfile w <(printf '%s' "$WRAPPER") '$w + .' <<< "$OUTBOUNDS_JSON")
          '';
      # Real exits for autoProxy, taken after the wrapper may have renamed one to
      # "proxy".
      exitTagsBlock = ''
        EXIT_TAGS_JSON=$(${jq} -c '[.[] | select(.type != "selector" and .type != "urltest"${lib.optionalString torOutboundEnabled " and (.tag | ltrimstr(\"proxy-suite-ob-\")) != \"tor\""}) | .tag]' <<< "$OUTBOUNDS_JSON")
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
    + torBlock
    + whitelistBypassBlocks
    + awgBlocks
    + detourBlock
    + requireOutboundsBlock
    + tagsBlock
    + groupsBlock
    + pinBlock
    + selectableBlock
    + inventoryBlock
    + wrapperBlock
    + exitTagsBlock;
in
{
  inherit mkOutboundScript rawOutboundJson;
  # For the checks: groups, and which outbounds a pin and selection may take.
  selectionBlocks = tagsBlock + groupsBlock + pinBlock + selectableBlock + inventoryBlock;
  # And what the runtime spool is read into.
  runtimeOutboundBlocks = mkUrlOutboundHelpersBlock null + runtimeOutboundsBlock;
}
