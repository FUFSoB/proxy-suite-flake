# Renders the core's systemd-shaped units into a user manager's INI sections
# ({ Unit, Service, Install }), with what only NixOS's unit options provide spelled out:
# the directories systemd would create and the PATH NixOS would set. runtimeDir and
# stateDir are the bases of RuntimeDirectory= and StateDirectory= (specifiers allowed);
# hostPath ends every PATH, for the host's own setuid binaries.
{
  lib,
  pkgs,
  runtimeDir,
  stateDir,
  hostPath ? null,
}:

let
  # The user manager has none of the system targets; the default target stands in for
  # multi-user.target.
  systemTargets = [
    "network.target"
    "network-online.target"
    "nss-lookup.target"
    "sysinit.target"
  ];
  userTargets = {
    "multi-user.target" = "default.target";
  };
  toUserUnits =
    units: lib.unique (map (unit: userTargets.${unit} or unit) (lib.subtractLists systemTargets units));

  # Identity, capabilities and sandboxing: a user manager can apply them only partly
  # (and ProtectHome would hide the state directory), and the core sets none of them
  # for a rootless host itself.
  systemOnlyKeys = [
    "User"
    "Group"
    "DynamicUser"
    "SupplementaryGroups"
    "AmbientCapabilities"
    "CapabilityBoundingSet"
    "PrivateTmp"
    "PrivateDevices"
    "ProtectSystem"
    "ProtectHome"
    "ProtectClock"
    "ProtectHostname"
    "ProtectKernelModules"
    "ProtectKernelLogs"
    "ProtectKernelTunables"
    "ProtectControlGroups"
    "RestrictSUIDSGID"
    "RestrictRealtime"
    "LockPersonality"
    "ReadWritePaths"
    "ReadOnlyPaths"
    # Rendered below against runtimeDir and stateDir: a user manager resolves them
    # against XDG directories, which need not be where the core looks.
    "RuntimeDirectory"
    "RuntimeDirectoryMode"
    "StateDirectory"
    "StateDirectoryMode"
  ];

  # home-manager takes plain values only.
  iniValue =
    value:
    if lib.isList value then
      map iniValue value
    else if lib.isBool value || lib.isInt value then
      value
    else
      toString value;
  iniSection = section: lib.mapAttrs (_: iniValue) (lib.filterAttrs (_: v: v != null) section);

  # As NixOS's service `path` default.
  defaultPath = with pkgs; [
    coreutils
    findutils
    gnugrep
    gnused
    systemd
  ];

  # As NixOS: "@" is not allowed in a store path name.
  jobScript =
    name: text: pkgs.writeShellScript (lib.replaceStrings [ "@" ] [ "_" ] name) "set -e\n${text}";

  dirsScript = pkgs.writeShellScript "proxy-suite-dirs" ''
    while (( $# )); do
      ${pkgs.coreutils}/bin/install -d -m "$1" -- "$2"
      shift 2
    done
  '';
  removeDirsScript = pkgs.writeShellScript "proxy-suite-remove-dirs" ''
    ${pkgs.coreutils}/bin/rm -rf -- "$@"
  '';

  directories =
    serviceConfig: key: base:
    map (dir: {
      path = "${base}/${dir}";
      mode = serviceConfig."${key}Mode" or "0755";
    }) (lib.concatMap (lib.splitString " ") (lib.toList (serviceConfig.${key} or [ ])));

  unitSection =
    unit:
    iniSection (
      {
        Description = unit.description;
      }
      // lib.filterAttrs (_: v: v != [ ]) {
        After = toUserUnits unit.after;
        Before = toUserUnits unit.before;
        Wants = toUserUnits unit.wants;
        Requires = toUserUnits unit.requires;
        BindsTo = toUserUnits unit.bindsTo;
        PartOf = toUserUnits unit.partOf;
        Conflicts = toUserUnits unit.conflicts;
      }
      // lib.optionalAttrs (unit.startLimitIntervalSec != null) {
        StartLimitIntervalSec = unit.startLimitIntervalSec;
      }
      // unit.unitConfig
    );

  installSection =
    unit:
    lib.filterAttrs (_: v: v != [ ]) {
      WantedBy = toUserUnits unit.wantedBy;
      RequiredBy = toUserUnits unit.requiredBy;
    };

  withInstall =
    unit: attrs:
    attrs
    // lib.optionalAttrs (installSection unit != { }) {
      Install = installSection unit;
    };

  toService =
    name: unit:
    let
      sc = unit.serviceConfig;
      runtimeDirs = directories sc "RuntimeDirectory" runtimeDir;
      stateDirs = directories sc "StateDirectory" stateDir;
      dirs = runtimeDirs ++ stateDirs;
      joinPaths = ds: lib.concatMapStringsSep ":" (d: d.path) ds;

      # Paths go on the command line, where systemd expands specifiers such as %t.
      commandLine =
        script: args: lib.concatStringsSep " " ([ "${script}" ] ++ map (arg: ''"${arg}"'') args);
      makeDirs = commandLine dirsScript (
        lib.concatMap (d: [
          d.mode
          d.path
        ]) dirs
      );
      removeRuntimeDirs = commandLine removeDirsScript (map (d: d.path) runtimeDirs);

      path = unit.path ++ defaultPath;
      environment = {
        PATH = lib.concatStringsSep ":" (
          [
            (lib.makeBinPath path)
            (lib.makeSearchPathOutput "bin" "sbin" path)
          ]
          ++ lib.optional (hostPath != null) hostPath
        );
      }
      // lib.optionalAttrs (runtimeDirs != [ ]) { RUNTIME_DIRECTORY = joinPaths runtimeDirs; }
      // lib.optionalAttrs (stateDirs != [ ]) { STATE_DIRECTORY = joinPaths stateDirs; }
      // lib.filterAttrs (_: v: v != null) unit.environment;

      optionalScript = suffix: text: lib.optional (text != "") (jobScript "${name}-${suffix}" text);
    in
    withInstall unit {
      Unit = unitSection unit;
      Service = iniSection (
        builtins.removeAttrs sc systemOnlyKeys
        // lib.optionalAttrs (sc ? WorkingDirectory && !lib.hasPrefix "-" sc.WorkingDirectory) {
          # Created by the first ExecStartPre, which already runs in it.
          WorkingDirectory = "-${sc.WorkingDirectory}";
        }
        // lib.filterAttrs (_: v: v != [ ]) {
          Environment =
            lib.mapAttrsToList (n: v: builtins.toJSON "${n}=${toString v}") environment
            ++ lib.toList (sc.Environment or [ ]);
          ExecStartPre =
            lib.optional (dirs != [ ]) makeDirs
            ++ optionalScript "pre-start" unit.preStart
            ++ lib.toList (sc.ExecStartPre or [ ]);
          ExecStart = optionalScript "start" unit.script ++ lib.toList (sc.ExecStart or [ ]);
          ExecStartPost = optionalScript "post-start" unit.postStart ++ lib.toList (sc.ExecStartPost or [ ]);
          ExecStop = optionalScript "pre-stop" unit.preStop ++ lib.toList (sc.ExecStop or [ ]);
          ExecStopPost =
            optionalScript "post-stop" unit.postStop
            ++ lib.toList (sc.ExecStopPost or [ ])
            ++ lib.optional (runtimeDirs != [ ]) removeRuntimeDirs;
        }
      );
    };

  toTimer =
    _: unit:
    withInstall unit {
      Unit = unitSection unit;
      Timer = iniSection unit.timerConfig;
    };

  toPath =
    _: unit:
    withInstall unit {
      Unit = unitSection unit;
      Path = iniSection unit.pathConfig;
    };
in
{
  inherit toService toTimer toPath;
}
