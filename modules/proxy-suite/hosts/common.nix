# Shared by the adapters whose host runs NixOS's own systemd unit options (NixOS,
# system-manager).
{ lib }:

rec {
  # Only what the core set: an internal option's default would add a definition of its
  # own. Definitions are forwarded rather than values, so priorities nested inside them
  # (mkDefault in a unit, say) still meet the rest of the host's.
  forwardWith =
    wrap: option:
    lib.mkIf (option.highestPrio < (lib.mkOptionDefault null).priority) (
      lib.mkMerge (map wrap option.definitions)
    );
  forward = forwardWith lib.id;

  # Scripts share one store name per block, and journald names a unit's output
  # after its ExecStart basename; tag each unit with its own name instead.
  unitsWithOwnSyslogIdentifier = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config.serviceConfig.SyslogIdentifier = lib.mkIf (lib.hasPrefix "proxy-suite-" name) (
            lib.mkDefault (lib.removeSuffix "@" name)
          );
        }
      )
    );
  };
}
