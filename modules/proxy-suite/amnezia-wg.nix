# Native AmneziaWG client profile services.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  awgCfg = cfg.amneziaWg;
  profiles = awgCfg.profiles;
  profileNames = builtins.attrNames profiles;
  globalProfileNames = builtins.attrNames derived.awgGlobalProfiles;
  inherit (derived.constants)
    awgGlobalFwmark
    awgGlobalGroup
    awgOutboundRulePriority
    awgServerUdpRulePriority
    runtimeAwgDir
    runtimeOutboundsDir
    awgRuntimeIfacePrefix
    awgRuntimeIfaceSlots
    awgRuntimeIfaceTableBase
    awgRuntimeTunnelBasePort
    awgRuntimeTunnelSlots
    systemctl
    runtimeDir
    ;
  killSwitchUnit = "proxy-suite-killswitch.service";
  # Profiles behind a loopback SOCKS hop, in a tunnel unit rather than awg-quick.
  tunnelOutbounds = derived.awgTunnelOutbounds;
  interfaceProfiles = lib.filterAttrs (
    _: profile:
    !builtins.elem profile.asOutbound [
      "singBox"
      "userspace"
    ]
  ) profiles;
  serviceName = name: "proxy-suite-awg-${name}";
  globalServiceNames = map serviceName globalProfileNames;
  allProfileConflicts =
    name:
    map (other: "${serviceName other}.service") (
      builtins.filter (other: other != name) globalProfileNames
    );
  inherit
    (import ./wg-tunnel.nix {
      inherit
        lib
        pkgs
        cfg
        derived
        ;
    })
    mkTunnel
    ;
  sourceCount =
    profile:
    builtins.length (
      builtins.filter (value: value != null) [
        profile.configFile
        profile.vpnFile
        profile.vpn
        profile.settings
      ]
    );
  source =
    profile:
    if profile.configFile != null then
      {
        kind = "configFile";
        path = profile.configFile;
      }
    else if profile.vpnFile != null then
      {
        kind = "vpnFile";
        path = profile.vpnFile;
      }
    else if profile.vpn != null then
      {
        kind = "vpn";
        path = pkgs.writeText "proxy-suite-awg" profile.vpn;
      }
    else
      {
        kind = "settings";
        inherit (profile) settings;
      };
  manifestFor =
    profile:
    pkgs.writeText "proxy-suite-awg" (
      builtins.toJSON (
        {
          allowConfigHooks = profile.allowConfigHooks;
          vpnContainer = profile.vpnContainer;
        }
        // lib.optionalAttrs (profile.endpoint != null) { inherit (profile) endpoint; }
        // source profile
      )
    );
  configTool = "${import ./lib/scripts-dir.nix { inherit lib; }}/amneziawg_config.py";
  awgCommon = import ./awg-common.nix { inherit lib pkgs awgCfg; };

  # What a unit's scripts know of the profile they run. `init` is their first line and sets
  # $profile_name; `runDir` is the runtime directory, as shell text; `source` the arguments
  # amneziawg_config.py reads the profile with; `outbound` whether it is an "interface" one.
  # `iface` is its interface and `table` an outbound's route table, as text for inside double
  # quotes: a name the type allows only safe characters in, or a variable `init` sets.
  staticSpec = name: profile: {
    inherit name profile;
    iface = profile.interfaceName;
    table = if profile.asOutbound == "interface" then toString (outboundRouteTable name) else "";
    template = false;
    unit = serviceName name;
    init = "profile_name=${lib.escapeShellArg name}";
    runDir = "/run/${serviceName name}";
    runtimeDirectory = serviceName name;
    source = "--manifest ${lib.escapeShellArg (toString (manifestFor profile))}";
    outbound = profile.asOutbound == "interface";
  };

  # Global profiles added with `proxy-ctl awg add`: instances of one template, the name
  # passed in as $1 (%i), the .conf in runtimeAwgDir. They share an interface, and hooks are
  # refused (--config), since whoever added one need not be root.
  runtimeProfile = {
    inherit (awgCfg.runtime) interfaceName;
    asOutbound = null;
    autostart = false;
    settings = null;
  };
  runtimeSpec = {
    name = "$profile_name";
    profile = runtimeProfile;
    iface = runtimeProfile.interfaceName;
    table = "";
    template = true;
    unit = "proxy-suite-awg@";
    init = ''
      profile_name=''${1:-}
      if [[ ! $profile_name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; then
        echo "proxy-suite: '$profile_name' is not an AmneziaWG profile name" >&2
        exit 1
      fi
    '';
    runDir = "/run/proxy-suite-awg-rt-$profile_name";
    runtimeDirectory = "proxy-suite-awg-rt-%i";
    source = ''--config "${runtimeAwgDir}/$profile_name.conf"'';
    outbound = false;
  };
  # Outbounds added with `proxy outbounds add --interface`: <tag>.awg in the runtime outbound
  # spool, and in <tag>.iface the slot proxy-ctl gave it, which names its interface and table.
  # Instances of one template, as the global ones; hooks refused (--config), the spool being
  # group-writable.
  runtimeIfaceSpec = {
    name = "$profile_name";
    profile = {
      asOutbound = "interface";
      autostart = false;
      settings = null;
    };
    iface = "$interface";
    table = "$table";
    template = true;
    unit = "proxy-suite-awg-if@";
    init = ''
      profile_name=''${1:-}
      if [[ ! $profile_name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "proxy-suite: '$profile_name' is not an outbound tag" >&2
        exit 1
      fi
      # The slot the unit started with: by its stop, the spool's entry may be gone.
      slot_file="/run/proxy-suite-awg-if-$profile_name/slot"
      if [[ -s $slot_file ]]; then
        slot=$(${pkgs.coreutils}/bin/head -n 1 "$slot_file")
      else
        # O_NOFOLLOW: the spool is group-writable.
        slot=$(${pkgs.coreutils}/bin/dd if="${runtimeOutboundsDir}/$profile_name.iface" iflag=nofollow,nonblock status=none 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1 || true)
      fi
      # No leading zero (bash reads it as octal) and three digits at most (a long one wraps
      # around in bash arithmetic): an out-of-range table reaches `ip route flush` as root.
      if [[ ! $slot =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( slot >= ${toString awgRuntimeIfaceSlots} )); then
        echo "proxy-suite: AmneziaWG outbound '$profile_name' needs a slot in 0-${
          toString (awgRuntimeIfaceSlots - 1)
        } in $profile_name.iface" >&2
        exit 1
      fi
      interface="${awgRuntimeIfacePrefix}$slot"
      table=$(( ${toString awgRuntimeIfaceTableBase} + slot ))
      if [[ -d /run/proxy-suite-awg-if-$profile_name && ! -s $slot_file ]]; then
        echo "$slot" > "$slot_file"
      fi
    '';
    runDir = "/run/proxy-suite-awg-if-$profile_name";
    runtimeDirectory = "proxy-suite-awg-if-%i";
    source = ''--config "${runtimeOutboundsDir}/$profile_name.awg"'';
    outbound = true;
  };
  # A global profile, declared or added with `awg add`, for `apps run --via <name>`: a copy
  # brought up as an outbound interface has it (no routes, no DNS), on an interface and table
  # of a free slot, while apps run through it. One unit with the profile up globally: each
  # stops the other (Conflicts=), since both would hold the same key with the same peer.
  appManifests = pkgs.writeText "proxy-suite-awg" (
    builtins.toJSON (
      lib.mapAttrs (_: profile: toString (manifestFor profile)) derived.awgGlobalProfiles
    )
  );
  appSlotDir = "${derived.constants.runtimeDir}/proxy-suite-awg-app";
  appSlotFile = ''"${appSlotDir}/slot-$slot"'';
  appSpec = {
    name = "$profile_name";
    profile = {
      asOutbound = "interface";
      autostart = false;
      settings = null;
    };
    iface = "$interface";
    table = "$table";
    template = true;
    unit = "proxy-suite-awg-app@";
    description = "proxy-suite AmneziaWG profile %i for the apps run through it";
    init = ''
      profile_name=''${1:-}
      if [[ ! $profile_name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; then
        echo "proxy-suite: '$profile_name' is not an AmneziaWG profile name" >&2
        exit 1
      fi
      manifest=$(${pkgs.jq}/bin/jq -r --arg n "$profile_name" '.[$n] // empty' ${appManifests})
      if [[ -n $manifest ]]; then
        source_args=(--manifest "$manifest")
      ${lib.optionalString derived.awgRuntimeGlobal ''
        # Added with `awg add`: hooks refused (--config), the directory being group-writable.
        elif [[ -f ${runtimeAwgDir}/$profile_name.conf ]]; then
          source_args=(--config "${runtimeAwgDir}/$profile_name.conf")
      ''}
      else
        echo "proxy-suite: no global AmneziaWG profile '$profile_name'" >&2
        exit 1
      fi
      # The slot the unit holds, else a free one: the file slot-<n> naming the profile.
      slot_file="/run/proxy-suite-awg-app-$profile_name/slot"
      slot=""
      if [[ -s $slot_file ]]; then
        slot=$(${pkgs.coreutils}/bin/head -n 1 "$slot_file")
      elif [[ -d /run/proxy-suite-awg-app-$profile_name ]]; then
        ${pkgs.coreutils}/bin/mkdir -p ${appSlotDir}
        exec 9>>"${appSlotDir}/lock"
        ${pkgs.util-linux}/bin/flock 9
        for (( n = 0; n < ${toString derived.constants.awgAppSlots}; n++ )); do
          if [[ ! -e ${appSlotDir}/slot-$n || $(< ${appSlotDir}/slot-$n) == "$profile_name" ]]; then
            printf '%s\n' "$profile_name" > ${appSlotDir}/slot-$n
            slot=$n
            break
          fi
        done
        ${pkgs.util-linux}/bin/flock -u 9
        exec 9>&-
        if [[ -z $slot ]]; then
          echo "proxy-suite: all ${toString derived.constants.awgAppSlots} slots for AmneziaWG profiles apps run through are taken" >&2
          exit 1
        fi
        echo "$slot" > "$slot_file"
      fi
      if [[ ! $slot =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( slot >= ${toString derived.constants.awgAppSlots} )); then
        echo "proxy-suite: AmneziaWG profile '$profile_name' is not up for apps" >&2
        exit 1
      fi
      interface="${derived.constants.awgAppIfacePrefix}$slot"
      table=$(( ${toString derived.constants.awgAppTableBase} + slot ))
    '';
    runDir = "/run/proxy-suite-awg-app-$profile_name";
    runtimeDirectory = "proxy-suite-awg-app-%i";
    source = ''"''${source_args[@]}"'';
    outbound = true;
    release = ''
      if [[ -f ${appSlotFile} && $(< ${appSlotFile}) == "$profile_name" ]]; then
        ${pkgs.coreutils}/bin/rm -f ${appSlotFile}
      fi
    '';
  };
  specConfig = spec: "${spec.runDir}/${spec.iface}.conf";

  # Runtime profiles cannot be named in Conflicts= at build time, and share one interface:
  # starting any global profile stops the runtime ones still up. $1: its own instance, if one.
  stopRuntimeProfiles = pkgs.writeShellScript "proxy-suite-awg" ''
    set -uo pipefail
    self="proxy-suite-awg@''${1:-}.service"
    # A failed unit's line starts with a glyph: take the name wherever it is.
    ${systemctl} list-units --plain --no-legend --state=active,activating,reloading 'proxy-suite-awg@*.service' \
      | ${pkgs.gnugrep}/bin/grep -o 'proxy-suite-awg@[^ ]*\.service' \
      | while read -r unit; do
        [[ $unit == "$self" ]] || ${systemctl} stop "$unit" || true
      done
    # grep finds nothing when none is up, which pipefail would make this script's failure.
    exit 0
  '';
  # Keep proxy backend sockets (proxyMark) out of AWG's default-route table.
  proxyBypassRulePriority = 8998;
  bypassRule =
    family: action:
    "${pkgs.iproute2}/bin/ip ${family} rule ${action} pref ${toString proxyBypassRulePriority} fwmark ${toString cfg.proxy.tproxy.proxyMark} lookup main";
  clearBypassRules =
    lib.concatMapStrings
      (family: ''
        while ${bypassRule family "del"} 2>/dev/null; do :; done
      '')
      [
        "-4"
        "-6"
      ];

  # Some lines drop a share of fresh flows for good, handshakes included. A new source port
  # is a new flow, and moving the interface to one keeps its routes, so traffic never leaks
  # past the tunnel while it tries again. A pinned ListenPort is left alone.
  mkHandshakeHelpers = spec: ''
    awg=${awgCfg.toolsPackage}/bin/awg
    interface="${spec.iface}"

    # Seconds since the newest handshake of any peer; a large number before the first.
    handshake_age() {
      local latest
      latest=$("$awg" show "$interface" latest-handshakes 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '$2 > max { max = $2 } END { print max + 0 }')
      if (( latest == 0 )); then echo 1000000; else echo $(( $(${pkgs.coreutils}/bin/date +%s) - latest )); fi
    }

    new_source_port() {
      ${
        if spec.profile.settings != null && spec.profile.settings.listenPort != null then
          ":"
        else
          ''"$awg" set "$interface" listen-port 0 || true''
      }
    }
  '';

  # An outbound interface runs with Table=off. A socket bound to it reaches IPv4 without a
  # route (the kernel takes the destination as on-link), but IPv6 is unreachable, so the
  # interface gets a table of its own, which only sockets bound to it look up.
  outboundRuleCleanup = spec: ''
    for family in -4 -6; do
      while ${pkgs.iproute2}/bin/ip "$family" rule del pref ${toString awgOutboundRulePriority} oif "${spec.iface}" 2>/dev/null; do :; done
      ${pkgs.iproute2}/bin/ip "$family" route flush table "${spec.table}" 2>/dev/null || true
    done
  '';
  outboundRoutesUp = spec: ''
    ${outboundRuleCleanup spec}
    for family in -4 -6; do
      if [[ -n $(${pkgs.iproute2}/bin/ip "$family" -o addr show dev "${spec.iface}" scope global) ]]; then
        ${pkgs.iproute2}/bin/ip "$family" route replace default dev "${spec.iface}" table "${spec.table}"
        ${pkgs.iproute2}/bin/ip "$family" rule add pref ${toString awgOutboundRulePriority} oif "${spec.iface}" table "${spec.table}"
      fi
    done
  '';
  outboundRouteTable =
    name: (lib.findFirst (ob: ob.name == name) null derived.awgInterfaceOutbounds).routeTable;

  # A global profile sends everything without its fwmark into the tunnel, replies to
  # connections made to this host from elsewhere (SSH, a web server, inbound listeners)
  # included, which then never reach the client. Those connections get the fwmark, so
  # their packets take the main table and leave the way they came. Before the
  # reverse-path filter, which then finds the route back as well.
  #
  # A UDP socket bound to every address is routed before any packet exists to mark, so the
  # tunnel's address would become its source. The ports the host serves UDP on are sent to
  # the main table by rule instead, which the kernel checks before it picks the source.
  repliesTable = profile: "proxy-suite-awg-${profile.interfaceName}";
  serverUdpPorts = lib.unique (
    map toString (
      awgCfg.serverUdpPorts ++ derived.proxyInboundFirewallUdpPorts ++ derived.proxyInboundRuntimePorts
    )
    ++ cfg.host.openUdpPorts
  );
  serverUdpRulesDown = ''
    for family in -4 -6; do
      while ${pkgs.iproute2}/bin/ip "$family" rule del pref ${toString awgServerUdpRulePriority} 2>/dev/null; do :; done
    done
  '';
  serverUdpRulesUp = ''
    ${serverUdpRulesDown}
    for family in -4 -6; do
      for port in ${lib.escapeShellArgs serverUdpPorts}; do
        # IPv6 may be off.
        ${pkgs.iproute2}/bin/ip "$family" rule add pref ${toString awgServerUdpRulePriority} ipproto udp sport "$port" lookup main \
          || [[ $family == -6 ]]
      done
    done
  '';
  repliesUp = profile: ''
    fwmark=$(${awgCfg.toolsPackage}/bin/awg show ${lib.escapeShellArg profile.interfaceName} fwmark)
    # Off when the profile routes nothing by default (a table of its own, or Table=off).
    if [[ "$fwmark" != off ]]; then
      ${awgIPv6FallbackUp}
      ${serverUdpRulesUp}
      ${pkgs.nftables}/bin/nft -f - <<EOF
    table inet ${repliesTable profile} {
        chain prerouting {
            type filter hook prerouting priority mangle - 5; policy accept;
            ct state new iifname != { "lo", "${profile.interfaceName}" } fib daddr type local ct mark set $fwmark
            ct mark $fwmark meta mark set $fwmark
        }
        chain output {
            type route hook output priority mangle - 5; policy accept;
            ct mark $fwmark meta mark set $fwmark
        }
    }
    EOF
    fi
  '';
  repliesDown = profile: ''
    ${pkgs.nftables}/bin/nft delete table inet ${repliesTable profile} 2>/dev/null || true
    ${serverUdpRulesDown}
    ${awgIPv6FallbackDown}
  '';

  # A global profile without IPv6 (AllowedIPs 0.0.0.0/0 alone): IPv6 unreachable rather than
  # out the uplink, behind the main table's more specific routes. $fwmark: the interface's.
  ip6 = "${pkgs.iproute2}/bin/ip -6";
  awgIPv6FallbackUp = ''
    table=$((fwmark))
    if [ -e /proc/net/if_inet6 ] && [ -z "$(${ip6} route show default table "$table" 2>/dev/null)" ]; then
      ${ip6} route replace unreachable default table "$table"
      ${ip6} rule add not fwmark "$table" table "$table"
      ${ip6} rule add table main suppress_prefixlength 0
    fi
  '';
  # The interface (and its fwmark) may be gone: found by the rule naming its mark as its
  # table and that table's unreachable default, which awg-quick's never has.
  awgIPv6FallbackDown = ''
    while read -r mark table; do
      [[ $mark =~ ^(0x[0-9a-f]+|[0-9]+)$ && $table =~ ^[0-9]+$ ]] && (( mark == table )) || continue
      ${ip6} route show table "$table" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q '^unreachable default' || continue
      while ${ip6} rule del not fwmark "$table" table "$table" 2>/dev/null; do :; done
      ${ip6} rule del table main suppress_prefixlength 0 2>/dev/null || true
      ${ip6} route flush table "$table" 2>/dev/null || true
    done < <(${ip6} rule show 2>/dev/null | ${pkgs.gawk}/bin/awk '$2 == "not" && $5 == "fwmark" && $7 == "lookup" { print $6, $8 }')
  '';

  # awg-quick turns src_valid_mark on for a default route and never back off; left on, it
  # changes how the kernel checks every marked packet's source. Put back as it was.
  srcValidMark = "/proc/sys/net/ipv4/conf/all/src_valid_mark";
  # Unquoted: a runtime profile's name is checked against [A-Za-z0-9_-] first (runtimeSpec).
  savedSrcValidMark = spec: "${spec.runDir}/src_valid_mark";
  saveSrcValidMark = spec: ''
    [[ -e ${savedSrcValidMark spec} ]] || cat ${srcValidMark} > ${savedSrcValidMark spec}
  '';
  restoreSrcValidMark = spec: ''
    if [[ -s ${savedSrcValidMark spec} ]]; then
      cat ${savedSrcValidMark spec} > ${srcValidMark} || true
      rm -f ${savedSrcValidMark spec}
    fi
  '';

  # `ping` for the handshake probe. An outbound interface has no route to the probe address, so
  # the probe is bound to it.
  pingVia =
    spec:
    "${pkgs.iputils}/bin/ping -n -c 1"
    + lib.optionalString (spec.profile.asOutbound == "interface") " -I \"${spec.iface}\"";

  # An outbound interface keeps the host's routes and resolver, and marks its packets so TUN and
  # TProxy let them past; its DNS servers go to runDir/dns. A global one under the kill switch
  # marks them with a mark it knows.
  prepareCommand = spec: output: ''
    ${pkgs.python3}/bin/python3 ${configTool} \
      ${spec.source} \
      --output ${output}${
        if spec.profile.asOutbound == "interface" then
          # The DNS line goes, but per-app routing sends a wrapped app's lookups to it.
          " --outbound-fwmark ${toString cfg.proxy.tproxy.proxyMark} --dns-out \"${spec.runDir}/dns\""
        else
          lib.optionalString (
            derived.killSwitchEnabled && spec.profile.asOutbound == null
          ) " --fwmark ${toString awgGlobalFwmark} --resolve-endpoints"
      }
  '';

  # The Endpoint lookup under the kill switch, under the unit's group: awg-quick gets it as
  # an address.
  ownLookups = derived.constants.ownLookups pkgs;

  # A global profile, or an "interface" outbound: a unit for a declared profile (staticSpec),
  # or the template the runtime ones start from (runtimeSpec). `conflicts`: the global units
  # it stops by starting.
  mkService =
    spec: conflicts:
    let
      inherit (spec) name profile outbound;
      configPath = specConfig spec;
      # Every script: a template's instance name comes in as $1.
      withInit = body: ''
        ${spec.init}
        ${body}
      '';
      prepare = pkgs.writeShellScript "proxy-suite-awg" (withInit ''
        set -euo pipefail
        ${
          lib.optionalString (
            derived.killSwitchEnabled && !outbound
          ) "${pkgs.util-linux}/bin/unshare --mount ${ownLookups} "
        }${prepareCommand spec ''"${configPath}"''}
      '');
      proxyBypassUp = pkgs.writeShellScript "proxy-suite-awg" ''
        set -euo pipefail
        ${clearBypassRules}
        # IPv4 is required, or the proxy backend is captured by AWG; IPv6 is best-effort.
        if ! ${bypassRule "-4" "add"} 2>/dev/null; then
          echo "proxy-suite: unable to install the AWG proxy-backend bypass rule" >&2
          exit 1
        fi
        ${bypassRule "-6" "add"} 2>/dev/null || true
      '';
      proxyBypassDown = pkgs.writeShellScript "proxy-suite-awg" ''
        set +e
        ${clearBypassRules}
      '';
      start = pkgs.writeShellScript "proxy-suite-awg" (withInit ''
        set -Eeuo pipefail

        cleanup() {
          set +e
          ${awgCfg.toolsPackage}/bin/awg-quick down "${configPath}"

          # Without the control socket awg-quick cannot find its fwmark; clean up this
          # interface only.
          for family in -4 -6; do
            had_table=0
            for table in $(${pkgs.iproute2}/bin/ip "$family" route show table all 2>/dev/null \
              | ${pkgs.gawk}/bin/awk -v iface="${spec.iface}" '$1 == "default" && $2 == "dev" && $3 == iface { for (i = 1; i <= NF; i++) if ($i == "table") print $(i + 1) }'); do
              had_table=1
              while ${pkgs.iproute2}/bin/ip "$family" rule delete table "$table" 2>/dev/null; do :; done
              ${pkgs.iproute2}/bin/ip "$family" route flush table "$table" 2>/dev/null || true
            done
            if (( had_table )); then
              ${pkgs.iproute2}/bin/ip "$family" rule delete table main suppress_prefixlength 0 2>/dev/null || true
            fi
          done
          if command -v nft >/dev/null; then
            nft list tables 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -F " wg-quick-${spec.iface}" \
              | while read -r _ family table; do nft delete table "$family" "$table" 2>/dev/null || true; done
          fi
          ${cfg.host.resolvconfPackage}/bin/resolvconf -d "${spec.iface}" -f 2>/dev/null || true
          ${pkgs.iproute2}/bin/ip link delete dev "${spec.iface}" 2>/dev/null || true
          ${if outbound then outboundRuleCleanup spec else repliesDown profile + restoreSrcValidMark spec}
          ${spec.release or ""}
        }
        trap cleanup ERR
        # Stopped (or conflicted out) during the handshake wait: no ExecStop follows a start
        # that never finished, so what is up so far would stay up with the unit inactive.
        trap 'cleanup; exit 143' TERM INT

        ${awgCommon.modprobe}

        read -r implementation probe _ < <(${pkgs.python3}/bin/python3 ${configTool} \
          --inspect "${configPath}")
        ${lib.optionalString (!outbound) (saveSrcValidMark spec)}
        ${awgCommon.awgQuickUp "$implementation" ''"${configPath}"''}
        ${if outbound then outboundRoutesUp spec else repliesUp profile}

        ${mkHandshakeHelpers spec}
        # A handshake is retried every 5 seconds: each retry after the first gets a new port.
        for attempt in $(${pkgs.coreutils}/bin/seq 1 20); do
          ${pingVia spec} -W 1 "$probe" >/dev/null 2>&1 || true
          if (( $(handshake_age) < 1000000 )); then
            trap - ERR
            exit 0
          fi
          if (( attempt % 5 == 0 )); then
            new_source_port
          fi
        done

        echo "proxy-suite: AmneziaWG profile '$profile_name' did not complete a handshake; rolling back routes" >&2
        false
      '');
      stop = pkgs.writeShellScript "proxy-suite-awg" (withInit ''
        set -uo pipefail
        status=0
        ${awgCfg.toolsPackage}/bin/awg-quick down "${configPath}" || status=$?
        ${if outbound then outboundRuleCleanup spec else repliesDown profile + restoreSrcValidMark spec}
        ${spec.release or ""}
        exit "$status"
      '');
      # A template's scripts get the instance name.
      withArg = script: if spec.template then "${script} %i" else script;
    in
    (
      if outbound then
        {
          description =
            spec.description or (
              if spec.template then
                "proxy-suite AmneziaWG interface behind the %i outbound (added at runtime)"
              else
                "proxy-suite AmneziaWG interface behind the ${name} outbound"
            );
          # Nothing waits for it: a slow handshake must not hold up the proxy.
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          # The sync unit starts a template's instances.
          wantedBy = lib.optionals (!spec.template) [ "multi-user.target" ];
          startLimitIntervalSec = 0;
        }
      else
        {
          description =
            if spec.template then
              "proxy-suite AmneziaWG client profile %i (added at runtime)"
            else
              "proxy-suite AmneziaWG client profile ${name}";
          # Start the local proxy before AWG takes the default route, so HTTP_PROXY clients
          # do not race it.
          after = [
            "network-online.target"
            "proxy-suite-zapret.service"
          ]
          ++ lib.optional cfg.proxy.enable "proxy-suite-socks.service";
          wants = [
            "network-online.target"
          ]
          ++ lib.optional cfg.proxy.enable "proxy-suite-socks.service"
          ++ lib.optional derived.killSwitchEnabled killSwitchUnit;
          wantedBy = lib.optionals profile.autostart [ "multi-user.target" ];
          conflicts = conflicts ++ [
            "proxy-suite-tun.service"
            "proxy-suite-tproxy.service"
            "proxy-suite-zapret.service"
            "proxy-suite-zapret-vm-exempt.service"
          ];
        }
    )
    // {
      path = [
        awgCfg.toolsPackage
        awgCfg.userspacePackage
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.iproute2
        pkgs.iputils
        pkgs.kmod
        cfg.host.firewallPackage
        cfg.host.resolvconfPackage
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = spec.runtimeDirectory;
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        NoNewPrivileges = true;
        LockPersonality = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        # Another profile stopping clears the bypass rules on its way out: before they go in.
        ExecStartPre = [
          (withArg prepare)
        ]
        ++ lib.optionals (!outbound && derived.awgRuntimeGlobal) [ (withArg stopRuntimeProfiles) ]
        ++ lib.optionals (cfg.proxy.enable && !outbound) [ proxyBypassUp ]
        # Per-app zapret and this profile's copy for apps have nothing to add once it is up,
        # and never take it down themselves (constants.refuseUnderGlobal).
        ++ lib.optionals (!outbound) [
          (derived.constants.stopPerAppUnits pkgs [
            "proxy-suite-per-app-zapret.service"
            "proxy-suite-awg-app@${if spec.template then "%i" else name}.service"
          ])
        ];
        ExecStart = withArg start;
        ExecStop = withArg stop;
      }
      // (
        let
          # Per-app zapret back once it is down, if kept running.
          stopPost =
            derived.constants.withPerAppStandby "${spec.unit}${lib.optionalString spec.template "*"}.service"
              (if cfg.proxy.enable then proxyBypassDown else null);
        in
        lib.optionalAttrs (!outbound && stopPost != null) { ExecStopPost = stopPost; }
      )
      # The Endpoint lookup (ownLookups) gets past the kill switch by this group, so a
      # profile that dropped can come back while the kill switch holds.
      // lib.optionalAttrs (derived.killSwitchEnabled && !outbound) {
        Group = awgGlobalGroup;
      }
      # A failed handshake leaves no routes behind here, so try again later.
      // lib.optionalAttrs outbound {
        Restart = "on-failure";
        RestartSec = 30;
      };
    };

  mkTunnelService =
    ob:
    let
      profile = profiles.${ob.name};
    in
    mkTunnel {
      description = "proxy-suite AmneziaWG tunnel behind the ${ob.name} outbound";
      unit = serviceName ob.name;
      engine = ob.kind;
      inherit (ob)
        tag
        tunnelPort
        directPort
        domainStrategy
        ;
      profile = ''
        ${lib.optionalString (profile.configFile != null) ''
          # It may not exist yet: WARP's appears once proxy-suite-warp has registered.
          if [ ! -s ${lib.escapeShellArg profile.configFile} ]; then
            echo "proxy-suite: waiting for the AmneziaWG profile at ${profile.configFile}" >&2
            until [ -s ${lib.escapeShellArg profile.configFile} ]; do sleep 5; done
          fi
        ''}
        profile="$RUNTIME_DIRECTORY/profile.conf"
        ${prepareCommand (staticSpec ob.name profile) ''"$profile"''}
      '';
    };

  # Outbounds added with `proxy-ctl proxy outbounds add`: <tag>.awg in the runtime outbound
  # spool, and the loopback port proxy-ctl gave it in <tag>.port. They run in wireproxy,
  # which keeps the obfuscation; --config refuses hooks, as the spool is group-writable.
  runtimeTunnelLastPort = awgRuntimeTunnelBasePort + awgRuntimeTunnelSlots - 1;
  runtimeTunnelService = mkTunnel {
    description = "proxy-suite AmneziaWG tunnel behind the %i outbound (added at runtime)";
    unit = "proxy-suite-awg-tunnel@";
    runtimeDirectory = "proxy-suite-awg-tunnel-%i";
    engine = "userspace";
    # `profile` sets $TUNNEL_TAG.
    tunnelPort = "$TUNNEL_PORT";
    execArgs = " %i";
    # The sync unit starts one per entry.
    wantedBy = [ ];
    # A removed entry exits cleanly, and stays stopped.
    restart = "on-failure";
    profile = ''
      TUNNEL_TAG=''${1:-}
      if [[ ! $TUNNEL_TAG =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "proxy-suite: '$TUNNEL_TAG' is not an outbound tag" >&2
        exit 1
      fi
      profile="${runtimeOutboundsDir}/$TUNNEL_TAG.awg"
      if [[ ! -s $profile ]]; then
        echo "proxy-suite: no AmneziaWG outbound '$TUNNEL_TAG' in ${runtimeOutboundsDir}" >&2
        exit 0
      fi
      # O_NOFOLLOW: the spool is group-writable, and the port is echoed back on error.
      TUNNEL_PORT=$(${pkgs.coreutils}/bin/dd if="${runtimeOutboundsDir}/$TUNNEL_TAG.port" iflag=nofollow,nonblock status=none 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1 || true)
      if [[ ! $TUNNEL_PORT =~ ^[1-9][0-9]{0,4}$ ]] || (( TUNNEL_PORT < ${toString awgRuntimeTunnelBasePort} || TUNNEL_PORT > ${toString runtimeTunnelLastPort} )); then
        echo "proxy-suite: AmneziaWG outbound '$TUNNEL_TAG' needs a port in ${toString awgRuntimeTunnelBasePort}-${toString runtimeTunnelLastPort} in $TUNNEL_TAG.port" >&2
        exit 1
      fi
      export TUNNEL_TAG TUNNEL_PORT
    '';
  };

  # One tunnel per runtime AmneziaWG outbound, and none for an entry removed since: at boot,
  # and with every proxy-suite-outbound-reload, which proxy-ctl starts after a change.
  runtimeSyncService = {
    description = "proxy-suite AmneziaWG outbounds added at runtime";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [
      "multi-user.target"
      "proxy-suite-outbound-reload.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "proxy-suite-awg" ''
        set -uo pipefail
        # Each entry's unit: a wireproxy tunnel, or with <tag>.iface an interface of its own.
        declare -A keep=()
        for entry in "${runtimeOutboundsDir}"/*.awg; do
          [[ -e $entry ]] || continue
          tag=''${entry##*/}
          tag=''${tag%.awg}
          kind=tunnel
          ${lib.optionalString derived.awgRuntimeIfaceOutbounds "[[ -e ${runtimeOutboundsDir}/$tag.iface ]] && kind=if"}
          keep[$kind@$tag]=1
          ${systemctl} start --no-block "proxy-suite-awg-$kind@$tag.service" || true
        done
        ${systemctl} list-units --all --plain --no-legend 'proxy-suite-awg-tunnel@*.service' 'proxy-suite-awg-if@*.service' \
          | ${pkgs.gnugrep}/bin/grep -o 'proxy-suite-awg-\(tunnel\|if\)@[^ ]*\.service' \
          | while read -r unit; do
            instance=''${unit#proxy-suite-awg-}
            instance=''${instance%.service}
            [[ -n ''${keep[$instance]:-} ]] || ${systemctl} stop --no-block "$unit" || true
          done
        # grep finds nothing when no tunnel is loaded, which pipefail would make a failure.
        exit 0
      '';
    };
  };

  # Runs alongside a started profile. Its pings keep traffic flowing, and traffic makes
  # WireGuard rekey every RekeyAfterTime (120 seconds by default); a handshake older than that
  # on two checks in a row is a rekey that is not getting through, so the interface moves to
  # a new port.
  #
  # An outbound interface also fetches proxy.urlTest.url over IPv4 through the tunnel, since a
  # peer can keep rekeying while carrying no traffic. After three misses the peer is re-added
  # for a fresh session (a new port alone keeps the old one), at most once in five minutes.
  mkWatchdog =
    spec:
    let
      inherit (spec) profile;
      egressProbe = profile.asOutbound == "interface";
      unit = if spec.template then "${spec.unit}%i.service" else "${spec.unit}.service";
      watchdog = pkgs.writeShellScript "proxy-suite-awg" ''
        ${spec.init}
        set -uo pipefail
        read -r _ probe rekey < <(${pkgs.python3}/bin/python3 ${configTool} \
          --inspect "${specConfig spec}") || exit 1
        if (( rekey == 0 )); then
          echo "proxy-suite: AmneziaWG profile '$profile_name' never rekeys; nothing to watch" >&2
          exec ${pkgs.coreutils}/bin/sleep infinity
        fi
        ${mkHandshakeHelpers spec}
        # Tells proxy-suite-outbound-groups at once, so a failover group this outbound is in
        # moves off it now rather than at its next test.
        hint() {
          local health="${runtimeDir}/proxy-suite-outbound-groups/health"
          local hint="$health/$profile_name"
          [[ -d $health ]] || return 0
          # Never through a symlink the service user's group left: O_EXCL (noclobber), touch -h.
          if [[ -e $hint || -L $hint ]]; then
            ${pkgs.coreutils}/bin/touch -h "$hint" 2>/dev/null || true
          else
            (set -C; : > "$hint") 2>/dev/null || true
          fi
        }
        ${lib.optionalString egressProbe ''
          new_session() {
            local peers
            peers=$("$awg" showconf "$interface" | ${pkgs.gawk}/bin/awk '/^\[Peer\]/ { p = 1 } p') || return
            [[ -n $peers ]] || return
            new_source_port
            "$awg" show "$interface" peers | while read -r peer; do
              "$awg" set "$interface" peer "$peer" remove || true
            done
            "$awg" addconf "$interface" <(printf '%s\n' "$peers") || true
          }
          # Only an interface with IPv4 can be judged by it.
          probe_egress=0
          [[ -n $(${pkgs.iproute2}/bin/ip -4 -o addr show dev "$interface") ]] && probe_egress=1
          misses=0
          last_session=-300
        ''}
        stale=0
        while sleep 15; do
          ${pingVia spec} -W 2 "$probe" >/dev/null 2>&1 || true
          if (( $(handshake_age) <= rekey + 10 )); then
            stale=0
          elif (( ++stale >= 2 )); then
            echo "proxy-suite: AmneziaWG profile '$profile_name' is not rekeying; moving to a new source port" >&2
            hint
            new_source_port
            stale=0
            ${lib.optionalString egressProbe "continue"}
          fi
          ${lib.optionalString egressProbe ''
            if (( !probe_egress )) || ${pkgs.curl}/bin/curl -4 -s --noproxy "*" --interface "$interface" -m 5 -o /dev/null \
              ${lib.escapeShellArg cfg.proxy.urlTest.url}; then
              misses=0
            elif (( ++misses == 1 )); then
              hint
            elif (( misses >= 3 && SECONDS - last_session >= 300 )); then
              echo "proxy-suite: AmneziaWG profile '$profile_name' carries no IPv4 past its peer; starting a new session" >&2
              new_session
              misses=0
              last_session=$SECONDS
            fi
          ''}
        done
      '';
    in
    {
      description = "proxy-suite AmneziaWG client profile ${
        if spec.template then "%i" else spec.name
      } watchdog";
      bindsTo = [ unit ];
      after = [ unit ];
      # A template's instances are pulled in by the profile's own Wants=.
      wantedBy = lib.optional (!spec.template) unit;
      serviceConfig = {
        ExecStart = if spec.template then "${watchdog} %i" else watchdog;
        Restart = "on-failure";
        RestartSec = 5;
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "full";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

  profileAssertions = lib.concatMap (
    name:
    let
      profile = profiles.${name};
      settings = profile.settings;
      obfuscation = if settings == null then null else settings.obfuscation;
    in
    [
      {
        assertion = builtins.match "^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$" name != null;
        message = "proxy-suite: AmneziaWG profile '${name}' must be a safe 1-32 character identifier";
      }
      {
        assertion = sourceCount profile == 1;
        message = "proxy-suite: AmneziaWG profile '${name}' must set exactly one of configFile, vpnFile, vpn, or settings";
      }
      {
        assertion = profile.vpnContainer == null || profile.vpn != null || profile.vpnFile != null;
        message = "proxy-suite: AmneziaWG profile '${name}': vpnContainer requires vpn or vpnFile";
      }
      {
        assertion = profile.asOutbound == null || cfg.proxy.enable;
        message = "proxy-suite: AmneziaWG profile '${name}': asOutbound requires proxy.enable = true";
      }
      {
        assertion = profile.asOutbound == null || !profile.autostart;
        message = "proxy-suite: AmneziaWG profile '${name}': an outbound always runs; leave autostart off";
      }
      {
        assertion = profile.asOutbound != "interface" || settings == null || settings.table == null;
        message = "proxy-suite: AmneziaWG profile '${name}': an outbound interface has no routes; leave settings.table unset";
      }
      {
        assertion = settings == null || settings.addresses != [ ];
        message = "proxy-suite: AmneziaWG profile '${name}': declarative settings require at least one address";
      }
      {
        assertion = settings == null || settings.peers != [ ];
        message = "proxy-suite: AmneziaWG profile '${name}': declarative settings require at least one peer";
      }
      {
        assertion =
          settings == null || ((settings.privateKey != null) != (settings.privateKeyFile != null));
        message = "proxy-suite: AmneziaWG profile '${name}': set exactly one of settings.privateKey or settings.privateKeyFile";
      }
      {
        assertion =
          obfuscation == null
          || obfuscation.headerProtectionKey == null
          || obfuscation.headerProtectionKeyFile == null;
        message = "proxy-suite: AmneziaWG profile '${name}': set at most one header-protection key source";
      }
    ]
    ++ lib.optionals (settings != null) (
      lib.imap0 (index: peer: {
        assertion = peer.presharedKey == null || peer.presharedKeyFile == null;
        message = "proxy-suite: AmneziaWG profile '${name}' peer ${toString index}: set at most one preshared key source";
      }) settings.peers
    )
  ) profileNames;

  interfaceNames =
    map (name: profiles.${name}.interfaceName) profileNames
    ++ lib.optional derived.awgRuntimeGlobal awgCfg.runtime.interfaceName;
  autostartProfiles = builtins.filter (name: profiles.${name}.autostart) globalProfileNames;
  globalAutostartCount =
    builtins.length autostartProfiles + (if cfg.proxy.autostart != null then 1 else 0);
in
{
  services.proxy-suite.internal.packages = [
    awgCfg.toolsPackage
    awgCfg.userspacePackage
  ]
  ++ lib.optional (
    derived.awgRuntimeOutbounds || builtins.any (ob: ob.kind == "userspace") tunnelOutbounds
  ) awgCfg.wireproxyPackage;

  services.proxy-suite.internal.groups = lib.optional (
    derived.killSwitchEnabled && derived.awgGlobalAvailable
  ) awgGlobalGroup;

  services.proxy-suite.internal.kernelModulePackages =
    lib.optionals (awgCfg.kernelModulePackage != null)
      [
        awgCfg.kernelModulePackage
      ];

  # Replies to the proxy's sockets come in on an interface the host has no route through.
  services.proxy-suite.internal.firewall.extraReversePathFilterRules =
    lib.concatMapStrings (ob: ''
      iifname "${ob.interface}" accept
    '') derived.awgInterfaceOutbounds
    + lib.optionalString derived.awgRuntimeIfaceOutbounds ''
      iifname "${awgRuntimeIfacePrefix}*" accept
    ''
    + lib.optionalString derived.perAppViaProfiles ''
      iifname "${derived.constants.awgAppIfacePrefix}*" accept
    '';

  services.proxy-suite.internal.services = lib.mkMerge [
    (lib.mapAttrs' (
      name: profile:
      lib.nameValuePair (serviceName name) (
        lib.mkMerge [
          (mkService (staticSpec name profile) (allProfileConflicts name))
          {
            # Ordered (one way, by name) so the old profile's cleanup of table 51820 ends before the
            # new one starts; Conflicts= alone lets them overlap.
            after = lib.optionals (builtins.elem name globalProfileNames) (
              map (other: "${serviceName other}.service") (
                builtins.filter (other: other < name) globalProfileNames
              )
            );
          }
        ]
      )
    ) interfaceProfiles)
    (lib.mapAttrs' (
      name: profile:
      lib.nameValuePair "${serviceName name}-watchdog" (mkWatchdog (staticSpec name profile))
    ) interfaceProfiles)
    (lib.mkIf derived.awgRuntimeGlobal {
      "proxy-suite-awg@" = lib.mkMerge [
        (mkService runtimeSpec (map (other: "${serviceName other}.service") globalProfileNames))
        {
          wants = [ "proxy-suite-awg-watchdog@%i.service" ];
          # After the declared ones it conflicts with: their stop goes first (as above).
          after = map (other: "${serviceName other}.service") globalProfileNames;
        }
      ];
      "proxy-suite-awg-watchdog@" = mkWatchdog runtimeSpec;
    })
    (lib.mkIf derived.awgRuntimeOutbounds {
      "proxy-suite-awg-tunnel@" = runtimeTunnelService;
      proxy-suite-awg-runtime-sync = runtimeSyncService;
    })
    (lib.mkIf derived.perAppViaProfiles {
      "proxy-suite-awg-app@" = lib.mkMerge [
        (mkService appSpec [ ])
        {
          wants = [ "proxy-suite-awg-app-watchdog@%i.service" ];
          # Not while the profile is up globally, declared or added with `awg add`: that
          # carries the apps already, and takes this one down as it starts.
          serviceConfig.ExecStartPre = lib.mkBefore [
            (derived.constants.refuseUnderGlobal pkgs [
              "proxy-suite-awg-%i.service"
              "proxy-suite-awg@%i.service"
            ])
          ];
          # Up only while proxy-ctl runs apps through it, which starts it again.
          serviceConfig.Restart = lib.mkForce "no";
        }
      ];
      "proxy-suite-awg-app-watchdog@" = mkWatchdog appSpec;
    })
    (lib.mkIf derived.awgRuntimeIfaceOutbounds {
      "proxy-suite-awg-if@" = lib.mkMerge [
        (mkService runtimeIfaceSpec [ ])
        { wants = [ "proxy-suite-awg-if-watchdog@%i.service" ]; }
      ];
      "proxy-suite-awg-if-watchdog@" = mkWatchdog runtimeIfaceSpec;
    })
    (lib.listToAttrs (
      map (ob: lib.nameValuePair (serviceName ob.name) (mkTunnelService ob)) tunnelOutbounds
    ))
    (lib.mkIf cfg.proxy.tun.enable {
      proxy-suite-tun.conflicts = map (name: "${name}.service") globalServiceNames;
    })
    (lib.mkIf cfg.proxy.tproxy.enable {
      proxy-suite-tproxy.conflicts = map (name: "${name}.service") globalServiceNames;
    })
  ];

  assertions = profileAssertions ++ [
    {
      assertion = profiles != { } || derived.awgRuntimeGlobal || derived.awgRuntimeOutbounds;
      message = "proxy-suite: amneziaWg.enable needs a profile, or amneziaWg.runtime.enable for profiles added with proxy-ctl (global ones need a root host, outbounds proxy.enable)";
    }
    {
      assertion = builtins.length interfaceNames == builtins.length (lib.unique interfaceNames);
      message = "proxy-suite: AmneziaWG profile interface names must be unique";
    }
    {
      assertion = builtins.all (
        name:
        !lib.hasPrefix awgRuntimeIfacePrefix name && !lib.hasPrefix derived.constants.awgAppIfacePrefix name
      ) (map (name: profiles.${name}.interfaceName) profileNames);
      message = "proxy-suite: AmneziaWG interface names starting with ${awgRuntimeIfacePrefix} or ${derived.constants.awgAppIfacePrefix} are for the interfaces proxy-suite brings up at runtime";
    }
    {
      # Their tables, per-app marks and DNS ports stay below the runtime ones'.
      assertion = builtins.length derived.awgOutbounds <= 40;
      message = "proxy-suite: at most 40 AmneziaWG outbound profiles";
    }
    {
      assertion = builtins.length autostartProfiles <= 1;
      message = "proxy-suite: at most one AmneziaWG profile may autostart";
    }
    {
      assertion = globalAutostartCount <= 1;
      message = "proxy-suite: at most one AmneziaWG, TUN, or TProxy global mode may autostart";
    }
    {
      assertion =
        !cfg.proxy.tun.enable
        || builtins.all (interface: interface != cfg.proxy.tun.interface) interfaceNames;
      message = "proxy-suite: AmneziaWG interfaces must differ from proxy.tun.interface";
    }
    {
      assertion =
        !cfg.perAppRouting.tun.enable
        || builtins.all (interface: interface != cfg.perAppRouting.tun.interface) interfaceNames;
      message = "proxy-suite: AmneziaWG interfaces must differ from perAppRouting.tun.interface";
    }
  ];
}
