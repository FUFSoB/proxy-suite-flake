{
  lib,
  pkgs,
}:

let
  mkOptionalTopLevel =
    {
      description,
      after ? [ ],
      wantedBy ? [ ],
      wants ? [ ],
      requires ? [ ],
      conflicts ? [ ],
      preStart ? null,
    }:
    {
      inherit
        description
        after
        wantedBy
        wants
        requires
        conflicts
        ;
    }
    // lib.optionalAttrs (preStart != null) { inherit preStart; };
in
rec {
  mkNamedUnits =
    entries:
    lib.listToAttrs (
      map (entry: lib.nameValuePair entry.name entry.value) (
        builtins.filter (entry: entry.enable) entries
      )
    );

  mkRestartingService =
    {
      description,
      execStart,
      runtimeDirectory,
      stateDirectory ? null,
      after ? [ ],
      wantedBy ? [ ],
      wants ? [ ],
      requires ? [ ],
      conflicts ? [ ],
      execStartPre ? null,
      execStartPost ? null,
      execStopPost ? null,
      extraServiceConfig ? { },
      preStart ? null,
    }:
    (mkOptionalTopLevel {
      inherit
        description
        after
        wantedBy
        wants
        requires
        conflicts
        preStart
        ;
    })
    // {
      serviceConfig = {
        ExecStart = execStart;
        Restart = "on-failure";
        RestartSec = 5;
        # Backing off to two minutes: a unit that cannot come up would refetch what it lacks
        # every 5 s for good.
        RestartSteps = 5;
        RestartMaxDelaySec = 120;
        RuntimeDirectory = runtimeDirectory;
      }
      // lib.optionalAttrs (stateDirectory != null) { StateDirectory = stateDirectory; }
      // lib.optionalAttrs (execStartPre != null) { ExecStartPre = execStartPre; }
      // lib.optionalAttrs (execStartPost != null) { ExecStartPost = execStartPost; }
      // lib.optionalAttrs (execStopPost != null) { ExecStopPost = execStopPost; }
      // extraServiceConfig;
    };

  mkOneshotService =
    {
      description,
      execStart,
      execStop ? null,
      execStartPre ? null,
      execStartPost ? null,
      execStopPost ? null,
      runtimeDirectory ? null,
      stateDirectory ? null,
      after ? [ ],
      wantedBy ? [ ],
      wants ? [ ],
      requires ? [ ],
      conflicts ? [ ],
      extraServiceConfig ? { },
      preStart ? null,
    }:
    (mkOptionalTopLevel {
      inherit
        description
        after
        wantedBy
        wants
        requires
        conflicts
        preStart
        ;
    })
    // {
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = execStart;
      }
      // lib.optionalAttrs (execStop != null) { ExecStop = execStop; }
      // lib.optionalAttrs (execStartPre != null) { ExecStartPre = execStartPre; }
      // lib.optionalAttrs (execStartPost != null) { ExecStartPost = execStartPost; }
      // lib.optionalAttrs (execStopPost != null) { ExecStopPost = execStopPost; }
      // lib.optionalAttrs (runtimeDirectory != null) { RuntimeDirectory = runtimeDirectory; }
      // lib.optionalAttrs (stateDirectory != null) { StateDirectory = stateDirectory; }
      // extraServiceConfig;
    };

  mkUserRuleService =
    {
      description,
      backendService,
      execStart,
      execStop,
    }:
    # Requires=: holds the shared backend up (StopWhenUnneeded=) and restarts this with it,
    # its crash included. Restarted by a switch, not stopped and started: a stop drops the hold.
    lib.recursiveUpdate (mkOneshotService {
      inherit description execStart execStop;
      requires = [ "${backendService}.service" ];
      after = [ "${backendService}.service" ];
    }) { serviceConfig."X-StopIfChanged" = false; };

  mkAnchorService =
    sliceName: description:
    mkOneshotService {
      inherit description;
      execStart = "${pkgs.coreutils}/bin/true";
      execStop = "${pkgs.coreutils}/bin/true";
      extraServiceConfig.Slice = sliceName;
    };

  cidrNetworkFunction = ''
    cidr_network() {
      local cidr="$1"
      local addr="''${cidr%/*}"
      local prefix="''${cidr#*/}"
      local o1 o2 o3 o4 ip mask net

      IFS=. read -r o1 o2 o3 o4 <<<"$addr"
      ip=$(((o1 << 24) | (o2 << 16) | (o3 << 8) | o4))
      if [ "$prefix" -eq 0 ]; then
        mask=0
      else
        mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
      fi
      net=$((ip & mask))

      printf '%d.%d.%d.%d/%s' \
        $(((net >> 24) & 255)) \
        $(((net >> 16) & 255)) \
        $(((net >> 8) & 255)) \
        $((net & 255)) \
        "$prefix"
    }
  '';

  mkDefaultUplinkIPv4Source =
    {
      ip,
      awk,
      errorMessage,
    }:
    ''
      uplink_addr="$(${ip} -4 route get 1.1.1.1 2>/dev/null | ${awk} '
        /src/ {
          for (i = 1; i <= NF; i++) {
            if ($i == "src" && i + 1 <= NF) {
              print $(i + 1)
              exit
            }
          }
        }
      ')"
      if [ -z "$uplink_addr" ]; then
        echo ${lib.escapeShellArg errorMessage} >&2
        exit 1
      fi
    '';

  mkNftDeleteTable =
    {
      nft,
      family,
      table,
    }:
    ''
      ${nft} delete table ${family} ${table} 2>/dev/null || true
    '';

  # A table's rules file swapped in whole, in one transaction: for a reload after the
  # firewall flushed the ruleset, where a delete-then-load would leave a gap.
  mkNftReplaceTable =
    {
      nft,
      family,
      table,
      file,
    }:
    ''
      { printf '%s\n' "table ${family} ${table}" "delete table ${family} ${table}"; cat ${file}; } | ${nft} -f -
    '';

  mkIpRuleDeleteByFwmark =
    {
      ip,
      family ? "",
      fwmark,
      table,
    }:
    ''
      while ${ip} ${
        lib.optionalString (family != "") "${family} "
      }rule del fwmark ${toString fwmark} table ${toString table} 2>/dev/null; do :; done
    '';

  mkIpRuleDeleteByTable =
    {
      ip,
      family,
      table,
    }:
    ''
      while ${ip} ${family} rule del table ${toString table} 2>/dev/null; do :; done
    '';

  mkIpRuleDeleteByPriority =
    {
      ip,
      family,
      priority,
    }:
    ''
      while ${ip} ${family} rule del pref ${toString priority} 2>/dev/null; do :; done
    '';

  mkIpRouteFlushTable =
    {
      ip,
      family,
      table,
    }:
    ''
      ${ip} ${family} route flush table ${toString table} 2>/dev/null || true
    '';

  mkIpLocalDefaultRouteDelete =
    {
      ip,
      family ? "",
      table,
    }:
    ''
      ${ip} ${
        lib.optionalString (family != "") "${family} "
      }route del local default dev lo table ${toString table} 2>/dev/null || true
    '';

  # The TProxy fwmark rule and local route: IPv4 always, IPv6 with proxy.ipv6.
  # Cleanup drops both families, whatever the setting was.
  mkTproxyRoutingDown =
    {
      ip,
      fwmark,
      table,
    }:
    lib.concatMapStrings
      (family: ''
        ${mkIpRuleDeleteByFwmark {
          inherit
            ip
            family
            fwmark
            table
            ;
        }}
        ${mkIpLocalDefaultRouteDelete { inherit ip family table; }}
        ${ip} ${family} route del unreachable default table ${toString table} 2>/dev/null || true
      '')
      [
        "-4"
        "-6"
      ]
    + ''
      while ${ip} -6 rule del fwmark ${toString fwmark} table main suppress_prefixlength 0 2>/dev/null; do :; done
    '';

  mkTproxyRoutingUp =
    {
      ip,
      ipv6,
      fwmark,
      table,
    }:
    lib.concatMapStrings (family: ''
      ${ip} ${family} route replace local default dev lo table ${toString table}
      ${ip} ${family} rule add fwmark ${toString fwmark} table ${toString table}
    '') ([ "-4" ] ++ lib.optional ipv6 "-6")
    # Without proxy.ipv6, marked IPv6 would leave directly: unreachable instead, so apps fall
    # back to IPv4. Not where the kernel has no IPv6 at all. On-link IPv6 still goes by main
    # (suppress_prefixlength 0: any route but its default); added last, it is looked at first.
    + lib.optionalString (!ipv6) ''
      if [ -e /proc/net/if_inet6 ]; then
        ${ip} -6 route replace unreachable default table ${toString table}
        ${ip} -6 rule add fwmark ${toString fwmark} table ${toString table}
        ${ip} -6 rule add fwmark ${toString fwmark} table main suppress_prefixlength 0
      fi
    '';

  mkIpLinkDelete =
    {
      ip,
      interface,
    }:
    ''
      ${ip} link del dev ${lib.escapeShellArg interface} 2>/dev/null || true
    '';

  flushResolvedCaches = ''
    ${pkgs.systemd}/bin/resolvectl flush-caches 2>/dev/null || true
  '';
}
