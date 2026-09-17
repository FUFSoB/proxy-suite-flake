# proxy-suite-install: the installer the ISO runs on tty1 (deploy/installer.sh).
{
  lib,
  writeShellApplication,
  xray,
  flakeUrl,
  flakeSource,
  stateVersion,
  coreutils,
  curl,
  dosfstools,
  e2fsprogs,
  gawk,
  getent,
  gnugrep,
  gnused,
  gptfdisk,
  iproute2,
  iputils,
  mkpasswd,
  nix,
  nixos-install-tools,
  openssl,
  parted,
  systemd,
  util-linux,
  xkcdpass,
}:

writeShellApplication {
  name = "proxy-suite-install";
  runtimeInputs = [
    coreutils
    curl
    dosfstools
    e2fsprogs
    gawk
    getent
    gnugrep
    gnused
    gptfdisk
    iproute2
    iputils
    mkpasswd
    nix
    nixos-install-tools
    openssl
    parted
    systemd
    util-linux
    xkcdpass
    xray
  ];
  runtimeEnv = {
    PSI_FLAKE_URL = flakeUrl;
    PSI_FLAKE_SRC = "${flakeSource}";
    PSI_STATE_VERSION = stateVersion;
  };
  text = lib.concatStringsSep "\n" [
    (builtins.readFile ./net-lib.sh)
    (builtins.readFile ./installer.sh)
  ];
}
