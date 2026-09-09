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
          -o ServerAliveInterval=15
          -o ServerAliveCountMax=3
          -o ConnectTimeout=10
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
    # Restart=always plus a server that refuses connections would otherwise hit
    # the default 5-starts-in-10s limit and stay failed.
    startLimitIntervalSec = 0;
    serviceConfig = {
      ExecStart = startScript;
      # `ssh -N` exits 0 when the server closes the connection cleanly, which
      # under on-failure left the tunnel down for good.
      Restart = "always";
      RestartSec = 5;
      # One fd per forwarded channel; the 1024 default is low for a relay.
      LimitNOFILE = 65536;
    }
    // lib.optionalAttrs (s.serviceUser != null) {
      User = s.serviceUser;
    };
  };
}
