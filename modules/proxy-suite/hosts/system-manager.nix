# system-manager (numtide/system-manager): root services on another distribution. Its
# systemd options are NixOS's own, so units are forwarded as on NixOS; what it lacks
# (user units, polkit, nftables, the firewall, kernel modules) is written to /etc or
# left to the host.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.proxy-suite;
  internal = options.services.proxy-suite.internal;
  inherit (import ./common.nix { inherit lib; })
    forwardWith
    forward
    unitsWithOwnSyslogIdentifier
    ;

  # For the user manager each session runs: units go to /etc/systemd/user, which it reads
  # alongside the distribution's own.
  userUnits = import ./user-units.nix {
    inherit lib pkgs;
    runtimeDir = "%t";
    stateDir = "%S";
    # The GUI escalates through the distribution's setuid pkexec.
    hostPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
  };
  toINI = lib.generators.toINI { listsAsDuplicateKeys = true; };
  userServiceFiles = lib.concatMapAttrs (
    name: unit:
    let
      fileName = "${name}.service";
      rendered = userUnits.toService name unit;
      file = pkgs.writeText fileName (toINI rendered);
      link = target: lib.nameValuePair "systemd/user/${target}/${fileName}" { source = file; };
    in
    {
      "systemd/user/${fileName}".source = file;
    }
    // lib.listToAttrs (
      map (target: link "${target}.wants") (rendered.Install.WantedBy or [ ])
      ++ map (target: link "${target}.requires") (rendered.Install.RequiredBy or [ ])
    )
  ) (lib.filterAttrs (_: unit: unit.enable) cfg.internal.userServices);

  # awg-quick pushes DNS through resolvconf: resolvectl stands in for it where
  # systemd-resolved owns resolv.conf, openresolv everywhere else.
  resolvconf = pkgs.writeShellScriptBin "resolvconf" ''
    if [ -d /run/systemd/resolve ]; then
      exec -a resolvconf ${pkgs.systemd}/bin/resolvectl "$@"
    fi
    exec ${pkgs.openresolv}/bin/resolvconf "$@"
  '';
in
{
  options.systemd.services = unitsWithOwnSyslogIdentifier;

  config = lib.mkMerge [
    {
      services.proxy-suite.host = {
        kind = "system-manager";
        privileged = true;
        serviceManager = "systemd";
        inherit (config.networking) enableIPv6;
        # The host's kernel is not Nix's to extend: AmneziaWG runs in userspace.
        kernelPackages = null;
        firewallPackage = pkgs.nftables;
        resolvconfPackage = resolvconf;
      };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.internal.kernelModulePackages == [ ];
          message = "proxy-suite: system-manager cannot load kernel modules from Nix; leave amneziaWg.kernelModulePackage at null";
        }
      ];

      systemd.services = forward internal.services;
      systemd.timers = forward internal.timers;
      systemd.paths = forward internal.paths;
      systemd.tmpfiles.rules = forward internal.tmpfiles;

      environment.systemPackages = lib.mkMerge [
        (forwardWith lib.mkBefore internal.earlyPackages)
        (forward internal.packages)
      ];

      environment.etc = lib.mkMerge [
        userServiceFiles
        # Read by polkit 0.106 and later; the distribution runs the daemon. The rules
        # go through the host's setuid pkexec: nothing here needs a wrapper.
        (lib.mkIf cfg.internal.polkit.enable {
          "polkit-1/rules.d/50-proxy-suite.rules".text = cfg.internal.polkit.rules;
        })
      ];

      users.users = lib.genAttrs cfg.internal.systemUsers (name: {
        isSystemUser = true;
        group = name;
        description = "proxy-suite daemons";
      });
      users.groups = lib.genAttrs (cfg.internal.systemUsers ++ cfg.internal.groups) (_: { });

      # Only reported: system-manager leaves the host firewall alone. The routing modes
      # load their own nftables tables, and the distribution's loose reverse-path filter
      # already lets AmneziaWG replies in.
      networking.firewall = {
        allowedTCPPorts = forward internal.firewall.allowedTCPPorts;
        allowedUDPPorts = forward internal.firewall.allowedUDPPorts;
      };
    })
  ];
}
