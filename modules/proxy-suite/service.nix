# Systemd services for sing-box
{
  config,
  lib,
  pkgs,
  cfg,
  tproxyFile,
  tunFile,
  appTunFile,
  nftablesRulesFile,
  appTproxyRulesFile,
  appZapretRulesFile,
  ip,
  nft,
}:

let
  sb = cfg.singBox;
  t = cfg.tgWsProxy;
  ar = cfg.appRouting;
  uc = cfg.userControl;
  art = ar.backends.tun;
  artp = ar.backends.tproxy;
  arz = ar.backends.zapret;
  userControlEnabled = uc.global.enable || uc.perApp.enable;
  userControlPolkitRules =
    lib.optionalString uc.perApp.enable ''
      if (unit.indexOf("proxy-suite-app-") === 0) {
        return polkit.Result.YES;
      }
    ''
    + lib.optionalString uc.global.enable ''
      if ((unit.indexOf("proxy-suite-") === 0 &&
           unit.indexOf("proxy-suite-app-") !== 0) ||
          unit === "zapret-discord-youtube.service") {
        return polkit.Result.YES;
      }
    '';
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
  proxychains4 = "${pkgs.proxychains-ng}/bin/proxychains4";
  systemdRun = "${pkgs.systemd}/bin/systemd-run";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  journalctl = "${pkgs.systemd}/bin/journalctl";
  idBin = "${pkgs.coreutils}/bin/id";
  grepBin = "${pkgs.gnugrep}/bin/grep";
  awk = "${pkgs.gawk}/bin/awk";
  sleepBin = "${pkgs.coreutils}/bin/sleep";
  headBin = "${pkgs.coreutils}/bin/head";
  seqBin = "${pkgs.coreutils}/bin/seq";
  findBin = "${pkgs.findutils}/bin/find";

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

  startAppTun = mkStartScript {
    name = "proxy-suite-start-app-tun";
    runtimeDir = "/run/proxy-suite-app-tun";
    configFile = appTunFile;
    # Only needed when TProxy mode is enabled; otherwise avoid tagging app TUN
    # proxy outbounds with a host-global mark.
    routingMark = if sb.tproxy.enable then sb.proxyMark else null;
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
  appRoutingProfileNames = map (profile: profile.name) ar.profiles;
  defaultAppRoutingProfiles = lib.optionals ar.createDefaultProfiles [
    {
      name = "proxychains";
      route = "proxychains";
    }
  ] ++ lib.optionals art.enable [
    {
      name = "tun";
      route = "tun";
    }
  ] ++ lib.optionals artp.enable [
    {
      name = "tproxy";
      route = "tproxy";
    }
  ] ++ lib.optionals (arz.enable && cfg.zapret.enable) [
    {
      name = "zapret";
      route = "zapret";
    }
  ];
  effectiveAppRoutingProfiles =
    ar.profiles
    ++ builtins.filter (profile: !(builtins.elem profile.name appRoutingProfileNames)) defaultAppRoutingProfiles;
  effectiveAppRoutingProfileNames = map (profile: profile.name) effectiveAppRoutingProfiles;
  appRoutingProfilesFile = pkgs.writeText "proxy-suite-app-routing-profiles.json" (
    builtins.toJSON effectiveAppRoutingProfiles
  );
  proxychainsConfigFile = pkgs.writeText "proxy-suite-proxychains.conf" ''
    strict_chain
    ${lib.optionalString ar.proxychains.quiet "quiet_mode"}
    ${lib.optionalString ar.proxychains.proxyDns "proxy_dns"}
    tcp_read_time_out 15000
    tcp_connect_time_out 8000

    [ProxyList]
    socks5 ${sb.listenAddress} ${toString sb.port}
  '';
  proxychainsQuietArg = lib.optionalString ar.proxychains.quiet "-q ";
  hasProxychainsProfiles = builtins.any (profile: profile.route == "proxychains") effectiveAppRoutingProfiles;
  hasTunProfiles = builtins.any (profile: profile.route == "tun") effectiveAppRoutingProfiles;
  hasTproxyProfiles = builtins.any (profile: profile.route == "tproxy") effectiveAppRoutingProfiles;
  hasZapretProfiles = builtins.any (profile: profile.route == "zapret") effectiveAppRoutingProfiles;
  appTunSliceName = "proxy-suite-app-tun.slice";
  appTproxySliceName = "proxy-suite-app-tproxy.slice";
  appZapretSliceName = "proxy-suite-app-zapret.slice";
  appTunChainFile = pkgs.writeText "proxy-suite-app-tun-chain.nft" ''
    define RESERVED_IP = {
        10.0.0.0/8,
        100.64.0.0/10,
        127.0.0.0/8,
        169.254.0.0/16,
        172.16.0.0/12,
        192.0.0.0/24,
        224.0.0.0/4,
        240.0.0.0/4,
        255.255.255.255/32
    }

    table inet proxy_suite_app_tun {
        chain output {
            type route hook output priority mangle; policy accept;
            ip daddr $RESERVED_IP return
${lib.concatMapStrings (cidr: ''
            ip daddr ${cidr} return
    '') art.localSubnets}
            ct mark ${toString art.fwmark} meta mark set ${toString art.fwmark}
            meta mark ${toString art.fwmark} return
        }
    }
  '';
  appTunWaitForInterface = pkgs.writeShellScript "proxy-suite-app-tun-wait-for-interface" ''
    set -euo pipefail
    for _ in $(${seqBin} 1 50); do
      if ${ip} link show dev ${lib.escapeShellArg art.interface} >/dev/null 2>&1; then
        exit 0
      fi
      ${sleepBin} 0.1
    done
    echo "proxy-suite: app TUN interface ${art.interface} did not appear in time" >&2
    exit 1
  '';
  appTunUpScript = pkgs.writeShellScript "proxy-suite-app-tun-up" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_app_tun 2>/dev/null || true
    ${nft} -f ${appTunChainFile}
    ${appTunWaitForInterface}
    ${ip} route replace default dev ${lib.escapeShellArg art.interface} table ${toString art.routeTable}
    ${ip} rule add fwmark ${toString art.fwmark} table ${toString art.routeTable} 2>/dev/null || true
  '';
  appTunDownScript = pkgs.writeShellScript "proxy-suite-app-tun-down" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_app_tun 2>/dev/null || true
    ${ip} route del default dev ${lib.escapeShellArg art.interface} table ${toString art.routeTable} 2>/dev/null || true
    ${ip} rule del fwmark ${toString art.fwmark} table ${toString art.routeTable} 2>/dev/null || true
  '';
  appTunUserRuleStart =
    pkgs.writeShellScript "proxy-suite-app-tun-user-start" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-app-tun-user-$uid"
      mark_comment="$rule_comment_prefix-mark"
      cgroup_root="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
      if ! [ -d "$cgroup_root" ]; then
        echo "proxy-suite: user cgroup root does not exist for uid $uid: $cgroup_root" >&2
        exit 1
      fi

      cgroup_dir=$(${findBin} "$cgroup_root" -type d -name ${lib.escapeShellArg appTunSliceName} | ${headBin} -n1 || true)
      if [ -z "$cgroup_dir" ]; then
        echo "proxy-suite: app TUN slice cgroup does not exist for uid $uid under $cgroup_root" >&2
        exit 1
      fi
      cgroup_path=''${cgroup_dir#/sys/fs/cgroup/}
      cgroup_level=$(printf '%s' "$cgroup_path" | ${awk} -F/ '{ print NF }')

      handles=$(${nft} -a list chain inet proxy_suite_app_tun output 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule inet proxy_suite_app_tun output handle "$handle" || true
        done <<< "$handles"
      fi

      printf '%s\n' \
        "add rule inet proxy_suite_app_tun output socket cgroupv2 level $cgroup_level \"$cgroup_path\" meta mark set ${toString art.fwmark} ct mark set ${toString art.fwmark} comment \"$mark_comment\"" \
        | ${nft} -f -
    '';
  appTunUserRuleStop =
    pkgs.writeShellScript "proxy-suite-app-tun-user-stop" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-app-tun-user-$uid"
      handles=$(${nft} -a list chain inet proxy_suite_app_tun output 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule inet proxy_suite_app_tun output handle "$handle" || true
        done <<< "$handles"
      fi
    '';
  appTproxyUpScript = pkgs.writeShellScript "proxy-suite-app-tproxy-up" ''
    set -euo pipefail
    ${nft} delete table ip proxy_suite_app_tproxy 2>/dev/null || true
    ${nft} -f ${appTproxyRulesFile}
    ${ip} route replace local default dev lo table ${toString artp.routeTable}
    ${ip} rule add fwmark ${toString artp.fwmark} table ${toString artp.routeTable} 2>/dev/null || true
  '';
  appTproxyDownScript = pkgs.writeShellScript "proxy-suite-app-tproxy-down" ''
    set -euo pipefail
    ${nft} delete table ip proxy_suite_app_tproxy 2>/dev/null || true
    ${ip} route del local default dev lo table ${toString artp.routeTable} 2>/dev/null || true
    ${ip} rule del fwmark ${toString artp.fwmark} table ${toString artp.routeTable} 2>/dev/null || true
  '';
  appTproxyUserRuleStart =
    pkgs.writeShellScript "proxy-suite-app-tproxy-user-start" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-app-tproxy-user-$uid"
      mark_comment="$rule_comment_prefix-mark"
      cgroup_root="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
      if ! [ -d "$cgroup_root" ]; then
        echo "proxy-suite: user cgroup root does not exist for uid $uid: $cgroup_root" >&2
        exit 1
      fi

      cgroup_dir=$(${findBin} "$cgroup_root" -type d -name ${lib.escapeShellArg appTproxySliceName} | ${headBin} -n1 || true)
      if [ -z "$cgroup_dir" ]; then
        echo "proxy-suite: app TProxy slice cgroup does not exist for uid $uid under $cgroup_root" >&2
        exit 1
      fi
      cgroup_path=''${cgroup_dir#/sys/fs/cgroup/}
      cgroup_level=$(printf '%s' "$cgroup_path" | ${awk} -F/ '{ print NF }')

      handles=$(${nft} -a list chain ip proxy_suite_app_tproxy output 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule ip proxy_suite_app_tproxy output handle "$handle" || true
        done <<< "$handles"
      fi

      printf '%s\n' \
        "add rule ip proxy_suite_app_tproxy output socket cgroupv2 level $cgroup_level \"$cgroup_path\" meta mark set ${toString artp.fwmark} ct mark set ${toString artp.fwmark} comment \"$mark_comment\"" \
        | ${nft} -f -
    '';
  appTproxyUserRuleStop =
    pkgs.writeShellScript "proxy-suite-app-tproxy-user-stop" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-app-tproxy-user-$uid"
      handles=$(${nft} -a list chain ip proxy_suite_app_tproxy output 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule ip proxy_suite_app_tproxy output handle "$handle" || true
        done <<< "$handles"
      fi
    '';
  appZapretUserRuleStart =
    pkgs.writeShellScript "proxy-suite-app-zapret-user-start" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-app-zapret-user-$uid"
      mark_comment="$rule_comment_prefix-mark"
      cgroup_root="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
      if ! [ -d "$cgroup_root" ]; then
        echo "proxy-suite: user cgroup root does not exist for uid $uid: $cgroup_root" >&2
        exit 1
      fi

      cgroup_dir=$(${findBin} "$cgroup_root" -type d -name ${lib.escapeShellArg appZapretSliceName} | ${headBin} -n1 || true)
      if [ -z "$cgroup_dir" ]; then
        echo "proxy-suite: app zapret slice cgroup does not exist for uid $uid under $cgroup_root" >&2
        exit 1
      fi
      cgroup_path=''${cgroup_dir#/sys/fs/cgroup/}
      cgroup_level=$(printf '%s' "$cgroup_path" | ${awk} -F/ '{ print NF }')

      handles=$(${nft} -a list chain inet proxy_suite_app_zapret_mark output 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule inet proxy_suite_app_zapret_mark output handle "$handle" || true
        done <<< "$handles"
      fi

      printf '%s\n' \
        "add rule inet proxy_suite_app_zapret_mark output socket cgroupv2 level $cgroup_level \"$cgroup_path\" meta mark set meta mark or ${toString arz.filterMark} ct mark set ct mark or ${toString arz.filterMark} comment \"$mark_comment\"" \
        | ${nft} -f -
    '';
  appZapretUserRuleStop =
    pkgs.writeShellScript "proxy-suite-app-zapret-user-stop" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-app-zapret-user-$uid"
      handles=$(${nft} -a list chain inet proxy_suite_app_zapret_mark output 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule inet proxy_suite_app_zapret_mark output handle "$handle" || true
        done <<< "$handles"
      fi
    '';

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
      APP_ROUTING_ENABLED="${if ar.enable then "1" else "0"}"
      APP_ROUTING_PROXYCHAINS_ENABLED="${if ar.proxychains.enable then "1" else "0"}"
      APP_ROUTING_TUN_ENABLED="${if art.enable then "1" else "0"}"
      APP_ROUTING_TPROXY_ENABLED="${if artp.enable then "1" else "0"}"
      APP_ROUTING_ZAPRET_ENABLED="${if (arz.enable && cfg.zapret.enable) then "1" else "0"}"
      APP_ROUTING_PROFILES_FILE="${appRoutingProfilesFile}"
      PROXYCHAINS_CONFIG="${proxychainsConfigFile}"
      APP_TUN_SLICE_BASE="proxy-suite-app-tun"
      APP_TUN_ANCHOR_UNIT="proxy-suite-app-tun-anchor.service"
      APP_TPROXY_SLICE_BASE="proxy-suite-app-tproxy"
      APP_TPROXY_ANCHOR_UNIT="proxy-suite-app-tproxy-anchor.service"
      APP_ZAPRET_SLICE_BASE="proxy-suite-app-zapret"
      APP_ZAPRET_ANCHOR_UNIT="proxy-suite-app-zapret-anchor.service"

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
        echo "  wrap <profile> -- <cmd>   run a command via an appRouting profile"
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
        if [ "$APP_ROUTING_ENABLED" != "1" ]; then
          echo "appRouting is not enabled in services.proxy-suite.appRouting."
          exit 1
        fi
      }

      _profile_route() {
        local profile="$1"
        ${jq} -r --arg name "$profile" '.[] | select(.name == $name) | .route' "$APP_ROUTING_PROFILES_FILE"
      }

      _tun_scope_running() {
        ${systemctl} --user list-units --type=scope --state=running --plain --no-legend 'proxy-suite-app-tun-*' \
          | ${grepBin} -q .
      }

      _any_app_tun_user_active() {
        ${systemctl} list-units --type=service --state=active --plain --no-legend 'proxy-suite-app-tun-user@*.service' \
          | ${grepBin} -q .
      }

      _tproxy_scope_running() {
        ${systemctl} --user list-units --type=scope --state=running --plain --no-legend 'proxy-suite-app-tproxy-*' \
          | ${grepBin} -q .
      }

      _any_app_tproxy_user_active() {
        ${systemctl} list-units --type=service --state=active --plain --no-legend 'proxy-suite-app-tproxy-user@*.service' \
          | ${grepBin} -q .
      }

      _zapret_scope_running() {
        ${systemctl} --user list-units --type=scope --state=running --plain --no-legend 'proxy-suite-app-zapret-*' \
          | ${grepBin} -q .
      }

      _any_app_zapret_user_active() {
        ${systemctl} list-units --type=service --state=active --plain --no-legend 'proxy-suite-app-zapret-user@*.service' \
          | ${grepBin} -q .
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
          if [ "$(${jq} 'length' "$APP_ROUTING_PROFILES_FILE")" -eq 0 ]; then
            echo "No appRouting profiles configured."
          else
            printf "  %-24s %s\n" "PROFILE" "ROUTE"
            ${jq} -r '.[] | "  " + (.name | tostring) + "\t" + (.route | tostring)' \
              "$APP_ROUTING_PROFILES_FILE" \
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
            echo "Unknown appRouting profile: $profile"
            exit 1
          fi

          case "$route" in
            direct)
              exec "$@"
              ;;
            proxychains)
              if [ "$APP_ROUTING_PROXYCHAINS_ENABLED" != "1" ]; then
                echo "Profile '$profile' uses route=proxychains, but appRouting.proxychains.enable is false."
                exit 1
              fi
              exec ${proxychains4} ${proxychainsQuietArg}-f "$PROXYCHAINS_CONFIG" "$@"
              ;;
            tun)
              if [ "$APP_ROUTING_TUN_ENABLED" != "1" ]; then
                echo "Profile '$profile' uses route=tun, but appRouting.backends.tun.enable is false."
                exit 1
              fi

              uid="$(${idBin} -u)"
              scope_unit="proxy-suite-app-tun-$profile-$$"

              ${systemctl} --user start "$APP_TUN_ANCHOR_UNIT"
              ${systemctl} start proxy-suite-app-tun.service
              ${systemctl} start "proxy-suite-app-tun-user@$uid.service"

              if ${systemdRun} --user --scope --quiet --collect --same-dir \
                --slice="$APP_TUN_SLICE_BASE" \
                --unit="$scope_unit" \
                "$@"; then
                status=0
              else
                status=$?
              fi

              if ! _tun_scope_running; then
                ${systemctl} stop "proxy-suite-app-tun-user@$uid.service" || true
                ${systemctl} --user stop "$APP_TUN_ANCHOR_UNIT" || true
                if ! _any_app_tun_user_active; then
                  ${systemctl} stop proxy-suite-app-tun.service || true
                fi
              fi

              exit "$status"
              ;;
            tproxy)
              if [ "$APP_ROUTING_TPROXY_ENABLED" != "1" ]; then
                echo "Profile '$profile' uses route=tproxy, but appRouting.backends.tproxy.enable is false."
                exit 1
              fi
              if ${systemctl} is-active --quiet proxy-suite-tun.service; then
                echo "Global proxy-suite-tun.service is active. Stop it before using route=tproxy profiles."
                exit 1
              fi
              if ${systemctl} is-active --quiet proxy-suite-tproxy.service; then
                echo "Global proxy-suite-tproxy.service is active. Stop it before using route=tproxy profiles."
                exit 1
              fi

              uid="$(${idBin} -u)"
              scope_unit="proxy-suite-app-tproxy-$profile-$$"

              ${systemctl} --user start "$APP_TPROXY_ANCHOR_UNIT"
              ${systemctl} start proxy-suite-app-tproxy.service
              ${systemctl} start "proxy-suite-app-tproxy-user@$uid.service"

              if ${systemdRun} --user --scope --quiet --collect --same-dir \
                --slice="$APP_TPROXY_SLICE_BASE" \
                --unit="$scope_unit" \
                "$@"; then
                status=0
              else
                status=$?
              fi

              if ! _tproxy_scope_running; then
                ${systemctl} stop "proxy-suite-app-tproxy-user@$uid.service" || true
                ${systemctl} --user stop "$APP_TPROXY_ANCHOR_UNIT" || true
                if ! _any_app_tproxy_user_active; then
                  ${systemctl} stop proxy-suite-app-tproxy.service || true
                fi
              fi

              exit "$status"
              ;;
            zapret)
              if [ "$APP_ROUTING_ZAPRET_ENABLED" != "1" ]; then
                echo "Profile '$profile' uses route=zapret, but the app-zapret backend or zapret service is not enabled."
                exit 1
              fi
              if ${systemctl} is-active --quiet proxy-suite-tun.service; then
                echo "Global proxy-suite-tun.service is active. Stop it before using route=zapret profiles."
                exit 1
              fi
              if ${systemctl} is-active --quiet proxy-suite-tproxy.service; then
                echo "Global proxy-suite-tproxy.service is active. Stop it before using route=zapret profiles."
                exit 1
              fi

              uid="$(${idBin} -u)"
              scope_unit="proxy-suite-app-zapret-$profile-$$"

              ${systemctl} --user start "$APP_ZAPRET_ANCHOR_UNIT"
              ${systemctl} start proxy-suite-app-zapret.service
              ${systemctl} start "proxy-suite-app-zapret-user@$uid.service"

              if ${systemdRun} --user --scope --quiet --collect --same-dir \
                --slice="$APP_ZAPRET_SLICE_BASE" \
                --unit="$scope_unit" \
                "$@"; then
                status=0
              else
                status=$?
              fi

              if ! _zapret_scope_running; then
                ${systemctl} stop "proxy-suite-app-zapret-user@$uid.service" || true
                ${systemctl} --user stop "$APP_ZAPRET_ANCHOR_UNIT" || true
                if ! _any_app_zapret_user_active; then
                  ${systemctl} stop proxy-suite-app-zapret.service || true
                fi
              fi

              exit "$status"
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
  environment.systemPackages = [ proxyCtl ];

  # nftables must be on for TProxy to work.
  networking.nftables.enable = lib.mkIf (sb.tproxy.enable || art.enable || artp.enable || arz.enable) (lib.mkDefault true);

  users.groups = lib.mkIf (cfg.enable && userControlEnabled) {
    "${uc.group}" = { };
  };

  security.polkit.enable = lib.mkIf (cfg.enable && userControlEnabled) true;
  security.polkit.extraConfig = lib.mkIf (cfg.enable && userControlEnabled) (lib.mkAfter ''
    polkit.addRule(function(action, subject) {
      if (!subject.isInGroup("${uc.group}")) {
        return null;
      }

      if (action.id !== "org.freedesktop.systemd1.manage-units") {
        return null;
      }

      var unit = action.lookup("unit");
      ${userControlPolkitRules}

      return null;
    });
  '');

  systemd.user.services =
    lib.optionalAttrs art.enable {
      proxy-suite-app-tun-anchor = {
        description = "Anchor service for proxy-suite app TUN slice";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Slice = appTunSliceName;
          ExecStart = "${pkgs.coreutils}/bin/true";
          ExecStop = "${pkgs.coreutils}/bin/true";
        };
      };
    }
    // lib.optionalAttrs artp.enable {
      proxy-suite-app-tproxy-anchor = {
        description = "Anchor service for proxy-suite app TProxy slice";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Slice = appTproxySliceName;
          ExecStart = "${pkgs.coreutils}/bin/true";
          ExecStop = "${pkgs.coreutils}/bin/true";
        };
      };
    }
    // lib.optionalAttrs (arz.enable && cfg.zapret.enable) {
      proxy-suite-app-zapret-anchor = {
        description = "Anchor service for proxy-suite app zapret slice";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Slice = appZapretSliceName;
          ExecStart = "${pkgs.coreutils}/bin/true";
          ExecStop = "${pkgs.coreutils}/bin/true";
        };
      };
    };

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
      assertion = ar.enable || ar.profiles == [ ];
      message = "proxy-suite: appRouting.profiles requires appRouting.enable = true";
    }
    {
      assertion = !ar.proxychains.enable || ar.enable;
      message = "proxy-suite: appRouting.proxychains.enable requires appRouting.enable = true";
    }
    {
      assertion = builtins.length effectiveAppRoutingProfileNames == builtins.length (lib.unique effectiveAppRoutingProfileNames);
      message = "proxy-suite: appRouting profile names must be unique";
    }
    {
      assertion = !hasProxychainsProfiles || ar.proxychains.enable;
      message = "proxy-suite: route=proxychains in appRouting.profiles requires appRouting.proxychains.enable = true";
    }
    {
      assertion = !art.enable || ar.enable;
      message = "proxy-suite: appRouting.backends.tun.enable requires appRouting.enable = true";
    }
    {
      assertion = !(hasTunProfiles && !art.enable);
      message = "proxy-suite: route=tun in appRouting profiles requires appRouting.backends.tun.enable = true";
    }
    {
      assertion = !artp.enable || ar.enable;
      message = "proxy-suite: appRouting.backends.tproxy.enable requires appRouting.enable = true";
    }
    {
      assertion = !(hasTproxyProfiles && !artp.enable);
      message = "proxy-suite: route=tproxy in appRouting profiles requires appRouting.backends.tproxy.enable = true";
    }
    {
      assertion = !arz.enable || ar.enable;
      message = "proxy-suite: appRouting.backends.zapret.enable requires appRouting.enable = true";
    }
    {
      assertion = !arz.enable || cfg.zapret.enable;
      message = "proxy-suite: appRouting.backends.zapret.enable requires zapret.enable = true";
    }
    {
      assertion = !(hasZapretProfiles && (!arz.enable || !cfg.zapret.enable));
      message = "proxy-suite: route=zapret in appRouting profiles requires appRouting.backends.zapret.enable = true and zapret.enable = true";
    }
    {
      assertion = !(art.enable && sb.tproxy.enable && art.fwmark == sb.fwmark);
      message = "proxy-suite: appRouting.backends.tun.fwmark must differ from singBox.fwmark when singBox.tproxy.enable = true";
    }
    {
      assertion = !(art.enable && sb.tproxy.enable && art.fwmark == sb.proxyMark);
      message = "proxy-suite: appRouting.backends.tun.fwmark must differ from singBox.proxyMark when singBox.tproxy.enable = true";
    }
    {
      assertion = !(art.enable && sb.tproxy.enable && art.routeTable == sb.routeTable);
      message = "proxy-suite: appRouting.backends.tun.routeTable must differ from singBox.routeTable when singBox.tproxy.enable = true";
    }
    {
      assertion = !(artp.enable && artp.fwmark == sb.fwmark);
      message = "proxy-suite: appRouting.backends.tproxy.fwmark must differ from singBox.fwmark";
    }
    {
      assertion = !(artp.enable && artp.fwmark == sb.proxyMark);
      message = "proxy-suite: appRouting.backends.tproxy.fwmark must differ from singBox.proxyMark";
    }
    {
      assertion = !(artp.enable && artp.routeTable == sb.routeTable);
      message = "proxy-suite: appRouting.backends.tproxy.routeTable must differ from singBox.routeTable";
    }
    {
      assertion = !(art.enable && artp.enable && art.fwmark == artp.fwmark);
      message = "proxy-suite: appRouting.backends.tun.fwmark and appRouting.backends.tproxy.fwmark must differ";
    }
    {
      assertion = !(art.enable && artp.enable && art.routeTable == artp.routeTable);
      message = "proxy-suite: appRouting.backends.tun.routeTable and appRouting.backends.tproxy.routeTable must differ";
    }
    {
      assertion = !(arz.enable && arz.filterMark == sb.fwmark);
      message = "proxy-suite: appRouting.backends.zapret.filterMark must differ from singBox.fwmark";
    }
    {
      assertion = !(arz.enable && arz.filterMark == sb.proxyMark);
      message = "proxy-suite: appRouting.backends.zapret.filterMark must differ from singBox.proxyMark";
    }
    {
      assertion = !(art.enable && arz.enable && art.fwmark == arz.filterMark);
      message = "proxy-suite: appRouting.backends.tun.fwmark and appRouting.backends.zapret.filterMark must differ";
    }
    {
      assertion = !(artp.enable && arz.enable && artp.fwmark == arz.filterMark);
      message = "proxy-suite: appRouting.backends.tproxy.fwmark and appRouting.backends.zapret.filterMark must differ";
    }
    {
      assertion = !(arz.enable && builtins.elem arz.filterMark [ 536870912 1073741824 ]);
      message = "proxy-suite: appRouting.backends.zapret.filterMark must not use zapret internal desync mark bits";
    }
    {
      assertion = !(arz.enable && builtins.elem sb.fwmark [ 67108864 134217728 ]);
      message = "proxy-suite: singBox.fwmark must not use app-zapret internal desync mark bits";
    }
    {
      assertion = !(arz.enable && builtins.elem sb.proxyMark [ 67108864 134217728 ]);
      message = "proxy-suite: singBox.proxyMark must not use app-zapret internal desync mark bits";
    }
    {
      assertion = !(art.enable && arz.enable && builtins.elem art.fwmark [ 67108864 134217728 ]);
      message = "proxy-suite: appRouting.backends.tun.fwmark must not use app-zapret internal desync mark bits";
    }
    {
      assertion = !(artp.enable && arz.enable && builtins.elem artp.fwmark [ 67108864 134217728 ]);
      message = "proxy-suite: appRouting.backends.tproxy.fwmark must not use app-zapret internal desync mark bits";
    }
    {
      assertion = !(arz.enable && builtins.elem arz.filterMark [ 67108864 134217728 ]);
      message = "proxy-suite: appRouting.backends.zapret.filterMark must not use app-zapret internal desync mark bits";
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
      conflicts = [
        "proxy-suite-tun.service"
        "proxy-suite-app-tproxy.service"
      ];
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
  // lib.optionalAttrs art.enable {
    proxy-suite-app-tun = {
      description = "sing-box app-routing TUN backend";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${startAppTun}";
        ExecStartPost = "${appTunUpScript}";
        ExecStopPost = "${appTunDownScript}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "proxy-suite-app-tun";
        StateDirectory = "proxy-suite";
      };
    };

    "proxy-suite-app-tun-user@" = {
      description = "Enable proxy-suite app TUN marking for user %i";
      requires = [ "proxy-suite-app-tun.service" ];
      after = [ "proxy-suite-app-tun.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${appTunUserRuleStart} %i";
        ExecStop = "${appTunUserRuleStop} %i";
      };
    };
  }
  // lib.optionalAttrs artp.enable {
    proxy-suite-app-tproxy = {
      description = "proxy-suite app-routing TProxy backend";
      after = [
        "network.target"
        "proxy-suite-socks.service"
      ];
      requires = [ "proxy-suite-socks.service" ];
      conflicts = [
        "proxy-suite-tproxy.service"
        "proxy-suite-tun.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${appTproxyUpScript}";
        ExecStop = "${appTproxyDownScript}";
      };
    };

    "proxy-suite-app-tproxy-user@" = {
      description = "Enable proxy-suite app TProxy marking for user %i";
      requires = [ "proxy-suite-app-tproxy.service" ];
      after = [ "proxy-suite-app-tproxy.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${appTproxyUserRuleStart} %i";
        ExecStop = "${appTproxyUserRuleStop} %i";
      };
    };
  }
  // lib.optionalAttrs (arz.enable && cfg.zapret.enable) {
    "proxy-suite-app-zapret-user@" = {
      description = "Enable proxy-suite app zapret marking for user %i";
      requires = [ "proxy-suite-app-zapret.service" ];
      after = [ "proxy-suite-app-zapret.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${appZapretUserRuleStart} %i";
        ExecStop = "${appZapretUserRuleStop} %i";
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
