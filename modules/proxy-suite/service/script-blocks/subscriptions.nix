# Subscription cache and outbound-loading script fragments.
#
# Everything is emitted as shell functions taking a tag and a file holding the
# subscription URL, so a subscription declared in Nix and one added at runtime
# under `subscriptions.d/` go through exactly the same code.
{ ctx }:

let
  fillTemplate = import ../../lib/fill-template.nix;
  inherit (ctx)
    lib
    pkgs
    proxyCfg
    hybridEnabled
    mainBackend
    backend
    constants
    jq
    python3
    parserScriptsPythonPath
    fetchSubscriptionPy
    routingMarkJq
    ;
  inherit (constants) stateDir runtimeSubscriptionsDir runtimeOutboundsDir;
  # Outbounds and groups the start script adds after the subscriptions, which a subscription
  # entry must not take the tag of.
  laterTagsJson = builtins.toJSON (ctx.effectiveOutboundTags ++ ctx.groupTags);
  subscriptionBackend = if hybridEnabled then "hybrid" else mainBackend;
  # Each entry also through its backend's own config check: one it refuses would fail the
  # whole start, every other outbound with it.
  subscriptionBackendArg =
    "--backend ${subscriptionBackend}"
    + lib.optionalString (subscriptionBackend != "xray") " --check-sing-box ${ctx.singBox}"
    + lib.optionalString (subscriptionBackend != "sing-box") " --check-xray ${ctx.xray}";
  subscriptionCacheDir = "${stateDir}/subscriptions/${backend}";

  mkSubscriptionUrlSource =
    sub: if sub.urlFile != null then sub.urlFile else pkgs.writeText "proxy-suite-core" sub.url;

  # Defined in every script that touches a cache: the start scripts and the
  # update unit.
  subscriptionCacheHelpersBlock = fillTemplate ./subscription-cache-helpers.template.sh {
    readSourceFunction = constants.readSourceFunction pkgs;
    cacheDir = subscriptionCacheDir;
    inherit runtimeSubscriptionsDir jq;
    declaredTags = lib.escapeShellArgs (map (sub: sub.tag) proxyCfg.subscriptions);
    validCacheFilter = lib.escapeShellArg (
      if hybridEnabled then
        ''type == "object" and (.singBox | type == "array") and (.xray | type == "array")''
      else
        ''type == "array"''
    );
    inherit (pkgs) diffutils findutils;
    # The directory alone, not what is in it (constants.grantDirAcl): the caches are 0644, and
    # a recursive pass would trip over another start script's temporary file.
    cacheDirAccess =
      let
        secrets = ctx.userControlAllows "secrets";
        extraGroups = ctx.userControlExtraGroupsFor "secrets";
      in
      lib.optionalString secrets ''
        ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg ctx.userControlCfg.group} "$SUB_CACHE_DIR"
      ''
      + ''
        chmod ${if secrets then "0750" else "0700"} "$SUB_CACHE_DIR"
      ''
      + constants.ifPrivileged (
        if extraGroups == [ ] then
          ''${pkgs.acl}/bin/setfacl -b -- "$SUB_CACHE_DIR"''
        else
          ''${pkgs.acl}/bin/setfacl --set ${
            lib.concatStringsSep "," (
              [
                "u::rwx"
                "g::${if secrets then "r-x" else "---"}"
                "o::---"
              ]
              ++ map (g: "g:${g}:r-x") extraGroups
            )
          } -- "$SUB_CACHE_DIR"''
      );
    pythonPath = parserScriptsPythonPath;
    inherit python3 fetchSubscriptionPy;
    backendArg = subscriptionBackendArg;
    killSwitch = lib.boolToString ctx.killSwitchDirectFallbacks;
    # Its own user, not exempt from the tunnel or the kill switch: the HTTP client and the
    # parser of what any subscription server sends do not run as root.
    tunnelFetch = constants.ifPrivileged "${pkgs.util-linux}/bin/setpriv --reuid=${ctx.subscriptionFetchUser} --regid=${ctx.subscriptionFetchUser} --clear-groups --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs --";
    # Past the kill switch as the service user, resolving names itself (constants.ownLookups).
    directFetch = lib.optionalString ctx.killSwitchDirectFallbacks "${pkgs.util-linux}/bin/unshare --mount ${constants.ownLookups pkgs} ${
      constants.runAsServiceUser pkgs [ ]
    }";
  };

  # Merging a cache into OUTBOUNDS_JSON needs the routing mark, which differs per
  # start script, so this one is emitted separately from the cache helpers.
  mkSubscriptionLoadHelperBlock =
    routingMark:
    let
      markFilter = routingMarkJq routingMark;
      subVar = if hybridEnabled then "SUB_SING_BOX_JSON" else "SUB_JSON";
      # Plain string concatenation: "$" next to an interpolation is exactly the
      # spot where an indented string's escaping bites.
      markBlock = lib.optionalString (routingMark != null) (
        subVar + "=$(${jq} 'map(.${markFilter})' <<< \"$" + subVar + "\")\n"
      );
      mergeBlock =
        if hybridEnabled then
          ''
            SUB_SING_BOX_JSON=$(_proxy_suite_free_tags "$tag" < <(${jq} -c '.singBox' "$cache"))
            ${markBlock}OUTBOUNDS_JSON=$(${jq} --slurpfile sub <(printf '%s' "$SUB_SING_BOX_JSON") '. + $sub[0]' <<< "$OUTBOUNDS_JSON")
            _proxy_suite_add_xray_sidecar_obs "$(_proxy_suite_free_tags "$tag" < <(${jq} -c '.xray' "$cache"))"
          ''
        else
          ''
            SUB_JSON=$(_proxy_suite_free_tags "$tag" < "$cache")
            ${markBlock}OUTBOUNDS_JSON=$(${jq} --slurpfile sub <(printf '%s' "$SUB_JSON") '. + $sub[0]' <<< "$OUTBOUNDS_JSON")
          '';
    in
    ''
      # stdin: a subscription's outbounds; prints those whose tag is free. A taken one (by any
      # other outbound, a group or the suite's own) would fail the backend's start.
      _proxy_suite_free_tags() {
        local entries taken f name
        entries=$(cat)
        taken=$(
          {
            ${jq} -r 'map(.tag) | .[]' <<< "$OUTBOUNDS_JSON"
            if [ -d ${lib.escapeShellArg runtimeOutboundsDir} ]; then
              for f in ${lib.escapeShellArg runtimeOutboundsDir}/*.url ${lib.escapeShellArg runtimeOutboundsDir}/*.json \
                ${lib.escapeShellArg runtimeOutboundsDir}/*.awg ${lib.escapeShellArg runtimeOutboundsDir}/*.group; do
                [ -e "$f" ] || continue
                name="''${f##*/}"
                printf '%s\n' "''${name%.*}"
              done
            fi
          } | ${jq} -R . | ${jq} -cs --argjson fixed ${lib.escapeShellArg laterTagsJson} '. + $fixed + ["proxy", "direct", "block"] | unique'
        )
        ${jq} -r --arg sub "$1" --slurpfile taken <(printf '%s' "$taken") '
          $taken[0] as $taken
          | .[] | .tag | select(. as $t | ($taken | index([$t])) != null or startswith("proxy-suite-"))
          | "proxy-suite: warning: subscription \($sub) entry \(.) left out: the tag is taken"
        ' <<< "$entries" >&2
        ${jq} -c --slurpfile taken <(printf '%s' "$taken") '
          $taken[0] as $taken
          | map(select(.tag as $t | ($taken | index([$t])) == null and ($t | startswith("proxy-suite-") | not)))
        ' <<< "$entries"
      }

      # $1 tag, $2 file holding the subscription URL, then the fetcher's flags. Fetches on a
      # cold cache and merges whatever is cached; a subscription that cannot be fetched is a
      # warning, never a failed start.
      _proxy_suite_load_subscription() {
        local tag="$1" src="$2" cache="$SUB_CACHE_DIR/$1.json" before after
        _proxy_suite_drop_invalid_subscription_cache "$cache" "$tag"
        if [ ! -f "$cache" ]; then
          _proxy_suite_fetch_subscription "$tag" "$src" "''${@:3}" \
            || echo "proxy-suite: warning: could not fetch subscription '$tag'" >&2
        fi
        [ -f "$cache" ] || return 0
        before=$(${jq} 'length' <<< "$OUTBOUNDS_JSON")
        ${mergeBlock}
        after=$(${jq} 'length' <<< "$OUTBOUNDS_JSON")
        _proxy_suite_record_outbound_source "sub:$tag" "$before" "$after"
        _proxy_suite_record_subscription_share "$tag" "$src" "$SUB_CACHE_DIR/$tag.links"
      }
    '';

  # A subscription's fetcher flags. Runtime ones take proxy.runtimeSubscriptions', https only
  # unless allowHttp: over http anyone on the way could add entries.
  mkSubscriptionFetchArgs =
    sub:
    lib.optionalString sub.allowPrivateServers " --allow-private-servers"
    + lib.optionalString sub.allowInsecure " --allow-insecure";
  runtimeCfg = proxyCfg.runtimeSubscriptions;
  runtimeFetchArgs =
    mkSubscriptionFetchArgs runtimeCfg + lib.optionalString (!runtimeCfg.allowHttp) " --https-only";

  mkSubscriptionBlock = sub: _routingMark: ''
    # subscription: ${sub.tag}
    _proxy_suite_load_subscription ${lib.escapeShellArg sub.tag} ${lib.escapeShellArg (mkSubscriptionUrlSource sub)}${mkSubscriptionFetchArgs sub}
  '';

  runtimeSubscriptionsBlock = ''
    # subscriptions added at runtime
    while IFS=$'\t' read -r RUNTIME_SUB_TAG RUNTIME_SUB_SRC; do
      [ -n "$RUNTIME_SUB_TAG" ] || continue
      _proxy_suite_load_subscription "$RUNTIME_SUB_TAG" "$RUNTIME_SUB_SRC"${runtimeFetchArgs}
    done < <(_proxy_suite_runtime_subscriptions)
  '';

  mkSubscriptionFetchBlock = sub: ''
    if _proxy_suite_fetch_subscription ${lib.escapeShellArg sub.tag} ${lib.escapeShellArg (mkSubscriptionUrlSource sub)}${mkSubscriptionFetchArgs sub}; then
      echo "Updated subscription: ${sub.tag}"
    else
      FAILED=1
    fi
  '';

  runtimeSubscriptionsFetchBlock = ''
    while IFS=$'\t' read -r RUNTIME_SUB_TAG RUNTIME_SUB_SRC; do
      [ -n "$RUNTIME_SUB_TAG" ] || continue
      if _proxy_suite_fetch_subscription "$RUNTIME_SUB_TAG" "$RUNTIME_SUB_SRC"${runtimeFetchArgs}; then
        echo "Updated subscription: $RUNTIME_SUB_TAG"
      else
        FAILED=1
      fi
    done < <(_proxy_suite_runtime_subscriptions)
  '';

  subscriptionTagsFile = pkgs.writeText "proxy-suite-core" (
    builtins.toJSON (map (sub: sub.tag) proxyCfg.subscriptions)
  );
in
{
  inherit
    subscriptionCacheDir
    subscriptionCacheHelpersBlock
    mkSubscriptionLoadHelperBlock
    mkSubscriptionBlock
    runtimeSubscriptionsBlock
    mkSubscriptionFetchBlock
    runtimeSubscriptionsFetchBlock
    subscriptionTagsFile
    ;
}
