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

  # The unit and package forwarding NixOS and system-manager do identically.
  systemdForward = internal: {
    systemd.services = forward internal.services;
    systemd.timers = forward internal.timers;
    systemd.paths = forward internal.paths;
    systemd.tmpfiles.rules = forward internal.tmpfiles;

    environment.systemPackages = lib.mkMerge [
      (forwardWith lib.mkBefore internal.earlyPackages)
      (forward internal.packages)
    ];
  };

  # One system user per daemon, each in a group of its own, plus the userControl group.
  systemUsersAndGroups = cfg: {
    users.users = lib.genAttrs cfg.internal.systemUsers (name: {
      isSystemUser = true;
      group = name;
      description = "proxy-suite daemons";
    });
    users.groups = lib.genAttrs (cfg.internal.systemUsers ++ cfg.internal.groups) (_: { });
  };

  firewallPortForward = internal: {
    networking.firewall = {
      allowedTCPPorts = forward internal.firewall.allowedTCPPorts;
      allowedUDPPorts = forward internal.firewall.allowedUDPPorts;
    };
  };

  # The rootless adapters (home-manager, nix-on-droid) render the same unit set for a user
  # manager: system and user services together, timers and paths, each filtered to enabled.
  userUnitsFor =
    {
      lib,
      pkgs,
      host,
      internal,
      hostPath ? null,
    }:
    let
      units = import ./user-units.nix (
        {
          inherit lib pkgs;
          inherit (host) runtimeDir;
          stateDir = builtins.dirOf host.stateDir;
        }
        // lib.optionalAttrs (hostPath != null) { inherit hostPath; }
      );
      enabled = lib.filterAttrs (_: unit: unit.enable);
    in
    {
      services = lib.mapAttrs units.toService (enabled (internal.services // internal.userServices));
      timers = lib.mapAttrs units.toTimer (enabled internal.timers);
      paths = lib.mapAttrs units.toPath (enabled internal.paths);
    };

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
