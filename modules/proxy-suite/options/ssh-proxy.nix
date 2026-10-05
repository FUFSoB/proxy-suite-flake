{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  token = types.nullOr (types.strMatching "[^[:space:]]+");
  path = (import ./lib.nix { inherit lib; }).nullStr;
in
{
  options.services.proxy-suite.sshProxy = {
    enable = mkEnableOption "an SSH SOCKS5 tunnel";

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
        Add the tunnel as an outbound tagged "ssh-proxy". On sing-box and hybrid, sing-box connects
        over SSH itself and needs `hostKey` or `hostKeyFile`. Otherwise OpenSSH runs a SOCKS listener, set up
        by `listener`, `knownHostsFile`, `strictHostKeyChecking`, `serviceUser` and `extraArgs`.
      '';
    };

    identityFile = path "File with the SSH private key. It can stay root-only. `null`: the agent or OpenSSH defaults." "/run/secrets/proxy-suite-ssh-key";

    hostKey = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Accepted host keys, for sing-box, and for OpenSSH without `knownHostsFile`. List every
        key `ssh-keyscan` prints, since the key type is negotiated.
      '';
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..." ];
    };

    hostKeyFile = path "Known-hosts file to read host keys from (sing-box, and OpenSSH without `knownHostsFile`). Takes priority over `hostKey`." "/root/.ssh/known_hosts";

    # The rest only apply to the OpenSSH unit (XRay, or asOutbound = false).
    knownHostsFile = path "Known-hosts file for OpenSSH." "/run/secrets/proxy-suite-ssh-known-hosts";

    strictHostKeyChecking = mkOption {
      type = types.enum [
        "yes"
        "accept-new"
        "no"
      ];
      default = "yes";
      description = ''
        OpenSSH host key policy. "yes" needs the server's keys: `knownHostsFile`, or else
        `hostKeyFile` or `hostKey`. "accept-new" takes whatever key the first connection
        meets, which anyone on the way can answer then.
      '';
      example = "accept-new";
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
        description = ''
          Port of the OpenSSH SOCKS5 listener. It takes no login: where it is the XRay backend's
          hop (`asOutbound`) on a host with root, only proxy-suite's daemons and root may
          connect to it. A standalone tunnel stays open to every local user.
        '';
      };
    };

    serviceUser = mkOption {
      # A user name as nft and systemd take one.
      type = types.nullOr (types.strMatching "[a-z_][a-z0-9_-]*[$]?");
      default = "proxy-suite-daemon";
      description = ''
        User that runs OpenSSH. The default is sandboxed; `null` runs it as root. Another user's
        traffic gets past the kill switch, all of it: never a login user's.
      '';
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
      description = "Resolve names locally instead of on the server (XRay only). Can make CDNs pick distant servers.";
      example = "prefer_ipv4";
    };
  };
}
