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

        OpenSSH path only: ignored when a SingBox or hybrid backend dials SSH
        natively and no separate unit is created.
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
      description = ''
        Local address for the SSH-created SOCKS5 listener.

        OpenSSH path only: a SingBox or hybrid backend dials SSH natively and
        creates no local listener.
      '';
      example = "127.0.0.1";
    };

    listenPort = mkOption {
      type = types.port;
      default = 1091;
      description = ''
        Local port for the SSH-created SOCKS5 listener.

        OpenSSH path only: a SingBox or hybrid backend dials SSH natively and
        creates no local listener.
      '';
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

        OpenSSH path only. A SingBox or hybrid backend verifies host keys with
        sshProxy.hostKey instead.
      '';
      example = "/run/secrets/proxy-suite-ssh-known-hosts";
    };

    hostKey = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Accepted SSH host public keys, in `authorized_keys` one-line form.
        Used by the sing-box backend, which verifies host keys by value rather
        than against a known-hosts file.

        List **every** key the server offers, not just one. The host key
        algorithm is negotiated, so pinning a single key fails the handshake
        outright whenever the server picks a different algorithm. Get the full
        set with `ssh-keyscan -p PORT HOST`, or from an existing known-hosts
        entry with `ssh-keygen -F '[HOST]:PORT'`.

        Leaving this empty accepts **any** host key, which allows a
        machine-in-the-middle on the tunnel. Set it whenever sshProxy.asOutbound
        is used with a SingBox or hybrid backend.

        Ignored by the XRay backend and by a standalone tunnel, which use
        knownHostsFile and strictHostKeyChecking instead.
      '';
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..." ];
    };

    hostKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Runtime path to a known-hosts file to read the accepted host keys from,
        instead of listing them inline in sshProxy.hostKey. Every key recorded
        there for `host:sshPort` is accepted, so a single known-hosts file stays
        the one source of truth. Hashed known-hosts files work.

        Read when the service starts, not at evaluation time, so the file never
        enters the Nix store. Set either this or sshProxy.hostKey; if both are
        set the file wins.

        Used by the sing-box backend. The XRay backend and a standalone tunnel
        pass knownHostsFile to OpenSSH instead.
      '';
      example = "/root/.ssh/known_hosts";
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
      description = ''
        Resolve destination domains locally before sending them through the
        SSH SOCKS5 proxy, so the remote SSH server never has to resolve them.
        Null preserves the backend's default behavior.

        Only applies to the XRay backend, which reaches the tunnel through the
        local SOCKS5 listener and maps this onto the outbound's
        `sockopt.domainStrategy`. SingBox and hybrid backends dial SSH natively
        and resolve destinations themselves, so this option is ignored there.

        Note that local resolution hands the remote server an address chosen by
        *this* machine's DNS. For anycast or geo-steered CDNs that address can
        be unreachable from the remote network, which surfaces as connection
        timeouts rather than as a DNS error. Prefer fixing DNS on the remote
        server if you have access to it.
      '';
      example = "prefer_ipv4";
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

        OpenSSH path only. A SingBox or hybrid backend verifies host keys with
        sshProxy.hostKey instead.
      '';
      example = "yes";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Additional arguments passed to OpenSSH before the destination.
        This can be used for options such as jump hosts or agent forwarding.

        OpenSSH path only: ignored when a SingBox or hybrid backend dials SSH
        natively. Keepalive, connect-timeout and restart behavior are already
        set by the module, so they do not need to be repeated here.
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
        Add the SSH tunnel as a proxy-suite outbound tagged "ssh-proxy".
        Requires proxy.enable and an active SingBox or XRay backend.

        How the tunnel is built depends on the backend. SingBox and hybrid
        backends dial SSH natively, with no systemd unit and no local SOCKS5
        listener. XRay has no SSH outbound, so it keeps the OpenSSH `ssh -D`
        unit and proxies through its local SOCKS5 listener. With
        asOutbound = false the OpenSSH unit is always used, since the tunnel is
        then a standalone listener the backends know nothing about.
      '';
      example = true;
    };
  };
}
