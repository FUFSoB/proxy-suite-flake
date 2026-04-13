# Systemd services for sing-box
{
  config,
  lib,
  pkgs,
  cfg,
  tproxyFile,
  tunFile,
  nftablesRulesFile,
  ip,
  nft,
}:

let
  sb = cfg.singBox;
  t = cfg.tgWsProxy;
  builtinTags = [
    "proxy"
    "direct"
    "block"
  ];
  outboundTags = map (ob: ob.tag) sb.outbounds;
  invalidRoutingTargets = lib.unique (
    map (rule: rule.outbound) (
      builtins.filter (rule: !builtins.elem rule.outbound (builtinTags ++ outboundTags)) sb.routing.rules
    )
  );

  jq = "${pkgs.jq}/bin/jq";
  python3 = "${pkgs.python3}/bin/python3";
  singBox = "${pkgs.sing-box}/bin/sing-box";

  fetchSubscriptionPy = ../../scripts/fetch-subscription.py;

  # Build the shell code block for a single outbound entry.
  # tag overrides ob.tag (used in "first" mode to force tag = "proxy").
  # routingMark is null or an int; added to outbound JSON if set.
  mkOutboundBlock =
    ob: routingMark: tag:
    let
      markArg = lib.optionalString (routingMark != null) " --routing-mark ${toString routingMark}";
    in
    if ob.json != null then
      let
        outboundJson = builtins.toJSON (
          ob.json // { tag = tag; } // lib.optionalAttrs (routingMark != null) { routing_mark = routingMark; }
        );
        jsonFile = pkgs.writeText "proxy-suite-ob-${tag}.json" outboundJson;
      in
      ''
        # outbound: ${tag} (static json)
        OB_JSON=$(cat ${lib.escapeShellArg jsonFile})
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      ''
    else
      let
        urlSource =
          if ob.urlFile != null then
            ob.urlFile
          else
            # Literal URL – write to nix store so the script can cat it.
            # Less secret than urlFile, but convenient for non-sensitive configs.
            "${pkgs.writeText "proxy-suite-url-${ob.tag}" ob.url}";
      in
      ''
        # outbound: ${tag}
        URL=$(cat ${lib.escapeShellArg urlSource})
        OB_JSON=$(printf '%s' "$URL" | ${python3} ${../../scripts/build-outbound.py} --tag ${lib.escapeShellArg tag}${markArg})
        OUTBOUNDS_JSON=$(${jq} --argjson ob "$OB_JSON" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
      '';

  # Build the shell code block for a single subscription entry.
  # Fetches subscription into the cache on first run; subsequent starts use the cache.
  mkSubscriptionBlock =
    sub: routingMark:
    let
      urlSource =
        if sub.urlFile != null then
          sub.urlFile
        else
          "${pkgs.writeText "proxy-suite-sub-url-${sub.tag}" sub.url}";
    in
    ''
      # subscription: ${sub.tag}
      CACHE_DIR="/var/lib/proxy-suite/subscriptions"
      CACHE_FILE="$CACHE_DIR/${lib.escapeShellArg sub.tag}.json"
      if [ ! -f "$CACHE_FILE" ]; then
        mkdir -p "$CACHE_DIR"
        SUB_URL=$(cat ${lib.escapeShellArg urlSource})
        if printf '%s' "$SUB_URL" \
            | ${python3} ${fetchSubscriptionPy} --tag-prefix ${lib.escapeShellArg sub.tag} \
            > "$CACHE_FILE.tmp"; then
          mv "$CACHE_FILE.tmp" "$CACHE_FILE"
        else
          rm -f "$CACHE_FILE.tmp"
          echo "proxy-suite: warning: could not fetch subscription '${sub.tag}'" >&2
        fi
      fi
      if [ -f "$CACHE_FILE" ]; then
        SUB_JSON=$(cat "$CACHE_FILE")
        ${lib.optionalString (routingMark != null) ''
        SUB_JSON=$(${jq} --argjson m ${toString routingMark} 'map(. + {routing_mark: $m})' <<< "$SUB_JSON")
        ''}OUTBOUNDS_JSON=$(${jq} --argjson sub "$SUB_JSON" '. + $sub' <<< "$OUTBOUNDS_JSON")
      fi
    '';

  # Shell code that builds all outbounds, then optionally adds a selector/urltest wrapper.
  mkOutboundScript =
    routingMark:
    let
      outboundBlocks =
        if sb.selection == "first" && sb.outbounds != [ ] then
          # Only the first static outbound, tagged "proxy" so sing-box routes to it.
          mkOutboundBlock (builtins.head sb.outbounds) routingMark "proxy"
        else
          lib.concatMapStrings (ob: mkOutboundBlock ob routingMark ob.tag) sb.outbounds;

      subscriptionBlocks =
        lib.concatMapStrings (sub: mkSubscriptionBlock sub routingMark) sb.subscriptions;

      wrapperBlock =
        if sb.selection == "first" then
          # When there are no static outbounds, subscription outbounds keep their
          # real tags. Rename the first one to "proxy" so routing rules resolve.
          lib.optionalString (sb.outbounds == [ ] && sb.subscriptions != [ ]) ''
            FIRST_TAG=$(${jq} -r 'if length > 0 then .[0].tag else "" end' <<< "$OUTBOUNDS_JSON")
            if [ -n "$FIRST_TAG" ]; then
              OUTBOUNDS_JSON=$(${jq} --arg t "$FIRST_TAG" \
                'map(if .tag == $t then .tag = "proxy" else . end)' <<< "$OUTBOUNDS_JSON")
            fi
          ''
        else if sb.selection == "selector" then
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            FIRST=$(${jq} -r '.[0].tag' <<< "$OUTBOUNDS_JSON")
            WRAPPER=$(${jq} -n \
              --argjson tags "$TAGS" \
              --arg default "$FIRST" \
              '{type:"selector",tag:"proxy",outbounds:$tags,default:$default}')
            OUTBOUNDS_JSON=$(${jq} --argjson w "$WRAPPER" '[$w] + .' <<< "$OUTBOUNDS_JSON")
          ''
        else
          # urltest
          ''
            TAGS=$(${jq} '[.[].tag]' <<< "$OUTBOUNDS_JSON")
            WRAPPER=$(${jq} -n \
              --argjson tags "$TAGS" \
              --arg url ${lib.escapeShellArg sb.urlTest.url} \
              --arg interval ${lib.escapeShellArg sb.urlTest.interval} \
              --argjson tolerance ${toString sb.urlTest.tolerance} \
              '{type:"urltest",tag:"proxy",outbounds:$tags,url:$url,interval:$interval,tolerance:$tolerance}')
            OUTBOUNDS_JSON=$(${jq} --argjson w "$WRAPPER" '[$w] + .' <<< "$OUTBOUNDS_JSON")
          '';
    in
    outboundBlocks + subscriptionBlocks + wrapperBlock;

  mkStartScript =
    {
      name,
      runtimeDir,
      configFile,
      routingMark ? null,
    }:
    pkgs.writeShellScript name ''
      set -euo pipefail
      RUNTIME_DIR="${runtimeDir}"
      mkdir -p "$RUNTIME_DIR"
      OUTBOUNDS_JSON='[]'

      ${mkOutboundScript routingMark}

      ${jq} --argjson obs "$OUTBOUNDS_JSON" \
        '.outbounds = $obs + .outbounds' \
        "${configFile}" > "$RUNTIME_DIR/config.json"

      exec ${singBox} run -c "$RUNTIME_DIR/config.json"
    '';

  startSocks = mkStartScript {
    name = "proxy-suite-start-socks";
    runtimeDir = "/run/proxy-suite-socks";
    configFile = tproxyFile;
    routingMark = sb.proxyMark;
  };

  startTun = mkStartScript {
    name = "proxy-suite-start-tun";
    runtimeDir = "/run/proxy-suite-tun";
    configFile = tunFile;
    routingMark = null;
  };

  clashApi = "http://127.0.0.1:${toString sb.clashApiPort}";
  selection = sb.selection;

  # Shell code to fetch a single subscription into the cache (used in update service).
  mkSubscriptionFetchBlock =
    sub:
    let
      urlSource =
        if sub.urlFile != null then
          sub.urlFile
        else
          "${pkgs.writeText "proxy-suite-sub-url-${sub.tag}" sub.url}";
    in
    ''
      SUB_URL=$(cat ${lib.escapeShellArg urlSource})
      if printf '%s' "$SUB_URL" \
          | ${python3} ${fetchSubscriptionPy} --tag-prefix ${lib.escapeShellArg sub.tag} \
          > "$CACHE_DIR/${lib.escapeShellArg sub.tag}.json.tmp"; then
        mv "$CACHE_DIR/${lib.escapeShellArg sub.tag}.json.tmp" \
           "$CACHE_DIR/${lib.escapeShellArg sub.tag}.json"
        echo "Updated subscription: ${sub.tag}"
      else
        rm -f "$CACHE_DIR/${lib.escapeShellArg sub.tag}.json.tmp"
        echo "proxy-suite: failed to update subscription '${sub.tag}'" >&2
        FAILED=1
      fi
    '';

  subscriptionUpdateScript = pkgs.writeShellScript "proxy-suite-subscription-update" ''
    set -euo pipefail
    CACHE_DIR="/var/lib/proxy-suite/subscriptions"
    mkdir -p "$CACHE_DIR"
    FAILED=0

    ${lib.concatMapStrings mkSubscriptionFetchBlock sb.subscriptions}

    if [ "$FAILED" -eq 0 ]; then
      systemctl restart proxy-suite-socks
      systemctl is-active --quiet proxy-suite-tun && systemctl restart proxy-suite-tun || true
    fi
    exit "$FAILED"
  '';

  # Subscription tags embedded at build time for proxy-ctl.
  subscriptionTagsList = lib.concatStringsSep " " (map (sub: lib.escapeShellArg sub.tag) sb.subscriptions);
  hasSubscriptions = sb.subscriptions != [ ];

  proxyCtl = pkgs.writeShellApplication {
    name = "proxy-ctl";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = ''
      # Embedded at build time from module config
      CLASH_API="${clashApi}"
      SELECTION="${selection}"
      SUB_TAGS=(${subscriptionTagsList})

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
        echo "  status                    show status of all proxy-suite services"
        echo "  tproxy on|off             enable/disable TProxy transparent mode"
        echo "  tun on|off                enable/disable TUN mode"
        echo "  restart                   restart proxy-suite-socks and proxy-suite-tun if active"
        echo "  logs [service]            follow service logs  (default: proxy-suite-socks)"
        echo "  outbounds                 list outbounds and current selection"
        echo "  select <tag>              switch to a specific outbound  (selector mode)"
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

      cmd="''${1:-status}"
      shift || true

      case "$cmd" in
        status)
          echo "proxy-suite services:"
          for svc in "''${ALL_SERVICES[@]}"; do
            _svc_status "$svc"
          done
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

        restart)
          systemctl restart proxy-suite-socks
          if systemctl is-active --quiet proxy-suite-tun; then
            systemctl restart proxy-suite-tun
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
  environment.systemPackages = [ proxyCtl ];

  # nftables must be on for TProxy to work.
  networking.nftables.enable = lib.mkIf sb.tproxy.enable (lib.mkDefault true);

  assertions = [
    {
      assertion = !sb.enable || (sb.outbounds != [ ] || sb.subscriptions != [ ]);
      message = "proxy-suite: at least one outbound or subscription is required when singBox.enable = true";
    }
    {
      assertion = builtins.length outboundTags == builtins.length (lib.unique outboundTags);
      message = "proxy-suite: outbound tags must be unique";
    }
    {
      assertion = builtins.all (tag: !builtins.elem tag builtinTags) outboundTags;
      message = "proxy-suite: outbound tags must not use reserved names: proxy, direct, block";
    }
    {
      assertion = invalidRoutingTargets == [ ];
      message = "proxy-suite: routing.rules reference unknown outbound tag(s): ${lib.concatStringsSep ", " invalidRoutingTargets}";
    }
    {
      assertion = !(sb.tproxy.enable && sb.tproxy.autostart && sb.tun.enable && sb.tun.autostart);
      message = "proxy-suite: singBox.tproxy.autostart and singBox.tun.autostart cannot both be enabled at the same time";
    }
    {
      assertion =
        !t.enable
        ||
          builtins.length (
            builtins.filter (x: x != null) [
              t.secret
              t.secretFile
            ]
          ) == 1;
      message = "proxy-suite: tgWsProxy requires exactly one of secret or secretFile";
    }
  ]
  ++ lib.concatMap (ob: [
    {
      assertion =
        builtins.length (
          builtins.filter (x: x != null) [
            ob.urlFile
            ob.url
            ob.json
          ]
        ) == 1;
      message = "proxy-suite: outbound '${ob.tag}': set exactly one of urlFile, url, or json";
    }
  ]) sb.outbounds
  ++ lib.concatMap (sub: [
    {
      assertion =
        builtins.length (
          builtins.filter (x: x != null) [
            sub.urlFile
            sub.url
          ]
        ) == 1;
      message = "proxy-suite: subscription '${sub.tag}': set exactly one of urlFile or url";
    }
  ]) sb.subscriptions;

  systemd.services = {
    # Always-on: SOCKS5/HTTP mixed inbound, also ready for TProxy interception.
    proxy-suite-socks = {
      description = "sing-box proxy client (SOCKS + TProxy-ready)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${startSocks}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "proxy-suite-socks";
        StateDirectory = "proxy-suite";
      };
    };
  }
  // lib.optionalAttrs sb.tproxy.enable {
    # Opt-in transparent proxy. Start/stop with:
    #   systemctl start proxy-suite-tproxy
    #   systemctl stop proxy-suite-tproxy
    proxy-suite-tproxy = {
      description = "sing-box TProxy – nftables rules and policy routing";
      after = [
        "network.target"
        "proxy-suite-socks.service"
      ];
      wantedBy = lib.optionals sb.tproxy.autostart [ "multi-user.target" ];
      requires = [ "proxy-suite-socks.service" ];
      conflicts = [ "proxy-suite-tun.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "proxy-suite-tproxy-up" ''
          ${nft} delete table ip singbox 2>/dev/null || true
          ${nft} -f ${nftablesRulesFile}
          ${ip} route add local default dev lo table ${toString sb.routeTable}
          ${ip} rule add fwmark ${toString sb.fwmark} table ${toString sb.routeTable}
        '';
        ExecStop = pkgs.writeShellScript "proxy-suite-tproxy-down" ''
          ${nft} delete table ip singbox 2>/dev/null || true
          ${ip} route del local default dev lo table ${toString sb.routeTable} 2>/dev/null || true
          ${ip} rule del fwmark ${toString sb.fwmark} table ${toString sb.routeTable} 2>/dev/null || true
        '';
      };
    };
  }
  // lib.optionalAttrs sb.tun.enable {
    # Opt-in TUN mode (full tunnel, no nftables needed). Start/stop with:
    #   systemctl start proxy-suite-tun
    #   systemctl stop proxy-suite-tun
    proxy-suite-tun = {
      description = "sing-box TUN proxy client";
      after = [ "network-online.target" ];
      wantedBy = lib.optionals sb.tun.autostart [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      conflicts = [ "proxy-suite-tproxy.service" ];
      serviceConfig = {
        ExecStart = "${startTun}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "proxy-suite-tun";
        StateDirectory = "proxy-suite";
      };
    };
  }
  // lib.optionalAttrs hasSubscriptions {
    proxy-suite-subscription-update = {
      description = "Refresh proxy-suite subscription caches";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "proxy-suite";
        ExecStart = "${subscriptionUpdateScript}";
      };
    };
  };

  systemd.timers = lib.optionalAttrs hasSubscriptions {
    proxy-suite-subscription-update = {
      description = "Periodic proxy-suite subscription refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = sb.subscriptionUpdateInterval;
      };
    };
  };
}
