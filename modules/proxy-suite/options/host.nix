# What the host adapter (modules/proxy-suite/hosts/*.nix) tells the core about the
# host, and what the core hands back for the adapter to turn into host settings.
# Nothing here is user-facing.
{ lib, pkgs, ... }:

let
  inherit (lib) mkOption types;
  unitType = import ./types/unit.nix { inherit lib; };

  internalOption =
    type: default:
    mkOption {
      inherit type default;
      internal = true;
      visible = false;
    };
  units = internalOption (types.attrsOf unitType) { };
in
{
  options.services.proxy-suite.host = {
    kind = internalOption (types.enum [
      "nixos"
      "system-manager"
      "home-manager"
      "nix-on-droid"
    ]) "nixos";
    # Whether the services run as root and may program routing, firewalls and interfaces.
    privileged = internalOption types.bool true;
    # Persistent state; units name the proxy-suite subdirectory of their host's state dir.
    stateDir = internalOption types.str "/var/lib/proxy-suite";
    # Parent of the per-unit runtime directories (proxy-suite-socks, …).
    runtimeDir = internalOption types.str "/run";
    # Which manager runs the units: proxy-ctl and the control scripts talk to it.
    serviceManager = internalOption (types.enum [
      "systemd"
      "systemd-user"
      "supervisor"
    ]) "systemd";
    # The commands that manage the units and show their logs, without a --user of their own.
    systemctl = internalOption types.str "${pkgs.systemd}/bin/systemctl";
    journalctl = internalOption types.str "journalctl";
    # Host facts a few option defaults read.
    enableIPv6 = internalOption types.bool true;
    kernelPackages = internalOption (types.nullOr types.raw) null;
    firewallPackage = internalOption (types.nullOr types.package) null;
    resolvconfPackage = internalOption (types.nullOr types.package) null;
  };

  options.services.proxy-suite.internal = {
    # systemd-shaped unit declarations; the adapter installs or converts them.
    services = units;
    userServices = units;
    timers = units;
    paths = units;
    tmpfiles = internalOption (types.listOf types.str) [ ];
    packages = internalOption (types.listOf types.package) [ ];
    # Ahead of the host's own packages (zapret's binaries shadow same-named ones).
    earlyPackages = internalOption (types.listOf types.package) [ ];
    systemUsers = internalOption (types.listOf types.str) [ ];
    groups = internalOption (types.listOf types.str) [ ];
    polkit = {
      enable = internalOption types.bool false;
      pkexecWrapper = internalOption types.bool false;
      rules = internalOption types.lines "";
    };
    nftables = internalOption types.bool false;
    firewall = {
      allowedTCPPorts = internalOption (types.listOf types.port) [ ];
      allowedUDPPorts = internalOption (types.listOf types.port) [ ];
      extraReversePathFilterRules = internalOption types.lines "";
    };
    kernelModulePackages = internalOption (types.listOf types.package) [ ];
  };
}
