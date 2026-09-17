# NixOS: the core's declarations become NixOS settings as they are.
{
  config,
  options,
  lib,
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
in
{
  options.systemd.services = unitsWithOwnSyslogIdentifier;
  options.systemd.user.services = unitsWithOwnSyslogIdentifier;

  config = lib.mkMerge [
    {
      services.proxy-suite.host = {
        kind = "nixos";
        privileged = true;
        serviceManager = "systemd";
        inherit (config.networking) enableIPv6;
        inherit (config.boot) kernelPackages;
        firewallPackage = config.networking.firewall.package;
        resolvconfPackage = config.networking.resolvconf.package;
      };
    }

    (lib.mkIf cfg.enable {
      systemd.services = forward internal.services;
      systemd.user.services = forward internal.userServices;
      systemd.timers = forward internal.timers;
      systemd.paths = forward internal.paths;
      systemd.tmpfiles.rules = forward internal.tmpfiles;

      environment.systemPackages = lib.mkMerge [
        (forwardWith lib.mkBefore internal.earlyPackages)
        (forward internal.packages)
      ];

      users.users = lib.genAttrs cfg.internal.systemUsers (name: {
        isSystemUser = true;
        group = name;
        description = "proxy-suite daemons";
      });
      users.groups = lib.genAttrs (cfg.internal.systemUsers ++ cfg.internal.groups) (_: { });

      security.polkit.enable = lib.mkIf cfg.internal.polkit.enable true;
      security.polkit.extraConfig = forwardWith lib.mkAfter internal.polkit.rules;

      networking.nftables.enable = lib.mkIf cfg.internal.nftables (lib.mkDefault true);
      networking.firewall = {
        allowedTCPPorts = forward internal.firewall.allowedTCPPorts;
        allowedUDPPorts = forward internal.firewall.allowedUDPPorts;
        extraReversePathFilterRules = forward internal.firewall.extraReversePathFilterRules;
        trustedInterfaces = forward internal.firewall.trustedInterfaces;
      };

      boot.extraModulePackages = forward internal.kernelModulePackages;
      boot.kernel.sysctl = lib.mapAttrs (_: lib.mkDefault) cfg.internal.sysctl;
    })

    # Off by default since nixpkgs 26.11, and always there before, where the option does
    # not exist.
    (lib.optionalAttrs (options.security.polkit ? enablePkexecWrapper) {
      security.polkit.enablePkexecWrapper = lib.mkIf (
        cfg.enable && cfg.internal.polkit.pkexecWrapper
      ) true;
    })
  ];
}
