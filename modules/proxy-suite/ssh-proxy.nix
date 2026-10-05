# Native OpenSSH dynamic SOCKS5 proxy service.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  s = cfg.sshProxy;
  inherit (derived.constants) serviceUser unprivilegedServiceConfig;
  destination = if s.server.user == null then s.server.host else "${s.server.user}@${s.server.host}";
  # ssh reads "::1:1091" as a bad forwarding spec: an IPv6 address goes in brackets.
  listenHost =
    if lib.hasInfix ":" s.listener.address then "[${s.listener.address}]" else s.listener.address;
  extraArgs = lib.concatMapStrings (arg: "    args+=(${lib.escapeShellArg arg})\n") s.extraArgs;
  # The server's keys: a known-hosts file, the one sing-box reads, or its keys as one.
  knownHostsSource =
    if s.knownHostsFile != null then
      s.knownHostsFile
    else if s.hostKeyFile != null then
      s.hostKeyFile
    else if s.hostKey != [ ] then
      pkgs.writeText "proxy-suite-ssh-known-hosts" (
        lib.concatMapStrings (
          key:
          "${
            if s.server.port == 22 then s.server.host else "[${s.server.host}]:${toString s.server.port}"
          } ${key}\n"
        ) s.hostKey
      )
    else
      null;
  # The service user's home is /var/empty: accepted host keys are kept in the state dir.
  knownHosts =
    if knownHostsSource != null then
      ''"$CREDENTIALS_DIRECTORY/known_hosts"''
    else if s.serviceUser == serviceUser then
      ''"$STATE_DIRECTORY/known_hosts"''
    else
      null;
  startScript = pkgs.writeShellScript "proxy-suite-ssh-proxy" ''
        set -euo pipefail

        args=(
          -N
          -o BatchMode=yes
          -o ExitOnForwardFailure=yes
          -o ServerAliveInterval=15
          -o ServerAliveCountMax=3
          -o ConnectTimeout=10
          -o StrictHostKeyChecking=${lib.escapeShellArg s.strictHostKeyChecking}
          -D ${lib.escapeShellArg "${listenHost}:${toString s.listener.port}"}
        )
        ${lib.optionalString (s.server.port != 22) "args+=(-p ${toString s.server.port})"}
        ${lib.optionalString (s.identityFile != null) ''args+=(-i "$CREDENTIALS_DIRECTORY/identity")''}
        ${lib.optionalString (knownHosts != null) "args+=(-o UserKnownHostsFile=${knownHosts})"}
    ${extraArgs}
        exec ${pkgs.openssh}/bin/ssh "''${args[@]}" ${lib.escapeShellArg destination}
  '';
in
{
  services.proxy-suite.internal.services.proxy-suite-ssh-proxy = {
    description = "SSH dynamic SOCKS5 proxy";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # Restart=always plus a server that refuses connections would otherwise hit
    # the default 5-starts-in-10s limit and stay failed.
    startLimitIntervalSec = 0;
    serviceConfig =
      lib.optionalAttrs (s.serviceUser == serviceUser) (unprivilegedServiceConfig [ "net_bind_service" ])
      // {
        ExecStart = startScript;
        # Copies the service user can read, whoever owns the originals.
        LoadCredential =
          lib.optional (s.identityFile != null) "identity:${s.identityFile}"
          ++ lib.optional (knownHostsSource != null) "known_hosts:${knownHostsSource}";
        StateDirectory = "proxy-suite/ssh";
        StateDirectoryMode = "0700";
        # `ssh -N` exits 0 when the server closes the connection cleanly, which
        # under on-failure left the tunnel down for good.
        Restart = "always";
        RestartSec = 5;
        # One fd per forwarded channel; the 1024 default is low for a relay.
        LimitNOFILE = 65536;
      }
      // lib.optionalAttrs (s.serviceUser != null && s.serviceUser != serviceUser) {
        User = s.serviceUser;
      };
  };
}
