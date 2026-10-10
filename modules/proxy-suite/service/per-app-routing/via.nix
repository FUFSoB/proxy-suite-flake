# `proxy-ctl apps run --via <tag>`: an app's traffic straight into an "interface" AmneziaWG
# outbound, past the proxy (proxy-suite-per-app-via@awg-<hex>); or, for any other outbound,
# into a pin slot of per-app TProxy or TUN, whose selector in the backend sends it there
# (proxy-suite-per-app-via-<route>@<hex>). The tag goes in hex: that keeps it out of
# systemd's slice hierarchy, where "de" would be the parent of "de-2", and nft's cgroup match
# would take both.
{ ctx, userRules }:

let
  inherit (ctx)
    lib
    pkgs
    cfg
    constants
    perAppRoutingCfg
    perAppViaInterfaceOutbounds
    perAppViaRuntime
    perAppViaProfiles
    perAppPinSlots
    perAppPinTproxy
    perAppPinTun
    perAppRoutingTun
    singBoxCfg
    builders
    proxySuiteScriptsDir
    python3
    ip
    nft
    jq
    awk
    ;
  inherit (constants)
    awgPerAppRulePriority
    awgPerAppUnreachablePriority
    runtimeOutboundsDir
    awgRuntimeIfacePrefix
    awgRuntimeIfaceSlots
    awgRuntimeIfaceTableBase
    awgRuntimeIfacePerAppFwmarkBase
    awgRuntimeIfaceDnsBasePort
    ;
  inherit (import ../../nftables.nix { inherit lib pkgs cfg; })
    perAppPinTproxyRulesFiles
    perAppPinTunChainFiles
    ;

  remoteDns = cfg.proxy.dns.remote.address;
  # proxy.dns.remote, for a profile with no DNS line of its own, if it is an address.
  fallbackDns = lib.optional (
    builtins.match "[0-9.]+|[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*" remoteDns != null
  ) remoteDns;

  # tag -> what an instance needs of its outbound. proxy-ctl reads it too, to tell which tags
  # take this path.
  perAppViaFile = pkgs.writeText "proxy-suite-per-app" (
    builtins.toJSON (
      lib.listToAttrs (
        map (
          ob:
          lib.nameValuePair ob.tag {
            inherit (ob) interface;
            table = ob.routeTable;
            mark = ob.perAppFwmark;
            dnsPort = ob.perAppDnsPort;
            unit = "proxy-suite-awg-${ob.name}.service";
            dnsFile = "/run/proxy-suite-awg-${ob.name}/dns";
            inherit fallbackDns;
          }
        ) perAppViaInterfaceOutbounds
      )
    )
  );

  ipFamily = cidr: if lib.hasInfix ":" cidr then "ip6" else "ip";

  # Runs `action` for a via instance kept running (perAppKeptViaKeys), `key` as shell text.
  keptCase =
    key: action:
    lib.optionalString (ctx.perAppKeptViaKeys != [ ]) ''
      case ${key} in
        ${lib.concatStringsSep " | " ctx.perAppKeptViaKeys}) ${action} ;;
      esac
    '';

  # $1, the instance, to $key, $tag and its outbound's $interface, $table and $mark. An
  # awg-<hex> instance is an "interface" outbound; app-<hex> a global profile, which
  # proxy-suite-awg-app@<name> has brought up on a slot of its own.
  resolveInstance = ''
    key=''${1:-}
    if [[ ! $key =~ ^(awg|app)-([0-9a-f][0-9a-f]){1,64}$ ]]; then
      echo "proxy-suite: '$key' is not a per-app via instance" >&2
      exit 1
    fi
    tag=$(printf '%b' "$(printf '%s' "''${key#*-}" | ${pkgs.gnused}/bin/sed 's/../\\x&/g')")
    if [[ ! $tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      echo "proxy-suite: '$tag' is not an outbound tag" >&2
      exit 1
    fi
    if [[ $key == app-* ]]; then
      ${
        if perAppViaProfiles then
          ''
            slot=$(${pkgs.coreutils}/bin/head -n 1 "/run/proxy-suite-awg-app-$tag/slot" 2>/dev/null || true)
            if [[ ! $slot =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( slot >= ${toString constants.awgAppSlots} )); then
              echo "proxy-suite: AmneziaWG profile '$tag' is not up for apps (proxy-suite-awg-app@$tag)" >&2
              exit 1
            fi
            entry=$(${jq} -nc --arg t "$tag" --argjson s "$slot" --argjson fallback ${lib.escapeShellArg (builtins.toJSON fallbackDns)} '{
              interface: ("${constants.awgAppIfacePrefix}" + ($s | tostring)),
              table: (${toString constants.awgAppTableBase} + $s),
              mark: (${toString constants.awgAppPerAppFwmarkBase} + $s),
              dnsPort: (${toString constants.awgAppDnsBasePort} + $s),
              dnsFile: ("/run/proxy-suite-awg-app-" + $t + "/dns"),
              fallbackDns: $fallback
            }')
          ''
        else
          ''
            echo "proxy-suite: apps cannot run through global AmneziaWG profiles here" >&2
            exit 1
          ''
      }
    elif ! entry=$(${jq} -ce --arg t "$tag" '.[$t] // empty' ${perAppViaFile}); then
      ${lib.optionalString perAppViaRuntime ''
        # One added at runtime: the slot its interface runs in, as proxy-suite-awg-if@ keeps it;
        # else the spool's, which is group-writable (O_NOFOLLOW), and names the slot it gets
        # next, not the one a tag removed and added again still runs in.
        slot_file="/run/proxy-suite-awg-if-$tag/slot"
        if [[ -s $slot_file && ! -L $slot_file ]]; then
          slot=$(${pkgs.coreutils}/bin/head -n 1 "$slot_file")
        else
          slot=$(${pkgs.coreutils}/bin/dd if="${runtimeOutboundsDir}/$tag.iface" iflag=nofollow,nonblock status=none 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1 || true)
        fi
        if [[ $slot =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( slot < ${toString awgRuntimeIfaceSlots} )); then
          entry=$(${jq} -nc --arg t "$tag" --argjson s "$slot" --argjson fallback ${lib.escapeShellArg (builtins.toJSON fallbackDns)} '{
            interface: ("${awgRuntimeIfacePrefix}" + ($s | tostring)),
            table: (${toString awgRuntimeIfaceTableBase} + $s),
            mark: (${toString awgRuntimeIfacePerAppFwmarkBase} + $s),
            dnsPort: (${toString awgRuntimeIfaceDnsBasePort} + $s),
            dnsFile: ("/run/proxy-suite-awg-if-" + $t + "/dns"),
            fallbackDns: $fallback
          }')
        fi
      ''}
      if [[ -z ''${entry:-} ]]; then
        echo "proxy-suite: '$tag' is not an \"interface\" AmneziaWG outbound" >&2
        exit 1
      fi
    fi
    interface=$(${jq} -r .interface <<< "$entry")
    table=$(${jq} -r .table <<< "$entry")
    mark=$(${jq} -r .mark <<< "$entry")
    nft_table="proxy_suite_per_app_via_$mark"
    dns_port=$(${jq} -r .dnsPort <<< "$entry")
  '';

  # $servers: the profile's own DNS servers, else proxy.dns.remote.
  dnsServers = ''
    dns_file=$(${jq} -r .dnsFile <<< "$entry")
    servers=()
    add_servers() {
      local server
      while read -r server; do
        if [[ $server =~ ^[0-9A-Fa-f:.]+$ ]]; then servers+=("$server"); fi
      done
    }
    if [[ -s $dns_file ]]; then add_servers < "$dns_file"; fi
    if (( ! ''${#servers[@]} )); then add_servers < <(${jq} -r '.fallbackDns[]' <<< "$entry"); fi
  '';

  rulesDown = ''
    for family in -4 -6; do
      while ${ip} "$family" rule del pref ${toString awgPerAppRulePriority} fwmark "$mark" 2>/dev/null; do :; done
      while ${ip} "$family" rule del pref ${toString awgPerAppUnreachablePriority} fwmark "$mark" 2>/dev/null; do :; done
    done
  '';

  viaUp = pkgs.writeShellScript "proxy-suite-per-app" ''
    set -euo pipefail
    ${resolveInstance}
    ${dnsServers}
    dns=""
    if (( ''${#servers[@]} )); then
      # By the conntrack mark, which only the app's own connections carry: the forwarder's
      # queries have the packet mark alone.
      dns="ct mark $mark meta l4proto { tcp, udp } th dport 53 redirect to :$dns_port"
    else
      echo "proxy-suite: AmneziaWG outbound '$tag' names no DNS server: apps run via it look names up outside the tunnel" >&2
    fi

    ${nft} delete table inet "$nft_table" 2>/dev/null || true
    ${rulesDown}

    ${nft} -f - <<EOF
    table inet $nft_table {
        # The per-user cgroup mark rules go here (proxy-suite-per-app-via-user@).
        chain app_mark {
        }
        # Replies find their way back by the mark, past a reverse-path check: only those
        # out of the tunnel, never the tunnel's own packets on the uplink.
        chain prerouting {
            type filter hook prerouting priority mangle - 10; policy accept;
            iifname "$interface" ct mark $mark meta mark set $mark
        }
        # Before the TProxy chains, which let this mark past.
        chain output {
            type route hook output priority mangle - 10; policy accept;
            ct direction reply return
            # A packet marked already is not the app's to take: the tunnel's own (its FwMark),
            # which still looks like it came from the app's socket and, taken, would be routed
            # back into the tunnel; the DNS forwarder's; or proxy-suite's own.
            meta mark != 0 return
            ct mark $mark meta mark set $mark
            meta mark $mark return
            # Lookups, wherever the app's resolver is, go to the forwarder (nat_output),
            # which asks the profile's resolvers through the tunnel.
            meta l4proto { tcp, udp } th dport 53 goto app_mark
            # Only what never leaves the host or its link stays out. Private ranges go in, as
            # a VPN takes them: the server's own address (where its VPN-only names resolve)
            # and the networks behind it are there. The LAN is localSubnets.
            ip daddr { 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } return
            ip6 daddr { ::1, fe80::/10, ff00::/8 } return
    ${lib.concatMapStrings (cidr: ''
      ${ipFamily cidr} daddr ${cidr} return
    '') perAppRoutingCfg.via.localSubnets}
            goto app_mark
        }
        chain nat_output {
            type nat hook output priority dstnat; policy accept;
            $dns
        }
        # The app picked its source address on the host's route, before the mark moved it here.
        chain nat_postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "$interface" meta mark $mark masquerade
        }
        # The app's packets out of any other interface: the ip rules are gone (networkd
        # drops rules it did not make), and the main table took them to the uplink.
        chain misrouted {
            type filter hook postrouting priority filter; policy accept;
            meta mark $mark oifname != { "lo", "$interface" } drop
        }
    }
    EOF

    for family in -4 -6; do
      # Turned away while the table has no route of the family: the interface is down, or
      # has no address of it. IPv6 may be off altogether.
      ${ip} "$family" rule add pref ${toString awgPerAppRulePriority} fwmark "$mark" lookup "$table" \
        && ${ip} "$family" rule add pref ${toString awgPerAppUnreachablePriority} fwmark "$mark" unreachable \
        || [[ $family == -6 ]]
    done
  '';

  # The forwarder, for the unit's lifetime; it has nothing to ask without a server.
  viaDns = pkgs.writeShellScript "proxy-suite-per-app" ''
    set -euo pipefail
    ${resolveInstance}
    ${dnsServers}
    exec ${python3} ${proxySuiteScriptsDir}/per_app_dns.py --port "$dns_port" --mark "$mark" "''${servers[@]}"
  '';

  # A failure keeps the marking and the unreachable rule, so the apps are turned away rather
  # than sent out directly until the restart; viaUp clears it. A stop takes it all down.
  viaDown = pkgs.writeShellScript "proxy-suite-per-app" ''
    set -uo pipefail
    ${resolveInstance}
    if [[ ''${SERVICE_RESULT:-success} != success ]]; then
      echo "proxy-suite: per-app via $1 failed ($SERVICE_RESULT): its apps are held until it is back" >&2
      exit 0
    fi
    ${nft} delete table inet "$nft_table" 2>/dev/null || true
    ${rulesDown}
  '';

  # Instance <uid>-<key>, the key awg-<hex> or <route>-<hex>: the user's apps in the slice
  # of what they run via.
  userPrelude = ''
    instance=''${1:-}
    if [[ ! $instance =~ ^([0-9]+)-((awg|app|tproxy|tun)-[0-9a-f]+)$ ]]; then
      echo "proxy-suite: '$instance' is not <uid>-<per-app via instance>" >&2
      exit 1
    fi
    key=''${BASH_REMATCH[2]}
    case "$key" in
      awg-* | app-*)
        set -- "$key"
        ${resolveInstance}
        nft_chain=app_mark
        ;;
      ${lib.concatMapStrings (route: ''
        ${route}-*)
          set -- "''${key#${route}-}"
          ${decodeTag}
          ${pinSlot route false}
          if [[ -z $slot ]]; then
            echo "proxy-suite: no ${route} pin slot holds '$tag'" >&2
            exit 1
          fi
          nft_chain=${pinRoutes.${route}.nftChain}
          ;;
      '') pinRouteNames}
      *)
        echo "proxy-suite: '$key' is not run via here" >&2
        exit 1
        ;;
    esac
    slice_name="proxy-suite-per-app-via-$key.slice"
    set -- "''${instance%%-*}"
  '';
  # The hold (user-rules.nix), by what the key runs via: an AmneziaWG interface takes the
  # private ranges too (as viaUp's chain does), a pin slot what its route's backend takes.
  viaHold = ''
    case "$key" in
      awg-* | app-*)
        ${userRules.mkHoldBodies {
          marks = [
            "$mark"
            (toString cfg.proxy.tproxy.proxyMark)
          ];
          allow = [
            "127.0.0.0/8"
            "169.254.0.0/16"
            "224.0.0.0/4"
            "255.255.255.255/32"
            "::1/128"
            "fe80::/10"
            "ff00::/8"
          ]
          ++ perAppRoutingCfg.via.localSubnets;
        }}
        ;;
      tproxy-*) ${userRules.tproxyHold "$mark"} ;;
      tun-*) ${userRules.tunHold "$mark"} ;;
    esac
  '';
  viaUserRule = userRules.mkUserRuleStart {
    name = "per-app-via-$key";
    nftFamily = "inet";
    nftTable = "$nft_table";
    nftChain = "$nft_chain";
    sliceNameArg = ''"$slice_name"'';
    sliceLabel = "app via";
    markRule = "meta mark set $mark ct mark set $mark";
    prelude = userPrelude;
    hold = viaHold;
  };
  viaUserStop = userRules.mkUserRuleStop {
    name = "per-app-via-$key";
    nftFamily = "inet";
    nftTable = "$nft_table";
    nftChain = "$nft_chain";
    prelude = userPrelude;
    hold = true;
    unitName = ''"proxy-suite-per-app-via-user@$instance.service"'';
  };

  # $1, a user unit's instance <uid>-<key>, to $key and $via_unit, the unit whose table
  # the key's user rules go in.
  viaUserKey = ''
    instance=''${1:-}
    if [[ ! $instance =~ ^[0-9]+-((awg|app|tproxy|tun)-[0-9a-f]+)$ ]]; then
      echo "proxy-suite: '$instance' is not <uid>-<per-app via instance>" >&2
      exit 1
    fi
    key=''${BASH_REMATCH[1]}
    case "$key" in
      awg-* | app-*) via_unit="proxy-suite-per-app-via@$key.service" ;;
      *) via_unit="proxy-suite-per-app-via-''${key%%-*}@''${key#*-}.service" ;;
    esac
  '';
  # Held while a user's rule goes in, and while the last user's unit takes the via unit
  # down: no rule lands in a table on its way out, to leave its app unmarked.
  viaUsersLock = ''
    ${pkgs.coreutils}/bin/mkdir -p ${pinDir}
    exec 8>>"${pinDir}/users-$key.lock"
    ${flock} 8
  '';
  viaUserStart = pkgs.writeShellScript "proxy-suite-per-app" ''
    set -euo pipefail
    ${viaUserKey}
    ${viaUsersLock}
    # proxy-ctl starts it first; one on its way down takes the table with it.
    if [[ $(${constants.systemctl} show --property=ActiveState --value "$via_unit") != active ]]; then
      echo "proxy-suite: $via_unit is not up" >&2
      exit 1
    fi
    ${viaUserRule} "$1"
  '';
  # ExecStopPost of a user's unit: with no other user's left, the via unit goes, and the
  # global profile it ran through, unless kept running. perApp members may only start those (polkit.nix):
  # stopping one under another user's apps would send them out unmarked.
  viaRetire = pkgs.writeShellScript "proxy-suite-per-app" ''
    set -euo pipefail
    ${viaUserKey}
    # Its own restart (a job of that type until the stop half is done) comes straight back.
    if ${constants.systemctl} list-jobs --no-legend "proxy-suite-per-app-via-user@$1.service" \
      | ${awk} '$3 == "restart" { found = 1 } END { exit !found }'; then
      exit 0
    fi
    ${keptCase "$key" "exit 0"}
    ${viaUsersLock}
    others=$(${constants.systemctl} list-units --plain --no-legend --state=active,activating,reloading \
      "proxy-suite-per-app-via-user@*-$key.service" \
      | ${awk} -v self="proxy-suite-per-app-via-user@$1.service" '$1 != self')
    [[ -z $others ]] || exit 0
    was=$(${constants.systemctl} show --property=ActiveState --value "$via_unit" || true)
    ${constants.systemctl} stop "$via_unit"
    # A failed one kept its rules to hold its apps (viaDown), and a stop runs nothing more for
    # it: with no app left, they go here.
    if [[ $was == failed && ( $key == awg-* || $key == app-* ) ]]; then
      SERVICE_RESULT=success ${viaDown} "$key" || true
      ${constants.systemctl} reset-failed "$via_unit" 2>/dev/null || true
    fi
    ${lib.optionalString perAppViaProfiles ''
      # After the via unit: its stop reads the profile's slot.
      if [[ $key == app-* ]]; then
        set -- "''${key#app-}"
        ${decodeTag}
        ${constants.systemctl} stop "proxy-suite-awg-app@$tag.service"
      fi
    ''}
  '';
  # ExecStartPost of the via units, $1 the key. Their table starts empty, also on a restart
  # (Restart=, or that of the backend a pin is part of), under users' units that stay
  # active: their rules go back in here, or their apps would go out unmarked.
  viaReapply = pkgs.writeShellScript "proxy-suite-per-app" ''
    set -uo pipefail
    ${constants.systemctl} list-units --plain --no-legend --state=active \
      "proxy-suite-per-app-via-user@*-''${1:-}.service" \
      | while read -r unit _; do
        instance=''${unit#proxy-suite-per-app-via-user@}
        ${viaUserRule} "''${instance%.service}" \
          || echo "proxy-suite: the rule of $unit did not go back in" >&2
      done
  '';
  # The pin slots, of per-app TProxy and of per-app TUN.
  pinRouteNames = lib.optional perAppPinTproxy "tproxy" ++ lib.optional perAppPinTun "tun";
  pinDir = "${constants.runtimeDir}/proxy-suite-per-app-via";
  curl = "${pkgs.curl}/bin/curl";
  flock = "${pkgs.util-linux}/bin/flock";
  pinTun = lib.escapeShellArg perAppRoutingTun.interface;
  pinRoutes = {
    tproxy = {
      fwmarkBase = constants.perAppPinTproxyFwmarkBase;
      tableBase = constants.perAppPinTproxyTableBase;
      nftFiles = perAppPinTproxyRulesFiles;
      # Where the user rule units add their cgroup rules, as for the per-app TProxy's own.
      nftChain = "app_mark";
      clashApi = "http://127.0.0.1:${toString singBoxCfg.clashApiPort}";
      secretFile = "${constants.runtimeDir}/proxy-suite-socks/clash-secret";
      backend = "proxy-suite-socks.service";
      routingDown = builders.mkTproxyRoutingDown {
        inherit ip;
        fwmark = "$mark";
        table = "$table";
      };
      routingUp = ''
        ${pinRoutes.tproxy.routingDown}
        ${builders.mkTproxyRoutingUp {
          inherit ip;
          inherit (cfg.proxy) ipv6;
          fwmark = "$mark";
          table = "$table";
        }}
      '';
    };
    tun = {
      fwmarkBase = constants.perAppPinTunFwmarkBase;
      tableBase = constants.perAppPinTunTableBase;
      nftFiles = perAppPinTunChainFiles;
      nftChain = "app_mark";
      clashApi = "http://127.0.0.1:${toString constants.perAppTunClashApiPort}";
      secretFile = "${constants.runtimeDir}/proxy-suite-per-app-tun/clash-secret";
      backend = "proxy-suite-per-app-tun.service";
      # Into the TUN; the slot's nft table SNATs the packets to the source the backend tells
      # the slot by.
      routingUp = ''
        ${ip} -4 route replace default dev ${pinTun} table "$table"
        ${
          if cfg.proxy.ipv6 then
            ''
              ${ip} -6 route replace default dev ${pinTun} table "$table"
            ''
          else
            ''
              # No IPv6 in the TUN: unreachable, so the app falls back to IPv4.
              ${ip} -6 route replace unreachable default table "$table"
            ''
        }
        for family in -4 -6; do
          while ${ip} "$family" rule del pref ${toString constants.perAppPinRulePriority} fwmark "$mark" 2>/dev/null; do :; done
          ${ip} "$family" rule add pref ${toString constants.perAppPinRulePriority} fwmark "$mark" table "$table"
        done
      '';
      routingDown = ''
        for family in -4 -6; do
          while ${ip} "$family" rule del pref ${toString constants.perAppPinRulePriority} fwmark "$mark" 2>/dev/null; do :; done
          ${ip} "$family" route flush table "$table" 2>/dev/null || true
        done
      '';
    };
  };

  # $1, a tag in hex, to $hex and $tag.
  decodeTag = ''
    hex=''${1:-}
    if [[ ! $hex =~ ^([0-9a-f][0-9a-f]){1,64}$ ]]; then
      echo "proxy-suite: '$hex' is not an outbound tag in hex" >&2
      exit 1
    fi
    tag=$(printf '%b' "$(printf '%s' "$hex" | ${pkgs.gnused}/bin/sed 's/../\\x&/g')")
    if [[ ! $tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      echo "proxy-suite: '$tag' is not an outbound tag" >&2
      exit 1
    fi
  '';

  # $slot: the one of the route's slots that $tag holds; with `claim`, a free one when none
  # does. Then its $mark, $table and $nft_table. A slot is the file <route>-<n> in pinDir,
  # holding the tag.
  pinSlot =
    route: claim:
    let
      r = pinRoutes.${route};
      file = ''"${pinDir}/${route}-$n"'';
    in
    ''
      ${pkgs.coreutils}/bin/mkdir -p ${pinDir}
      exec 9>>"${pinDir}/lock"
      ${flock} 9
      slot=""
      for (( n = 0; n < ${toString perAppPinSlots}; n++ )); do
        if [[ -f ${file} && $(< ${file}) == "$tag" ]]; then
          slot=$n
          break
        fi
      done
      ${lib.optionalString claim ''
        for (( n = 0; n < ${toString perAppPinSlots}; n++ )); do
          [[ -z $slot ]] || break
          if [[ ! -e ${file} ]]; then
            printf '%s\n' "$tag" > ${file}
            slot=$n
          fi
        done
      ''}
      ${flock} -u 9
      if [[ -n $slot ]]; then
        mark=$(( ${toString r.fwmarkBase} + slot ))
        table=$(( ${toString r.tableBase} + slot ))
        nft_table="proxy_suite_per_app_via_${route}_$slot"
      fi
    '';

  # select_pin <tag> <attempts>: switches the slot's selector, while the backend comes up.
  mkSelect =
    route:
    let
      r = pinRoutes.${route};
    in
    ''
      select_pin() {
        local code attempt secret
        for attempt in $(${pkgs.coreutils}/bin/seq 1 "$2"); do
          secret=$(${pkgs.coreutils}/bin/tr -d '\r\n' 2>/dev/null < ${r.secretFile} || true)
          code=$(${curl} -s -o /dev/null -w '%{http_code}' --noproxy '*' -m 3 \
            -X PUT "${r.clashApi}/proxies/proxy-suite-pin-${route}-$slot" \
            -H "Content-Type: application/json" \
            -H @<(printf 'Authorization: Bearer %s\n' "$secret") \
            -d "$(${jq} -cn --arg n "$1" '{name: $n}')" || true)
          case "$code" in
            2??) return 0 ;;
            400)
              echo "proxy-suite: the backend has no outbound '$1' to run apps through" >&2
              return 2
              ;;
            404)
              echo "proxy-suite: the backend has no ${route} pin slot $slot; restart ${r.backend}" >&2
              return 2
              ;;
          esac
          ${pkgs.coreutils}/bin/sleep 0.5
        done
        echo "proxy-suite: the backend's Clash API at ${r.clashApi} did not answer" >&2
        return 1
      }
    '';

  mkPinUp =
    route:
    let
      r = pinRoutes.${route};
    in
    pkgs.writeShellScript "proxy-suite-per-app" ''
      set -euo pipefail
      ${decodeTag}
      ${pinSlot route true}
      if [[ -z $slot ]]; then
        # Every slot taken: one that nothing has run through for a minute (no user's marking
        # unit for it), as a perApp member could leave behind by starting the unit alone, is
        # taken back. The minute spares one proxy-ctl has just started for its app.
        for (( n = 0; n < ${toString perAppPinSlots}; n++ )); do
          slot_file="${pinDir}/${route}-$n"
          [[ -f $slot_file ]] || continue
          other=$(< "$slot_file")
          [[ $other =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
          (( $(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$slot_file") >= 60 )) || continue
          other_hex=$(printf '%s' "$other" | ${pkgs.coreutils}/bin/od -An -tx1 | ${pkgs.coreutils}/bin/tr -d ' \n')
          ${keptCase ''"${route}-$other_hex"'' "continue"}
          if [[ -z $(${constants.systemctl} list-units --plain --no-legend --state=active,activating,reloading \
            "proxy-suite-per-app-via-user@*-${route}-$other_hex.service") ]]; then
            echo "proxy-suite: taking back ${route} pin slot $n from '$other': nothing runs through it" >&2
            ${constants.systemctl} stop "proxy-suite-per-app-via-${route}@$other_hex.service" || true
            break
          fi
        done
        ${pinSlot route true}
      fi
      if [[ -z $slot ]]; then
        echo "proxy-suite: all ${toString perAppPinSlots} ${route} pin slots are taken (perAppRouting.via.pinSlots)" >&2
        exit 1
      fi
      ${mkSelect route}
      release() {
        set +e
        ${nft} delete table inet "$nft_table" 2>/dev/null
        ${r.routingDown}
        ${pkgs.coreutils}/bin/rm -f "${pinDir}/${route}-$slot"
      }
      trap release ERR
      files=(${lib.concatMapStringsSep " " toString r.nftFiles})
      ${nft} delete table inet "$nft_table" 2>/dev/null || true
      # The route first, then the marking: a packet marked before its route is in would
      # leave by the main table, and the kill switch lets the mark through.
      ${r.routingUp}
      ${nft} -f "''${files[$slot]}"
      # A backend that restarts restarts this too (PartOf), which switches it again.
      select_pin "$tag" 60
    '';

  mkPinDown =
    route:
    let
      r = pinRoutes.${route};
    in
    pkgs.writeShellScript "proxy-suite-per-app" ''
      set -uo pipefail
      ${decodeTag}
      ${pinSlot route false}
      [[ -n $slot ]] || exit 0
      ${mkSelect route}
      # Blocked until another outbound claims the slot; a backend that is down blocks anyway.
      select_pin block 1 2>/dev/null
      ${nft} delete table inet "$nft_table" 2>/dev/null || true
      ${r.routingDown}
      ${pkgs.coreutils}/bin/rm -f "${pinDir}/${route}-$slot"
    '';

  pinUp = lib.genAttrs pinRouteNames mkPinUp;
  pinDown = lib.genAttrs pinRouteNames mkPinDown;
in
{
  inherit
    perAppViaFile
    viaUp
    viaDns
    viaDown
    viaUserRule
    viaUserStart
    viaUserStop
    viaRetire
    viaReapply
    pinRoutes
    pinUp
    pinDown
    ;
}
