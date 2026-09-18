# Subscription refresh, route-mode and outbound control scripts.
{
  lib,
  pkgs,
  proxyCfg,
  clashApi,
  routeModeStateFile,
  pinnedOutboundFile,
  outboundInventoryFile,
  runtimeOutboundsDir,
  subscriptionCacheDir,
  subscriptionCacheHelpersBlock,
  mkSubscriptionFetchBlock,
  runtimeSubscriptionsFetchBlock,
  jq,
  systemctl,
}:

let
  curl = "${pkgs.curl}/bin/curl";

  restartActiveBlock = lib.concatMapStrings (svc: ''
    if ${systemctl} is-active --quiet ${svc}; then
      ${systemctl} restart ${svc}
    fi
  '');

  # The TUN backends are sing-box instances of their own, without a Clash API.
  tunConsumers = [
    "proxy-suite-tun"
    "proxy-suite-per-app-tun"
  ];
  restartActiveConfigConsumersBlock = restartActiveBlock ([ "proxy-suite-socks" ] ++ tunConsumers);

  subscriptionUpdateScript = pkgs.writeShellScript "proxy-suite-core" ''
    set -euo pipefail
    CACHE_DIR="${subscriptionCacheDir}"
    mkdir -p "$CACHE_DIR"
    FAILED=0
    ${subscriptionCacheHelpersBlock}
    ${lib.concatMapStrings mkSubscriptionFetchBlock proxyCfg.subscriptions}
    ${runtimeSubscriptionsFetchBlock}

    if [ "$FAILED" -eq 0 ]; then
      ${restartActiveConfigConsumersBlock}
    fi
    exit "$FAILED"
  '';

  setRouteModeScript = pkgs.writeShellScript "proxy-suite-core" ''
    set -euo pipefail
    mode="''${1:-}"

    case "$mode" in
      default | whitelist | blacklist | all-proxy | all-bypass)
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

  # Pins the outbound the proxy prefers; without a tag, unpins it and hands the choice
  # back to the configured selection. The pin is persisted either way; a live Clash
  # API switch only saves the restart.
  pinOutboundScript = pkgs.writeShellScript "proxy-suite-core" ''
    set -euo pipefail
    tag="''${1:-}"

    if [ -z "$tag" ]; then
      rm -f "${pinnedOutboundFile}"
    else
      # The inventory only exists once the proxy has run. Without it there is
      # nothing to check against, so accept the tag and let the start script warn
      # if it turns out to name nothing.
      if [ -r "${outboundInventoryFile}" ] \
        && ! ${jq} -e --arg t "$tag" '.tags | index($t) != null' "${outboundInventoryFile}" >/dev/null; then
        echo "proxy-suite: unknown outbound '$tag'" >&2
        exit 1
      fi
      # Disabled means nothing picks it on its own, a pin included.
      case "$tag" in
        */* | . | ..) ;;
        *)
          if [ -e "${runtimeOutboundsDir}/$tag.disabled" ]; then
            echo "proxy-suite: outbound '$tag' is disabled; enable it first: proxy-ctl proxy outbounds enable $tag" >&2
            exit 1
          fi
          ;;
      esac
      mkdir -p "$(dirname "${pinnedOutboundFile}")"
      printf '%s\n' "$tag" > "${pinnedOutboundFile}"
      # Live switch when the running config exposes a selector; the persisted pin
      # is what keeps it after the next restart.
      if ${curl} -sf -X PUT "${clashApi}/proxies/proxy" \
        -H "Content-Type: application/json" \
        -d "$(${jq} -cn --arg name "$tag" '{name:$name}')" >/dev/null 2>&1; then
        # A live switch skips the restart that rewrites the inventory, and the pin
        # is only ever read from there: without this the outbound reads as merely
        # current, and the front ends offer no unpin until the next restart.
        if [ -f "${outboundInventoryFile}" ]; then
          INVENTORY_TMP=$(mktemp "${outboundInventoryFile}.XXXXXX")
          if ${jq} --arg t "$tag" '.pinned = $t' "${outboundInventoryFile}" > "$INVENTORY_TMP"; then
            chmod 644 "$INVENTORY_TMP"
            mv -f "$INVENTORY_TMP" "${outboundInventoryFile}"
          else
            rm -f "$INVENTORY_TMP"
          fi
        fi
        ${restartActiveBlock tunConsumers}
        exit 0
      fi
    fi

    ${restartActiveConfigConsumersBlock}
  '';

  # Applies whatever is now in the runtime spool directories. A removed runtime
  # subscription leaves a root-owned cache behind that the group cannot unlink,
  # so the cache dir is reconciled against the sources here.
  reloadOutboundsScript = pkgs.writeShellScript "proxy-suite-core" ''
    set -euo pipefail
    ${subscriptionCacheHelpersBlock}

    KEEP="|${lib.concatMapStrings (sub: "${sub.tag}|") proxyCfg.subscriptions}"
    while IFS=$'\t' read -r TAG _; do
      [ -n "$TAG" ] || continue
      KEEP="$KEEP$TAG|"
    done < <(_proxy_suite_runtime_subscriptions)

    for CACHE in "$SUB_CACHE_DIR"/*.json; do
      [ -e "$CACHE" ] || continue
      TAG="''${CACHE##*/}"
      TAG="''${TAG%.json}"
      case "$KEEP" in
        *"|$TAG|"*) ;;
        *) rm -f "$CACHE" "''${CACHE%.json}.links" ;;
      esac
    done

    # A pin on a disabled outbound goes with it, so enabling the outbound later does not
    # bring the pin back. Here rather than through the unpin unit: disabling is the
    # outbounds scope's, pinning the routing scope's.
    if [ -r "${pinnedOutboundFile}" ]; then
      PINNED="$(tr -d '\r\n[:space:]' < "${pinnedOutboundFile}" 2>/dev/null || true)"
      case "$PINNED" in
        "" | */* | . | ..) ;;
        *)
          if [ -e "${runtimeOutboundsDir}/$PINNED.disabled" ]; then
            rm -f "${pinnedOutboundFile}"
          fi
          ;;
      esac
    fi

    ${restartActiveConfigConsumersBlock}
  '';
in
{
  inherit
    subscriptionUpdateScript
    setRouteModeScript
    pinOutboundScript
    reloadOutboundsScript
    ;
}
