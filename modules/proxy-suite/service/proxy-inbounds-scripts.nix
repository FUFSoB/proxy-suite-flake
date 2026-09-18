# Start script of the inbound service: renders the listeners with their secrets into the
# template and runs XRay.
{ ctx }:

let
  inherit (ctx)
    lib
    pkgs
    proxyCfg
    proxyInboundsCfg
    proxyInboundsAwg
    awgBin
    proxyInboundsNeedLocalProxy
    torOnionEnabled
    proxyInboundViaOutbounds
    userControlCfg
    userControlAllows
    localProxyAuth
    localProxyAuthEnabled
    localProxyAuthPasswordSource
    jq
    python3
    parserScriptsPythonPath
    buildInboundPy
    buildOutboundPy
    proxyInboundsFile
    proxyInboundsSpecFile
    builders
    constants
    ;
  runtimeDir = "${constants.runtimeDir}/proxy-suite-inbounds";
  linksFile = "${runtimeDir}/links.json";
  subscriptionsFile = "${runtimeDir}/subscriptions.json";
  subsCfg = proxyInboundsCfg.subscriptions;
  xray = "${proxyInboundsCfg.package}/bin/xray";
  # Only listeners, and for AmneziaWG listeners transparent sockets (IP_TRANSPARENT).
  runXray = constants.runAsServiceUser pkgs (
    [ "net_bind_service" ] ++ lib.optional (proxyInboundsAwg != [ ]) "net_admin"
  );

  needsLocalProxyAuth = proxyInboundsNeedLocalProxy && localProxyAuthEnabled;

  serverAddressBlock =
    if proxyInboundsCfg.serverAddress != null then
      "SERVER_ADDRESS=${lib.escapeShellArg proxyInboundsCfg.serverAddress}"
    else if proxyInboundsCfg.shareLinks then
      ''
        ${builders.mkDefaultUplinkIPv4Source {
          ip = "${pkgs.iproute2}/bin/ip";
          awk = "${pkgs.gawk}/bin/awk";
          errorMessage = "proxy-suite: could not determine this host's uplink address for inbound share links; set inbounds.serverAddress";
        }}
        SERVER_ADDRESS="$uplink_addr"
      ''
    else
      ''SERVER_ADDRESS=""'';

  # The onion service's address, for its share links. Tor writes it as it starts; a Tor
  # that is not up in time costs only the onion links, until the next restart.
  onionAddressBlock =
    if torOnionEnabled && proxyInboundsCfg.shareLinks then
      ''
        ONION_ADDRESS=""
        onion_hostname=${lib.escapeShellArg constants.torOnionHostnameFile}
        for _ in $(${pkgs.coreutils}/bin/seq 30); do
          [ -s "$onion_hostname" ] && break
          ${pkgs.coreutils}/bin/sleep 1
        done
        if [ -s "$onion_hostname" ]; then
          ONION_ADDRESS=$(${pkgs.coreutils}/bin/tr -d '[:space:]' < "$onion_hostname")
        else
          echo "proxy-suite: proxy-suite-tor has not written $onion_hostname; no onion share links until a restart" >&2
        fi
      ''
    else
      ''ONION_ADDRESS=""'';

  # Outbounds pinned with `via = "<tag>"`, rendered at start so urlFile contents stay
  # out of the store.
  mkViaOutboundBlock =
    ob:
    let
      # A chained one dials through its hop, which the chain put in this config too.
      dialerBlock = lib.optionalString (ob.detour != null) ''
        OB_JSON=$(${jq} -c --arg hop ${lib.escapeShellArg ob.detour} '.streamSettings.sockopt.dialerProxy = $hop' <<< "$OB_JSON")
      '';
      urlSource =
        if ob.urlFile != null then
          ob.urlFile
        else if ob.url != null then
          pkgs.writeText "proxy-suite-inbounds" ob.url
        else
          null;
    in
    if urlSource == null then
      ''
        # via outbound: ${ob.tag} (static xray json)
        OB_JSON=$(cat ${
          pkgs.writeText "proxy-suite-inbounds" (builtins.toJSON (ob.xrayJson // { inherit (ob) tag; }))
        })
        ${dialerBlock}
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      ''
    else
      ''
        # via outbound: ${ob.tag}
        URL=$(cat ${lib.escapeShellArg urlSource})
        OB_JSON=$(printf '%s' "$URL" | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildOutboundPy} \
          --backend xray --tag ${lib.escapeShellArg ob.tag})
        ${dialerBlock}
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      '';

  viaOutboundsBlock = lib.concatMapStrings mkViaOutboundBlock proxyInboundViaOutbounds;

  writeLinksBlock = lib.optionalString proxyInboundsCfg.shareLinks ''
    ${jq} -c '.links' <<< "$RENDERED" > "${linksFile}"
    ${lib.optionalString (userControlAllows "secrets") ''
      ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "${linksFile}"
    ''}
    chmod ${if userControlAllows "secrets" then "640" else "600"} "${linksFile}"
  '';

  # One file per user for the web server, plus a token index for proxy-ctl. Filled aside
  # and swapped in whole; a missing group leaves them root-only.
  writeSubscriptionsBlock = lib.optionalString (proxyInboundsCfg.shareLinks && subsCfg.enable) ''
    SUB_DIR="${runtimeDir}/subscriptions"
    rm -rf "$SUB_DIR.new"
    mkdir -m 0750 "$SUB_DIR.new"
    ${jq} -r '.subscriptions[] | "\(.token)\t\(.body)"' <<< "$RENDERED" |
      while IFS=$'\t' read -r token body; do
        printf '%s' "$body" > "$SUB_DIR.new/$token"
      done
    chmod -R u=rwX,g=rX,o= "$SUB_DIR.new"
    ${constants.ifPrivileged ''
      ${pkgs.coreutils}/bin/chgrp -R ${lib.escapeShellArg subsCfg.group} "$SUB_DIR.new" ||
        echo "proxy-suite: group ${subsCfg.group} cannot be given the subscriptions; they stay root-only" >&2''}
    rm -rf "$SUB_DIR"
    mv "$SUB_DIR.new" "$SUB_DIR"
    ${jq} -c '[.subscriptions[] | {user, token}]' <<< "$RENDERED" > "${subscriptionsFile}"
    ${lib.optionalString (userControlAllows "secrets") ''
      ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "${subscriptionsFile}"
    ''}
    chmod ${if userControlAllows "secrets" then "640" else "600"} "${subscriptionsFile}"
  '';

  startInbounds = pkgs.writeShellScript "proxy-suite-inbounds" ''
    set -euo pipefail
    umask 077
    RUNTIME_DIR="${runtimeDir}"
    mkdir -p "$RUNTIME_DIR"

    ${serverAddressBlock}
    ${onionAddressBlock}

    RENDERED=$(PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildInboundPy} \
      --spec ${proxyInboundsSpecFile} \
      --server-address "$SERVER_ADDRESS" \
      --onion-address "$ONION_ADDRESS")

    INBOUNDS_JSON=$(${jq} -c '.inbounds' <<< "$RENDERED")

    OUTBOUNDS_JSON='[]'
    ${viaOutboundsBlock}

    ${lib.optionalString needsLocalProxyAuth ''
      LOCAL_PROXY_PASSWORD="$(cat "${localProxyAuthPasswordSource}")"
    ''}

    ${jq} \
      --argjson ibs "$INBOUNDS_JSON" \
      --argjson obs "$OUTBOUNDS_JSON" \
      --argjson auth_enabled ${if needsLocalProxyAuth then "true" else "false"} \
      --arg user ${if needsLocalProxyAuth then lib.escapeShellArg localProxyAuth.username else "''"} \
      --arg password ${if needsLocalProxyAuth then "\"$LOCAL_PROXY_PASSWORD\"" else "''"} \
      '.inbounds = $ibs
       | .outbounds = $obs + .outbounds
       | if $auth_enabled then
           (.outbounds[] | select(.tag == "proxy") | .settings.servers[0].users)
             = [{user:$user,pass:$password}]
         else . end' \
      ${proxyInboundsFile} > "$RUNTIME_DIR/config.json.tmp"

    # XRay runs as ${constants.serviceUser}. A certificate or key it cannot read (an ACME
    # key, say) is copied in, which means a renewal needs a restart; give the user read
    # access to keep XRay's own reload.
    CERT_DIR="$RUNTIME_DIR/tls"
    rm -rf "$CERT_DIR"
    index=0
    while IFS= read -r source; do
      [ -n "$source" ] || continue
      if ! ${runXray} ${pkgs.coreutils}/bin/test -r "$source"; then
        [ -d "$CERT_DIR" ] || install -d -m 0750 ${constants.ifPrivileged "-g ${constants.serviceUser} "}"$CERT_DIR"
        index=$((index + 1))
        copy="$CERT_DIR/$index-$(basename "$source")"
        install -m 0640 ${constants.ifPrivileged "-g ${constants.serviceUser} "}"$source" "$copy"
        echo "proxy-suite: ${constants.serviceUser} cannot read $source; XRay uses a copy until the next restart" >&2
        ${jq} --arg from "$source" --arg to "$copy" '
          (.inbounds[].streamSettings.tlsSettings.certificates[]? | (.certificateFile, .keyFile)
            | select(. == $from)) = $to
        ' "$RUNTIME_DIR/config.json.tmp" > "$RUNTIME_DIR/config.json.next"
        mv "$RUNTIME_DIR/config.json.next" "$RUNTIME_DIR/config.json.tmp"
      fi
    done < <(${jq} -r '[.inbounds[].streamSettings.tlsSettings.certificates[]? | (.certificateFile, .keyFile) | strings]
      | unique[]' "$RUNTIME_DIR/config.json.tmp")

    # Read by XRay as ${constants.serviceUser}, and by the userControl group: the daemon
    # as owner then, since a file has one group.
    ${
      if userControlAllows "secrets" then
        ''
          ${pkgs.coreutils}/bin/chown ${constants.serviceUser}:${lib.escapeShellArg userControlCfg.group} "$RUNTIME_DIR/config.json.tmp"
          chmod 440 "$RUNTIME_DIR/config.json.tmp"
        ''
      else
        ''
          ${constants.ifPrivileged ''${pkgs.coreutils}/bin/chgrp ${constants.serviceUser} "$RUNTIME_DIR/config.json.tmp"''}
          chmod 640 "$RUNTIME_DIR/config.json.tmp"
        ''
    }
    mv "$RUNTIME_DIR/config.json.tmp" "$RUNTIME_DIR/config.json"

    ${writeLinksBlock}
    ${writeSubscriptionsBlock}

    exec ${runXray} ${xray} run -c "$RUNTIME_DIR/config.json"
  '';

  # Adds XRay's counters to the daily totals, read and reset in one call, and notes who
  # is online. Run by a timer, and by the inbounds' ExecStop, so a restart loses nothing.
  collectInboundStats = pkgs.writeShellScript "proxy-suite-inbounds" ''
    set -euo pipefail
    file=${lib.escapeShellArg constants.inboundStatsFile}
    api=--server=127.0.0.1:${toString constants.inboundStatsApiPort}
    # A timer run and a stop can overlap: each reads and resets part, and both rewrite the file.
    exec 9> "$file.lock"
    ${pkgs.util-linux}/bin/flock 9
    if ! reading=$(${xray} api statsquery "$api" -pattern "" -reset 2> /dev/null); then
      echo "the inbounds' stats API is not answering; nothing collected"
      exit 0
    fi
    [ -n "$reading" ] || reading='{}'
    online=$(${xray} api statsonlineiplist "$api" -all 2> /dev/null) || online=""
    [ -n "$online" ] || online='{}'
    ${
      if proxyInboundsAwg != [ ] then
        ''
          awg=$(PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${parserScriptsPythonPath}/awg_inbound.py peers \
            --spec ${proxyInboundsSpecFile} --awg ${awgBin}) || awg='[]'
        ''
      else
        "awg='[]'"
    }
    [ -s "$file" ] || echo '{}' > "$file"
    tmp=$(${pkgs.coreutils}/bin/mktemp "$file.XXXXXX")
    ${jq} --argjson q "$reading" --argjson online "$online" --argjson awg "$awg" \
      --arg day "$(${pkgs.coreutils}/bin/date +%F)" \
      --argjson now "$(${pkgs.coreutils}/bin/date +%s)" \
      -f ${
        builtins.path {
          name = "proxy-suite-inbounds";
          path = ../inbound-stats-add.jq;
        }
      } "$file" > "$tmp"
    ${lib.optionalString (userControlAllows "stats") ''
      ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "$tmp" ||
        echo "proxy-suite: group ${userControlCfg.group} cannot read the stats; they stay root-only" >&2
    ''}
    chmod ${if userControlAllows "stats" then "640" else "600"} "$tmp"
    mv -f "$tmp" "$file"
  '';
in
{
  inherit
    startInbounds
    collectInboundStats
    linksFile
    subscriptionsFile
    ;
}
