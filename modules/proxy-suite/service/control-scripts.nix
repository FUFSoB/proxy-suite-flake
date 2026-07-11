# Subscription refresh and route-mode control scripts.
{
  lib,
  pkgs,
  proxyCfg,
  routeModeStateFile,
  subscriptionCacheDir,
  subscriptionCacheHelpersBlock,
  mkSubscriptionFetchBlock,
}:

let
  systemctl = "${pkgs.systemd}/bin/systemctl";

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
in
{
  inherit
    subscriptionUpdateScript
    setRouteModeScript
    ;
}
