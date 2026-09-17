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

writeShellApplication {
  name = "proxy-suite-net";
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
  text = lib.concatStringsSep "\n" [
    (builtins.readFile ./net-lib.sh)
    (builtins.readFile ./net-rescue.sh)
  ];
}
