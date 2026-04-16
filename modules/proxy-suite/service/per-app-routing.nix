# App routing backend infrastructure (TUN, TProxy, zapret) and the proxy-ctl management tool.
{
  lib,
  pkgs,
  cfg,
  singBoxCfg,
  perAppRoutingCfg,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretCfg,
  perAppTunChainFile,
  perAppTproxyRulesFile,
  perAppZapretRulesFile,
  ip,
  nft,
  awk,
  grepBin,
  findBin,
  headBin,
  seqBin,
  sleepBin,
  jq,
  proxychains4,
  systemdRun,
  systemctl,
  journalctl,
  idBin,
  clashApi,
  selection,
  subscriptionTagsList,
}:

let
  perAppTunSliceName = "proxy-suite-per-app-tun.slice";
  perAppTproxySliceName = "proxy-suite-per-app-tproxy.slice";
  perAppZapretSliceName = "proxy-suite-per-app-zapret.slice";

  perAppRoutingProfileNames = map (profile: profile.name) perAppRoutingCfg.profiles;
  defaultPerAppRoutingProfiles = lib.optionals perAppRoutingCfg.createDefaultProfiles (
    [
      {
        name = "proxychains";
        route = "proxychains";
      }
    ]
    ++ lib.optionals perAppRoutingTun.enable [
      {
        name = "tun";
        route = "tun";
      }
    ]
    ++ lib.optionals perAppRoutingTproxy.enable [
      {
        name = "tproxy";
        route = "tproxy";
      }
    ]
    ++ lib.optionals (perAppZapretCfg.enable && cfg.zapret.enable) [
      {
        name = "zapret";
        route = "zapret";
      }
    ]
  );
  effectivePerAppRoutingProfiles =
    perAppRoutingCfg.profiles
    ++ builtins.filter (profile: !(builtins.elem profile.name perAppRoutingProfileNames)) defaultPerAppRoutingProfiles;
  effectivePerAppRoutingProfileNames = map (profile: profile.name) effectivePerAppRoutingProfiles;

  perAppRoutingProfilesFile = pkgs.writeText "proxy-suite-per-app-routing-profiles.json" (
    builtins.toJSON effectivePerAppRoutingProfiles
  );

  proxychainsConfigFile = pkgs.writeText "proxy-suite-proxychains.conf" ''
    strict_chain
    ${lib.optionalString perAppRoutingCfg.proxychains.quiet "quiet_mode"}
    ${lib.optionalString perAppRoutingCfg.proxychains.proxyDns "proxy_dns"}
    tcp_read_time_out 15000
    tcp_connect_time_out 8000

    [ProxyList]
    socks5 ${singBoxCfg.listenAddress} ${toString singBoxCfg.port}
  '';
  proxychainsQuietArg = lib.optionalString perAppRoutingCfg.proxychains.quiet "-q ";

  hasProxychainsProfiles = builtins.any (profile: profile.route == "proxychains") effectivePerAppRoutingProfiles;
  hasTunProfiles = builtins.any (profile: profile.route == "tun") effectivePerAppRoutingProfiles;
  hasTproxyProfiles = builtins.any (profile: profile.route == "tproxy") effectivePerAppRoutingProfiles;
  hasZapretProfiles = builtins.any (profile: profile.route == "zapret") effectivePerAppRoutingProfiles;

  perAppTunWaitForInterface = pkgs.writeShellScript "proxy-suite-per-app-tun-wait-for-interface" ''
    set -euo pipefail
    for _ in $(${seqBin} 1 50); do
      if ${ip} link show dev ${lib.escapeShellArg perAppRoutingTun.interface} >/dev/null 2>&1; then
        exit 0
      fi
      ${sleepBin} 0.1
    done
    echo "proxy-suite: app TUN interface ${perAppRoutingTun.interface} did not appear in time" >&2
    exit 1
  '';

  perAppTunUpScript = pkgs.writeShellScript "proxy-suite-per-app-tun-up" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_tun 2>/dev/null || true
    ${nft} -f ${perAppTunChainFile}
    ${perAppTunWaitForInterface}
    ${ip} route replace default dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable}
    ${ip} rule add fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
  '';

  perAppTunDownScript = pkgs.writeShellScript "proxy-suite-per-app-tun-down" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_tun 2>/dev/null || true
    ${ip} route del default dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
    ${ip} rule del fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
  '';

  perAppTproxyUpScript = pkgs.writeShellScript "proxy-suite-per-app-tproxy-up" ''
    set -euo pipefail
    ${nft} delete table ip proxy_suite_per_app_tproxy 2>/dev/null || true
    ${nft} -f ${perAppTproxyRulesFile}
    ${ip} route replace local default dev lo table ${toString perAppRoutingTproxy.routeTable}
    ${ip} rule add fwmark ${toString perAppRoutingTproxy.fwmark} table ${toString perAppRoutingTproxy.routeTable} 2>/dev/null || true
  '';

  perAppTproxyDownScript = pkgs.writeShellScript "proxy-suite-per-app-tproxy-down" ''
    set -euo pipefail
    ${nft} delete table ip proxy_suite_per_app_tproxy 2>/dev/null || true
    ${ip} route del local default dev lo table ${toString perAppRoutingTproxy.routeTable} 2>/dev/null || true
    ${ip} rule del fwmark ${toString perAppRoutingTproxy.fwmark} table ${toString perAppRoutingTproxy.routeTable} 2>/dev/null || true
  '';

  # Generate a "start" script that adds a per-user cgroup nftables mark rule.
  mkUserRuleStart =
    {
      name,
      nftFamily,
      nftTable,
      nftChain,
      sliceName,
      sliceLabel,
      markRule,
    }:
    pkgs.writeShellScript "proxy-suite-${name}-user-start" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-${name}-user-$uid"
      mark_comment="$rule_comment_prefix-mark"
      cgroup_root="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
      if ! [ -d "$cgroup_root" ]; then
        echo "proxy-suite: user cgroup root does not exist for uid $uid: $cgroup_root" >&2
        exit 1
      fi

      cgroup_dir=$(${findBin} "$cgroup_root" -type d -name ${lib.escapeShellArg sliceName} | ${headBin} -n1 || true)
      if [ -z "$cgroup_dir" ]; then
        echo "proxy-suite: ${sliceLabel} slice cgroup does not exist for uid $uid under $cgroup_root" >&2
        exit 1
      fi
      cgroup_path=''${cgroup_dir#/sys/fs/cgroup/}
      cgroup_level=$(printf '%s' "$cgroup_path" | ${awk} -F/ '{ print NF }')

      handles=$(${nft} -a list chain ${nftFamily} ${nftTable} ${nftChain} 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule ${nftFamily} ${nftTable} ${nftChain} handle "$handle" || true
        done <<< "$handles"
      fi

      printf '%s\n' \
        "add rule ${nftFamily} ${nftTable} ${nftChain} socket cgroupv2 level $cgroup_level \"$cgroup_path\" ${markRule} comment \"$mark_comment\"" \
        | ${nft} -f -
    '';

  # Generate a "stop" script that removes all per-user cgroup nftables mark rules.
  mkUserRuleStop =
    {
      name,
      nftFamily,
      nftTable,
      nftChain,
    }:
    pkgs.writeShellScript "proxy-suite-${name}-user-stop" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-${name}-user-$uid"
      handles=$(${nft} -a list chain ${nftFamily} ${nftTable} ${nftChain} 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule ${nftFamily} ${nftTable} ${nftChain} handle "$handle" || true
        done <<< "$handles"
      fi
    '';

  perAppTunUserRuleStart = mkUserRuleStart {
    name = "per-app-tun";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_tun";
    nftChain = "output";
    sliceName = perAppTunSliceName;
    sliceLabel = "app TUN";
    markRule = "meta mark set ${toString perAppRoutingTun.fwmark} ct mark set ${toString perAppRoutingTun.fwmark}";
  };
  perAppTunUserRuleStop = mkUserRuleStop {
    name = "per-app-tun";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_tun";
    nftChain = "output";
  };

  perAppTproxyUserRuleStart = mkUserRuleStart {
    name = "per-app-tproxy";
    nftFamily = "ip";
    nftTable = "proxy_suite_per_app_tproxy";
    nftChain = "output";
    sliceName = perAppTproxySliceName;
    sliceLabel = "app TProxy";
    markRule = "meta mark set ${toString perAppRoutingTproxy.fwmark} ct mark set ${toString perAppRoutingTproxy.fwmark}";
  };
  perAppTproxyUserRuleStop = mkUserRuleStop {
    name = "per-app-tproxy";
    nftFamily = "ip";
    nftTable = "proxy_suite_per_app_tproxy";
    nftChain = "output";
  };

  perAppZapretUserRuleStart = mkUserRuleStart {
    name = "per-app-zapret";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_zapret_mark";
    nftChain = "output";
    sliceName = perAppZapretSliceName;
    sliceLabel = "app zapret";
    markRule = "meta mark set meta mark or ${toString perAppZapretCfg.filterMark} ct mark set ct mark or ${toString perAppZapretCfg.filterMark}";
  };
  perAppZapretUserRuleStop = mkUserRuleStop {
    name = "per-app-zapret";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_zapret_mark";
    nftChain = "output";
  };

  mkAnchorService = sliceName: desc: {
    description = desc;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Slice = sliceName;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = "${pkgs.coreutils}/bin/true";
    };
  };

  proxyCtl = pkgs.writeShellApplication {
    name = "proxy-ctl";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      gnugrep
      jq
      proxychains-ng
      systemd
    ];
    text = ''
      # Embedded at build time from module config
      CLASH_API="${clashApi}"
      SELECTION="${selection}"
      SUB_TAGS=(${subscriptionTagsList})
      PER_APP_ROUTING_ENABLED="${if perAppRoutingCfg.enable then "1" else "0"}"
      PER_APP_ROUTING_PROXYCHAINS_ENABLED="${if perAppRoutingCfg.proxychains.enable then "1" else "0"}"
      PER_APP_ROUTING_TUN_ENABLED="${if perAppRoutingTun.enable then "1" else "0"}"
      PER_APP_ROUTING_TPROXY_ENABLED="${if perAppRoutingTproxy.enable then "1" else "0"}"
      PER_APP_ROUTING_ZAPRET_ENABLED="${if (perAppZapretCfg.enable && cfg.zapret.enable) then "1" else "0"}"
      PER_APP_ROUTING_PROFILES_FILE="${perAppRoutingProfilesFile}"
      PROXYCHAINS_CONFIG="${proxychainsConfigFile}"
      PER_APP_TUN_SLICE_BASE="proxy-suite-per-app-tun"
      PER_APP_TPROXY_SLICE_BASE="proxy-suite-per-app-tproxy"
      PER_APP_ZAPRET_SLICE_BASE="proxy-suite-per-app-zapret"

      ALL_SERVICES=(
        proxy-suite-socks
        proxy-suite-tproxy
        proxy-suite-tun
        proxy-suite-tg-ws-proxy
        proxy-suite-zapret-vm-exempt
        zapret-discord-youtube
      )

      _usage() {
        echo "Usage: proxy-ctl <command> [args]"
        echo ""
        echo "Commands:"
        echo "  status [--tray]           show status of all proxy-suite services"
        echo "  proxy on|off              enable/disable the core SOCKS proxy"
        echo "  tproxy on|off             enable/disable TProxy transparent mode"
        echo "  tun on|off                enable/disable TUN mode"
        echo "  zapret on|off             enable/disable zapret-discord-youtube"
        echo "  restart                   restart active global proxy-suite services"
        echo "  logs [service]            follow service logs  (default: proxy-suite-socks)"
        echo "  outbounds                 list outbounds and current selection"
        echo "  select <tag>              switch to a specific outbound  (selector mode)"
        echo "  apps                      list configured per-app routing profiles"
        echo "  wrap <profile> -- <cmd>   run a command via an perAppRouting profile"
        echo "  subscription list         show subscriptions, cache age, and proxy count"
        echo "  subscription update       force-refresh all subscription caches and restart"
        exit 1
      }

      _svc_status() {
        local svc="$1"
        if ! systemctl cat "$svc" &>/dev/null; then
          return
        fi
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null || true)
        printf "  %-44s %s\n" "$svc" "$state"
      }

      _bool() {
        if "$@"; then
          printf true
        else
          printf false
        fi
      }

      _svc_exists() {
        systemctl cat "$1" &>/dev/null
      }

      _svc_active() {
        systemctl is-active --quiet "$1"
      }

      _status_tray() {
        printf 'socks_available=%s\n' "$(_bool _svc_exists proxy-suite-socks)"
        printf 'socks_active=%s\n' "$(_bool _svc_active proxy-suite-socks)"
        printf 'tproxy_available=%s\n' "$(_bool _svc_exists proxy-suite-tproxy)"
        printf 'tproxy_active=%s\n' "$(_bool _svc_active proxy-suite-tproxy)"
        printf 'tun_available=%s\n' "$(_bool _svc_exists proxy-suite-tun)"
        printf 'tun_active=%s\n' "$(_bool _svc_active proxy-suite-tun)"
        printf 'zapret_available=%s\n' "$(_bool _svc_exists zapret-discord-youtube)"
        printf 'zapret_active=%s\n' "$(_bool _svc_active zapret-discord-youtube)"
        printf 'subscription_update_available=%s\n' "$(_bool _svc_exists proxy-suite-subscription-update)"
      }

      _ensure_app_routing() {
        if [ "$PER_APP_ROUTING_ENABLED" != "1" ]; then
          echo "perAppRouting is not enabled in services.proxy-suite.perAppRouting."
          exit 1
        fi
      }

      _profile_route() {
        local profile="$1"
        ${jq} -r --arg name "$profile" '.[] | select(.name == $name) | .route' "$PER_APP_ROUTING_PROFILES_FILE"
      }

      _scope_running() {
        ${systemctl} --user list-units --type=scope --state=running --plain --no-legend "$1-*" \
          | ${grepBin} -q .
      }

      _any_user_active() {
        ${systemctl} list-units --type=service --state=active --plain --no-legend "$1*.service" \
          | ${grepBin} -q .
      }

      _check_no_global_proxy() {
        if ${systemctl} is-active --quiet proxy-suite-tun.service; then
          echo "Global proxy-suite-tun.service is active. Stop it before using route=$1 profiles."
          exit 1
        fi
        if ${systemctl} is-active --quiet proxy-suite-tproxy.service; then
          echo "Global proxy-suite-tproxy.service is active. Stop it before using route=$1 profiles."
          exit 1
        fi
      }

      # _wrap_slice <slice_base> <enabled_var> <disabled_msg> <backend_svc> [cmd...]
      _wrap_slice() {
        local slice_base="$1" enabled="$2" disabled_msg="$3" backend_svc="$4"
        shift 4
        if [ "$enabled" != "1" ]; then
          echo "$disabled_msg"
          exit 1
        fi
        local uid; uid="$(${idBin} -u)"
        local scope_unit="$slice_base-''${profile}-$$"
        local anchor_unit="$slice_base-anchor.service"
        local user_svc="$slice_base-user@$uid.service"

        ${systemctl} --user start "$anchor_unit"
        ${systemctl} start "$backend_svc"
        ${systemctl} start "$user_svc"

        local status=0
        ${systemdRun} --user --scope --quiet --collect --same-dir \
          --slice="$slice_base" --unit="$scope_unit" "$@" || status=$?

        if ! _scope_running "$slice_base"; then
          ${systemctl} stop "$user_svc" || true
          ${systemctl} --user stop "$anchor_unit" || true
          if ! _any_user_active "$slice_base-user@"; then
            ${systemctl} stop "$backend_svc" || true
          fi
        fi
        exit "$status"
      }

      cmd="''${1:-status}"
      shift || true

      case "$cmd" in
        status)
          if [ "''${1:-}" = "--tray" ]; then
            _status_tray
          else
            echo "proxy-suite services:"
            for svc in "''${ALL_SERVICES[@]}"; do
              _svc_status "$svc"
            done
          fi
          ;;

        proxy)
          case "''${1:-on}" in
            on)
              systemctl start proxy-suite-socks
              ;;
            off)
              systemctl stop proxy-suite-tproxy || true
              systemctl stop proxy-suite-tun || true
              systemctl stop proxy-suite-socks
              ;;
            *)
              echo "Usage: proxy-ctl proxy on|off"; exit 1 ;;
          esac
          ;;

        tproxy)
          case "''${1:-on}" in
            on)  systemctl start proxy-suite-tproxy ;;
            off) systemctl stop  proxy-suite-tproxy ;;
            *)   echo "Usage: proxy-ctl tproxy on|off"; exit 1 ;;
          esac
          ;;

        tun)
          case "''${1:-on}" in
            on)  systemctl start proxy-suite-tun ;;
            off) systemctl stop  proxy-suite-tun ;;
            *)   echo "Usage: proxy-ctl tun on|off"; exit 1 ;;
          esac
          ;;

        zapret)
          case "''${1:-on}" in
            on)  systemctl start zapret-discord-youtube ;;
            off) systemctl stop  zapret-discord-youtube ;;
            *)   echo "Usage: proxy-ctl zapret on|off"; exit 1 ;;
          esac
          ;;

        restart)
          systemctl restart proxy-suite-socks
          if systemctl is-active --quiet proxy-suite-tproxy; then
            systemctl restart proxy-suite-tproxy
          fi
          if systemctl is-active --quiet proxy-suite-tun; then
            systemctl restart proxy-suite-tun
          fi
          if systemctl is-active --quiet zapret-discord-youtube; then
            systemctl restart zapret-discord-youtube
          fi
          ;;

        logs)
          svc="''${1:-proxy-suite-socks}"
          shift || true
          exec journalctl -fu "$svc" "$@"
          ;;

        outbounds)
          data=$(curl -sf "$CLASH_API/proxies/proxy" 2>/dev/null) || {
            echo "Clash API not available."
            echo "  - Make sure proxy-suite-socks is running"
            echo "  - selection must be 'selector' or 'urltest' (currently: $SELECTION)"
            exit 1
          }
          now=$(echo "$data" | jq -r '.now // "n/a"')
          ob_type=$(echo "$data" | jq -r '.type // "n/a"')
          echo "Type:    $ob_type"
          echo "Current: $now"
          echo ""
          echo "Available:"
          echo "$data" | jq -r '.all[]? | "  " + .'
          ;;

        select)
          tag="''${1:?Usage: proxy-ctl select <outbound-tag>}"
          if [ "$SELECTION" != "selector" ]; then
            echo "selection must be 'selector' (currently: $SELECTION)"
            exit 1
          fi
          payload=$(jq -cn --arg name "$tag" '{name:$name}')
          if curl -sf -X PUT "$CLASH_API/proxies/proxy" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null; then
            echo "Switched to: $tag"
          else
            echo "Failed – is proxy-suite-socks running with selector mode?"
            exit 1
          fi
          ;;

        apps)
          _ensure_app_routing
          if [ "$(${jq} 'length' "$PER_APP_ROUTING_PROFILES_FILE")" -eq 0 ]; then
            echo "No perAppRouting profiles configured."
          else
            printf "  %-24s %s\n" "PROFILE" "ROUTE"
            ${jq} -r '.[] | "  " + (.name | tostring) + "\t" + (.route | tostring)' \
              "$PER_APP_ROUTING_PROFILES_FILE" \
              | while IFS=$'\t' read -r profile route; do
                  printf "%-26s %s\n" "$profile" "$route"
                done
          fi
          ;;

        wrap)
          profile="''${1:?Usage: proxy-ctl wrap <profile> -- <command> [args...]}"
          shift || true
          if [ "''${1:-}" = "--" ]; then
            shift
          fi
          if [ "$#" -eq 0 ]; then
            echo "Usage: proxy-ctl wrap <profile> -- <command> [args...]"
            exit 1
          fi

          _ensure_app_routing
          route="$(_profile_route "$profile")"
          if [ -z "$route" ] || [ "$route" = "null" ]; then
            echo "Unknown perAppRouting profile: $profile"
            exit 1
          fi

          case "$route" in
            direct)
              exec "$@"
              ;;
            proxychains)
              if [ "$PER_APP_ROUTING_PROXYCHAINS_ENABLED" != "1" ]; then
                echo "Profile '$profile' uses route=proxychains, but perAppRouting.proxychains.enable is false."
                exit 1
              fi
              exec ${proxychains4} ${proxychainsQuietArg}-f "$PROXYCHAINS_CONFIG" "$@"
              ;;
            tun)
              _wrap_slice "$PER_APP_TUN_SLICE_BASE" "$PER_APP_ROUTING_TUN_ENABLED" \
                "Profile '$profile' uses route=tun, but singBox.tun.perApp.enable is false." \
                "proxy-suite-per-app-tun.service" "$@"
              ;;
            tproxy)
              _check_no_global_proxy tproxy
              _wrap_slice "$PER_APP_TPROXY_SLICE_BASE" "$PER_APP_ROUTING_TPROXY_ENABLED" \
                "Profile '$profile' uses route=tproxy, but singBox.tproxy.perApp.enable is false." \
                "proxy-suite-per-app-tproxy.service" "$@"
              ;;
            zapret)
              _check_no_global_proxy zapret
              _wrap_slice "$PER_APP_ZAPRET_SLICE_BASE" "$PER_APP_ROUTING_ZAPRET_ENABLED" \
                "Profile '$profile' uses route=zapret, but zapret.perApp.enable or zapret.enable is false." \
                "proxy-suite-per-app-zapret.service" "$@"
              ;;
            *)
              echo "Route backend '$route' is not implemented in this build."
              exit 1
              ;;
          esac
          ;;

        subscription)
          subcmd="''${1:-list}"
          shift || true
          case "$subcmd" in
            list)
              CACHE_DIR="/var/lib/proxy-suite/subscriptions"
              if [ ''${#SUB_TAGS[@]} -eq 0 ]; then
                echo "No subscriptions configured."
              else
                printf "  %-30s %-22s %s\n" "TAG" "LAST UPDATED" "PROXIES"
                for t in "''${SUB_TAGS[@]}"; do
                  cache="$CACHE_DIR/$t.json"
                  if [ -f "$cache" ]; then
                    age=$(date -r "$cache" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
                    count=$(jq 'length' "$cache" 2>/dev/null || echo "?")
                  else
                    age="(no cache)"
                    count="-"
                  fi
                  printf "  %-30s %-22s %s\n" "$t" "$age" "$count"
                done
              fi
              ;;
            update)
              systemctl start proxy-suite-subscription-update
              echo "Subscription update triggered. Follow with: proxy-ctl logs proxy-suite-subscription-update"
              ;;
            *)
              echo "Usage: proxy-ctl subscription list|update"; exit 1 ;;
          esac
          ;;

        *)
          _usage
          ;;
      esac
    '';
  };
in
{
  inherit
    perAppTunSliceName
    perAppTproxySliceName
    perAppZapretSliceName
    perAppTunUpScript
    perAppTunDownScript
    perAppTproxyUpScript
    perAppTproxyDownScript
    perAppTunUserRuleStart
    perAppTunUserRuleStop
    perAppTproxyUserRuleStart
    perAppTproxyUserRuleStop
    perAppZapretUserRuleStart
    perAppZapretUserRuleStop
    mkAnchorService
    effectivePerAppRoutingProfiles
    effectivePerAppRoutingProfileNames
    perAppRoutingProfilesFile
    proxychainsConfigFile
    proxychainsQuietArg
    hasProxychainsProfiles
    hasTunProfiles
    hasTproxyProfiles
    hasZapretProfiles
    proxyCtl
    ;
}
