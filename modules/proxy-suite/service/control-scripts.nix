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
  # As the start script reads them (script-blocks/outbounds.nix).
  groupPinsDir = "${dirOf pinnedOutboundFile}/group-pins";

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

  # $1 "due" (the timer's unit, proxy-suite-subscription-refresh): only the subscriptions whose
  # interval has run out. Without it (`proxy-ctl proxy subs update`): every one.
  subscriptionUpdateScript = pkgs.writeShellScript "proxy-suite-core" ''
    set -euo pipefail
    SUB_UPDATE_MODE="''${1:-all}"
    CACHE_DIR="${subscriptionCacheDir}"
    mkdir -p "$CACHE_DIR"
    FAILED=0
    ${subscriptionCacheHelpersBlock}
    ${lib.concatMapStrings mkSubscriptionFetchBlock proxyCfg.subscriptions}
    ${runtimeSubscriptionsFetchBlock}
    _proxy_suite_prune_subscription_meta

    # Only a changed cache: the timer runs this 5 minutes after every switch and then hourly,
    # and a restart drops every connection through the proxy, the inbounds' users' included. A
    # failed subscription keeps its old cache, so the others' changes still apply.
    if [ "$SUB_CACHE_CHANGED" -eq 1 ]; then
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

    # proxy-ctl shortens a name whose escaped unit instance would pass systemd's 255
    # characters (a Cyrillic letter escapes to 8; proxy_ctl._pin_instance) to its start,
    # "~" and the first 12 hex digits of its SHA-256. $1 the name as it came, the rest jq
    # arguments listing the names it may stand for: prints the one it stands for, or $1.
    _proxy_suite_pin_name() {
      local name="$1" head sum candidate
      shift
      if [[ $name =~ ^(.*)~([0-9a-f]{12})$ ]] && [ -r "${outboundInventoryFile}" ]; then
        head="''${BASH_REMATCH[1]}" sum="''${BASH_REMATCH[2]}"
        while IFS= read -r candidate; do
          [ "$candidate" != "$name" ] || break
          [[ $candidate == "$head"* ]] || continue
          if [ "$(printf '%s' "$candidate" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-12)" = "$sum" ]; then
            name="$candidate"
            break
          fi
        done < <(${jq} -r "$@" "${outboundInventoryFile}" 2>/dev/null || true)
      fi
      printf '%s' "$name"
    }

    # group/member pins inside a group, group/ unpins it (`proxy-ctl proxy pin --in`).
    case "$tag" in
      */*)
        group="''${tag%%/*}"
        member="''${tag#*/}"
        case "$group/$member" in
          /* | */*/* | . | .. | ./* | ../* | */. | */..)
            echo "proxy-suite: not a group and member: $tag" >&2
            exit 1
            ;;
        esac
        group=$(_proxy_suite_pin_name "$group" '.groups // {} | keys[]')
        [ -z "$member" ] || member=$(_proxy_suite_pin_name "$member" --arg g "$group" '.groups[$g].members // [] | .[]')
        if [ -r "${outboundInventoryFile}" ] \
          && ! ${jq} -e --arg g "$group" '.groups // {} | has($g)' "${outboundInventoryFile}" >/dev/null; then
          echo "proxy-suite: unknown group '$group'" >&2
          exit 1
        fi
        STRATEGY=$(${jq} -r --arg g "$group" '.groups[$g].strategy // ""' "${outboundInventoryFile}" 2>/dev/null || true)
        if [ -z "$member" ]; then
          rm -f "${groupPinsDir}/$group"
          # A failover group is picked again by the watcher, a selector stays where it is; a
          # urltest group only becomes one again with a restart, the TUN backends' with it.
          if [ "$STRATEGY" = urltest ]; then
            ${restartActiveConfigConsumersBlock}
          else
            if [ -f "${outboundInventoryFile}" ]; then
              INVENTORY_TMP=$(mktemp "${outboundInventoryFile}.XXXXXX")
              ${jq} --arg g "$group" '.groups[$g].pinned = ""' "${outboundInventoryFile}" > "$INVENTORY_TMP"
              chmod 644 "$INVENTORY_TMP"
              mv -f "$INVENTORY_TMP" "${outboundInventoryFile}"
            fi
            ${restartActiveBlock tunConsumers}
          fi
          exit 0
        fi
        if [ -r "${outboundInventoryFile}" ] \
          && ! ${jq} -e --arg g "$group" --arg t "$member" '.groups[$g].members | index([$t]) != null' "${outboundInventoryFile}" >/dev/null; then
          echo "proxy-suite: '$member' is not in group '$group'" >&2
          exit 1
        fi
        if [ -e "${runtimeOutboundsDir}/$member.disabled" ]; then
          echo "proxy-suite: outbound '$member' is disabled; enable it first: proxy-ctl proxy outbounds enable $member" >&2
          exit 1
        fi
        mkdir -p "${groupPinsDir}"
        printf '%s\n' "$member" > "${groupPinsDir}/$group"
        CLASH_SECRET_FILE="$(dirname "${outboundInventoryFile}")/clash-secret"
        CLASH_SECRET=""
        [ ! -r "$CLASH_SECRET_FILE" ] || CLASH_SECRET=$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$CLASH_SECRET_FILE")
        if [ "$STRATEGY" != urltest ] && ${curl} -sf -X PUT "${clashApi}/proxies/$group" \
          -H "Content-Type: application/json" \
          -H @<(printf 'Authorization: Bearer %s\n' "$CLASH_SECRET") \
          -d "$(${jq} -cn --arg name "$member" '{name:$name}')" >/dev/null 2>&1; then
          if [ -f "${outboundInventoryFile}" ]; then
            INVENTORY_TMP=$(mktemp "${outboundInventoryFile}.XXXXXX")
            ${jq} --arg g "$group" --arg t "$member" '.groups[$g].pinned = $t' "${outboundInventoryFile}" > "$INVENTORY_TMP"
            chmod 644 "$INVENTORY_TMP"
            mv -f "$INVENTORY_TMP" "${outboundInventoryFile}"
          fi
          ${restartActiveBlock tunConsumers}
          exit 0
        fi
        ${restartActiveConfigConsumersBlock}
        exit 0
        ;;
    esac

    if [ -z "$tag" ]; then
      rm -f "${pinnedOutboundFile}"
    else
      tag=$(_proxy_suite_pin_name "$tag" '(.tags // [])[], (.groups // {} | keys[])')
      # The inventory only exists once the proxy has run. Without it there is
      # nothing to check against, so accept the tag and let the start script warn
      # if it turns out to name nothing. A group is pinned like any outbound.
      if [ -r "${outboundInventoryFile}" ] \
        && ! ${jq} -e --arg t "$tag" '.tags + (.groups // {} | keys) | index($t) != null' "${outboundInventoryFile}" >/dev/null; then
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
      CLASH_SECRET_FILE="$(dirname "${outboundInventoryFile}")/clash-secret"
      CLASH_SECRET=""
      [ ! -r "$CLASH_SECRET_FILE" ] || CLASH_SECRET=$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$CLASH_SECRET_FILE")
      # The header from a pipe: argv is readable by every local user.
      if ${curl} -sf -X PUT "${clashApi}/proxies/proxy" \
        -H "Content-Type: application/json" \
        -H @<(printf 'Authorization: Bearer %s\n' "$CLASH_SECRET") \
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
        *) rm -f "$CACHE" "''${CACHE%.json}.links" "''${CACHE%.json}.fingerprint" ;;
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
