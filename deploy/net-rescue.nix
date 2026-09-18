# proxy-suite-net: re-enter the uplink settings from the console of an installed server
# whose network does not come up.
{
  lib,
  writeShellApplication,
  coreutils,
  curl,
  gawk,
  getent,
  gnugrep,
  gnused,
  iproute2,
  iputils,
  systemd,
}:

import ./script.nix { inherit lib writeShellApplication; } {
  name = "proxy-suite-net";
  script = ./net-rescue.sh;
  runtimeInputs = [
    coreutils
    curl
    gawk
    getent
    gnugrep
    gnused
    iproute2
    iputils
    systemd
  ];
}
