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
    mkOneshotService {
      inherit description execStart execStop;
      requires = [ "${backendService}.service" ];
      after = [ "${backendService}.service" ];
    };

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
      table,
    }:
    ''
      ${ip} route del local default dev lo table ${toString table} 2>/dev/null || true
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
