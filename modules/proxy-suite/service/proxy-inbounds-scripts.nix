# Startup script for the server-side inbound service.
#
# Much smaller than the client start script: no route-mode, no TUN/TProxy, no
# hybrid sidecar. It renders the listeners (reading their secrets), merges them
# into the build-time template, and hands the result to XRay.
{
  lib,
  pkgs,
  proxyCfg,
  proxyInboundsCfg,
  proxyInboundsNeedLocalProxy,
  proxyInboundViaOutbounds,
  userControlCfg,
  userControlEnabled,
  localProxyAuth,
  localProxyAuthEnabled,
  localProxyAuthPasswordSource,
  jq,
  python3,
  parserScriptsPythonPath,
  buildInboundPy,
  buildOutboundPy,
  proxyInboundsFile,
  proxyInboundsSpecFile,
  builders,
}:

let
  runtimeDir = "/run/proxy-suite-inbounds";
  linksFile = "${runtimeDir}/links.json";
  # This service's own package, not the client backend's.
  xray = "${proxyInboundsCfg.package}/bin/xray";

  # Only the local proxy needs credentials injected; the listeners' own secrets
  # are resolved by build-inbound.py.
  needsLocalProxyAuth = proxyInboundsNeedLocalProxy && localProxyAuthEnabled;

  serverAddressBlock =
    if proxyInboundsCfg.serverAddress != null then
      ''SERVER_ADDRESS=${lib.escapeShellArg proxyInboundsCfg.serverAddress}''
    else if proxyInboundsCfg.shareLinks then
      ''
        ${builders.mkDefaultUplinkIPv4Source {
          ip = "${pkgs.iproute2}/bin/ip";
          awk = "${pkgs.gawk}/bin/awk";
          errorMessage = "proxy-suite: could not determine this host's uplink address for inbound share links; set proxyInbounds.serverAddress";
        }}
        SERVER_ADDRESS="$uplink_addr"
      ''
    else
      ''SERVER_ADDRESS=""'';

  # Outbounds a listener pins itself to with `via = "<tag>"`. Rendered here, at
  # start time, so a urlFile's contents stay out of the Nix store. Subscriptions
  # are deliberately not duplicated into this service: their cache is refreshed
  # for the client backend only, and `via = "proxy"` already reaches them.
  mkViaOutboundBlock =
    ob:
    let
      urlSource =
        if ob.urlFile != null then
          ob.urlFile
        else if ob.url != null then
          pkgs.writeText "proxy-suite-inbound-via-url-${ob.tag}" ob.url
        else
          null;
    in
    if urlSource == null then
      ''
        # via outbound: ${ob.tag} (static xray json)
        OB_JSON=$(cat ${
          pkgs.writeText "proxy-suite-inbound-via-${ob.tag}.json" (
            builtins.toJSON (ob.xrayJson // { inherit (ob) tag; })
          )
        })
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      ''
    else
      ''
        # via outbound: ${ob.tag}
        URL=$(cat ${lib.escapeShellArg urlSource})
        OB_JSON=$(printf '%s' "$URL" | PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildOutboundPy} \
          --backend xray --tag ${lib.escapeShellArg ob.tag})
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      '';

  viaOutboundsBlock = lib.concatMapStrings mkViaOutboundBlock proxyInboundViaOutbounds;

  # Share links carry the listener credentials, so they are no more public than
  # the config itself.
  writeLinksBlock = lib.optionalString proxyInboundsCfg.shareLinks ''
    ${jq} -c '.links' <<< "$RENDERED" > "${linksFile}"
    ${lib.optionalString userControlEnabled ''
      ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg userControlCfg.group} "${linksFile}"
    ''}
    chmod ${if userControlEnabled then "640" else "600"} "${linksFile}"
  '';

  startInbounds = pkgs.writeShellScript "proxy-suite-start-inbounds" ''
    set -euo pipefail
    umask 077
    RUNTIME_DIR="${runtimeDir}"
    mkdir -p "$RUNTIME_DIR"

    ${serverAddressBlock}

    RENDERED=$(PYTHONPATH="${parserScriptsPythonPath}" ${python3} ${buildInboundPy} \
      --spec ${proxyInboundsSpecFile} \
      --server-address "$SERVER_ADDRESS")

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
      ${proxyInboundsFile} > "$RUNTIME_DIR/config.json"
    chmod 600 "$RUNTIME_DIR/config.json"

    ${writeLinksBlock}

    exec ${xray} run -c "$RUNTIME_DIR/config.json"
  '';
in
{
  inherit startInbounds linksFile;
}
