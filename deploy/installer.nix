# proxy-suite-install: the installer the ISO runs on tty1 (deploy/installer.sh).
{
  lib,
  writeShellApplication,
  xray,
  disko,
  diskLayout,
  flakeRev,
  flakeSource,
  stateVersion,
  coreutils,
  curl,
  gawk,
  getent,
  gnugrep,
  gnused,
  iproute2,
  iputils,
  jq,
  mkpasswd,
  nix,
  nixos-install-tools,
  openssl,
  systemd,
  util-linux,
  xkcdpass,
}:

import ./script.nix { inherit lib writeShellApplication; } {
  name = "proxy-suite-install";
  script = ./installer.sh;
  runtimeInputs = [
    coreutils
    curl
    disko
    gawk
    getent
    gnugrep
    gnused
    iproute2
    iputils
    jq
    mkpasswd
    nix
    nixos-install-tools
    openssl
    systemd
    util-linux
    xkcdpass
    xray
  ];
  runtimeEnv = {
    PSI_FLAKE_REV = flakeRev;
    PSI_FLAKE_SRC = "${flakeSource}";
    PSI_STATE_VERSION = stateVersion;
    PSI_DISK_LAYOUT = "${diskLayout}";
  };
}
