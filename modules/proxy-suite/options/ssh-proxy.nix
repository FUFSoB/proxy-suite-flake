# SSH dynamic SOCKS5 proxy options.
{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.proxy-suite.sshProxy = {
    enable = mkEnableOption "SSH dynamic SOCKS5 proxy";

    user = mkOption {
      type = types.nullOr (types.strMatching "[^[:space:]]+");
      default = null;
      description = ''
        SSH login user. Required when sshProxy.enable is true.
      '';
      example = "root";
    };

    serviceUser = mkOption {
      type = types.nullOr (types.strMatching "[^[:space:]]+");
      default = null;
      description = ''
        Unix user for the systemd SSH proxy service. Leave unset to use
        systemd's default user.
      '';
      example = "proxy";
    };

    host = mkOption {
      type = types.nullOr (types.strMatching "[^[:space:]]+");
      default = null;
      description = ''
        SSH server hostname or address. Required when sshProxy.enable is true.
      '';
      example = "ssh.example.com";
    };

    sshPort = mkOption {
      type = types.port;
      default = 22;
      description = "Remote SSH server port.";
      example = 22;
    };

    listenAddress = mkOption {
      type = types.strMatching "[^[:space:]]+";
      default = "127.0.0.1";
      description = "Local address for the SSH-created SOCKS5 listener.";
      example = "127.0.0.1";
    };

    listenPort = mkOption {
      type = types.port;
      default = 1091;
      description = "Local port for the SSH-created SOCKS5 listener.";
      example = 1091;
    };

    identityFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Runtime path to the SSH private key. Leave unset to use the SSH agent
        or OpenSSH's normal identity-file lookup.
      '';
      example = "/run/secrets/proxy-suite-ssh-key";
    };

    knownHostsFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Optional runtime path to the known-hosts file passed to OpenSSH.
      '';
      example = "/run/secrets/proxy-suite-ssh-known-hosts";
    };

    strictHostKeyChecking = mkOption {
      type = types.enum [
        "yes"
        "accept-new"
        "no"
      ];
      default = "accept-new";
      description = ''
        OpenSSH host-key verification policy. Use "yes" with pinned
        knownHostsFile contents for strict verification.
      '';
      example = "yes";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Additional arguments passed to OpenSSH before the destination.
        This can be used for options such as jump hosts or agent forwarding.
      '';
      example = [
        "-o"
        "ServerAliveInterval=30"
      ];
    };

    asOutbound = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add the local SSH SOCKS5 listener as a proxy-suite outbound tagged
        "ssh-proxy". Requires proxy.enable and an active SingBox or XRay
        backend.
      '';
      example = true;
    };
  };
}
