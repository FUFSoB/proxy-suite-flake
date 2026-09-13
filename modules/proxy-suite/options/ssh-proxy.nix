{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  token = types.nullOr (types.strMatching "[^[:space:]]+");
  path =
    description: example:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      inherit description example;
    };
in
{
  options.services.proxy-suite.sshProxy = {
    enable = mkEnableOption "an SSH dynamic SOCKS5 tunnel";

    # Where the tunnel goes.
    server = {
      user = mkOption {
        type = token;
        default = null;
        description = "SSH login user.";
        example = "root";
      };

      host = mkOption {
        type = token;
        default = null;
        description = "SSH server.";
        example = "ssh.example.com";
      };

      port = mkOption {
        type = types.port;
        default = 22;
        description = "SSH server port.";
      };
    };

    asOutbound = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add the tunnel as an outbound tagged "ssh-proxy". sing-box dials SSH itself; XRay goes
        through the OpenSSH unit's SOCKS listener.
      '';
    };

    identityFile = path "Runtime path to the private key. Null uses the agent or OpenSSH defaults." "/run/secrets/proxy-suite-ssh-key";

    hostKey = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Accepted host keys (sing-box). List every key `ssh-keyscan` prints: the algorithm is
        negotiated. Empty accepts any key.
      '';
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..." ];
    };

    hostKeyFile = path "Known-hosts file to read hostKey from at runtime (sing-box). Wins over hostKey." "/root/.ssh/known_hosts";

    # The rest only apply to the OpenSSH unit (XRay, or asOutbound = false).
    knownHostsFile = path "Known-hosts file for OpenSSH." "/run/secrets/proxy-suite-ssh-known-hosts";

    strictHostKeyChecking = mkOption {
      type = types.enum [
        "yes"
        "accept-new"
        "no"
      ];
      default = "accept-new";
      description = "OpenSSH host key policy.";
      example = "yes";
    };

    # The local SOCKS5 listener the OpenSSH unit opens.
    listener = {
      address = mkOption {
        type = types.strMatching "[^[:space:]]+";
        default = "127.0.0.1";
        description = "Address of the OpenSSH SOCKS5 listener.";
      };

      port = mkOption {
        type = types.port;
        default = 1091;
        description = "Port of the OpenSSH SOCKS5 listener.";
      };
    };

    serviceUser = mkOption {
      type = token;
      default = null;
      description = "Unix user running the OpenSSH unit.";
      example = "proxy";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra OpenSSH arguments.";
      example = [
        "-J"
        "jump.example.com"
      ];
    };

    domainStrategy = mkOption {
      type = types.nullOr (
        types.enum [
          "prefer_ipv4"
          "prefer_ipv6"
          "ipv4_only"
          "ipv6_only"
        ]
      );
      default = null;
      description = "Resolve destinations locally before the tunnel (XRay only). Can break geo-steered CDNs.";
      example = "prefer_ipv4";
    };
  };
}
