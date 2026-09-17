# proxy-suitectl: the service manager of hosts without systemd (nix-on-droid). It reads
# the units from `manifest`, a path outside the store the host's activation points at the
# current generation's units, so the command itself does not change with the configuration.
{
  lib,
  pkgs,
}:

{
  # Where the daemon keeps its socket, logs and credentials.
  supervisorDir,
  manifest,
  # What %t and %S expand to.
  runtimeDir,
  stateDir,
}:

let
  unwrapped = pkgs.writeScriptBin "proxy-suitectl" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ./proxy-ctl/proxy_supervisor.py
  );
in
pkgs.symlinkJoin {
  name = "proxy-suitectl";
  paths = [ unwrapped ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram "$out/bin/proxy-suitectl" \
      --set PROXY_SUITE_SUPERVISOR_DIR ${lib.escapeShellArg supervisorDir} \
      --set PROXY_SUITE_MANIFEST ${lib.escapeShellArg manifest} \
      --set PROXY_SUITE_RUNTIME_BASE ${lib.escapeShellArg runtimeDir} \
      --set PROXY_SUITE_STATE_BASE ${lib.escapeShellArg stateDir}
  '';
  meta = {
    description = "A systemctl-like supervisor for proxy-suite's units on hosts without systemd";
    mainProgram = "proxy-suitectl";
  };
}
