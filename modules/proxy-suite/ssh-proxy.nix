# Native OpenSSH dynamic SOCKS5 proxy service.
{
  lib,
  pkgs,
  cfg,
}:

let
  s = cfg.sshProxy;
  destination = if s.user == null then s.host else "${s.user}@${s.host}";
  extraArgs = lib.concatMapStrings (arg: "    args+=(${lib.escapeShellArg arg})\n") s.extraArgs;
  startScript = pkgs.writeShellScript "proxy-suite-ssh-proxy-start" ''
        set -euo pipefail

        args=(
          -N
          -o BatchMode=yes
          -o ExitOnForwardFailure=yes
          -o StrictHostKeyChecking=${lib.escapeShellArg s.strictHostKeyChecking}
          -D ${lib.escapeShellArg "${s.listenAddress}:${toString s.listenPort}"}
        )
        ${lib.optionalString (s.sshPort != 22) "args+=(-p ${toString s.sshPort})"}
        ${lib.optionalString (s.identityFile != null) "args+=(-i ${lib.escapeShellArg s.identityFile})"}
        ${lib.optionalString (
          s.knownHostsFile != null
        ) "args+=(-o ${lib.escapeShellArg "UserKnownHostsFile=${s.knownHostsFile}"})"}
    ${extraArgs}
        exec ${pkgs.openssh}/bin/ssh "''${args[@]}" ${lib.escapeShellArg destination}
  '';
in
{
  systemd.services.proxy-suite-ssh-proxy = {
    description = "SSH dynamic SOCKS5 proxy";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = startScript;
      Restart = "on-failure";
      RestartSec = 5;
    }
    // lib.optionalAttrs (s.serviceUser != null) {
      User = s.serviceUser;
    };
  };
}
