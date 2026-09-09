# Server-side inbound listener option type definitions.
{ lib }:

let
  inherit (lib) mkOption types;

  userType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        default = "";
        description = ''
          Optional label for this account. Used as the share-link fragment so
          clients show a readable server name, and as the XRay user email.
        '';
        example = "phone";
      };

      uuid = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Literal UUID for vless/vmess accounts.

          This value is embedded in the Nix store. Prefer uuidFile for real
          credentials.

          Set exactly one of uuid or uuidFile for vless and vmess listeners.
        '';
        example = "b831381d-6324-4d53-ad4f-8cda48b30811";
      };

      uuidFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the account UUID.
          Intended for use with secret managers (sops-nix, agenix, etc.).
          The file is read at service start time and never lands in the Nix store.
        '';
        example = "/run/secrets/proxy-inbound-uuid";
      };

      password = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Literal password for trojan, shadowsocks, socks, and http listeners.

          This value is embedded in the Nix store. Prefer passwordFile for real
          credentials.
        '';
        example = "hunter2";
      };

      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the account password.
          The file is read at service start time and never lands in the Nix store.
        '';
        example = "/run/secrets/proxy-inbound-password";
      };
    };
  };

  transportType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "raw"
          "ws"
          "grpc"
          "httpupgrade"
          "xhttp"
        ];
        default = "raw";
        description = ''
          Stream transport for this listener. "raw" is plain TCP and is what
          REALITY setups normally use.
        '';
        example = "ws";
      };

      path = mkOption {
        type = types.str;
        default = "/";
        description = ''
          Request path for the "ws", "httpupgrade", and "xhttp" transports.
          Ignored by the other transports.
        '';
        example = "/download";
      };

      host = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Expected Host header for the "ws", "httpupgrade", and "xhttp"
          transports. Leave null to accept any host.
        '';
        example = "cdn.example.com";
      };

      mode = mkOption {
        type = types.nullOr (
          types.enum [
            "auto"
            "packet-up"
            "stream-up"
            "stream-one"
          ]
        );
        default = null;
        description = ''
          Transfer mode for the "xhttp" transport. Ignored by the others.

          Leave null for XRay's own default, which lets the client choose.
          Behind an HTTP/1.1 reverse proxy, "packet-up" is the mode that works:
          "stream-one" needs a full-duplex HTTP/2 path from the client all the
          way to the listener, which a proxy speaking HTTP/1.1 upstream cannot
          provide.
        '';
        example = "packet-up";
      };

      serviceName = mkOption {
        type = types.str;
        default = "";
        description = ''
          gRPC service name for the "grpc" transport. Ignored otherwise.
        '';
        example = "GunService";
      };
    };
  };

  tlsType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Terminate TLS on this listener. Mutually exclusive with reality.

          Always on for trojan listeners regardless of this setting.
        '';
        example = true;
      };

      certificateFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to the PEM certificate chain. Compose with
          security.acme to keep it renewed.
        '';
        example = "/var/lib/acme/example.com/fullchain.pem";
      };

      keyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to the PEM private key matching certificateFile.
        '';
        example = "/var/lib/acme/example.com/key.pem";
      };

      serverName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          SNI advertised in generated share links. Defaults to
          proxyInbounds.serverAddress when unset.
        '';
        example = "example.com";
      };
    };
  };

  realityType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable REALITY on this listener. Mutually exclusive with tls.enable.
        '';
        example = true;
      };

      dest = mkOption {
        type = types.str;
        default = "www.microsoft.com:443";
        description = ''
          Real TLS server that unauthenticated probes are proxied to. Must be a
          host:port that serves TLS 1.3 with HTTP/2.
        '';
        example = "www.microsoft.com:443";
      };

      serverNames = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          SNI values accepted by this listener. These must be names the dest
          server actually serves. The first entry is used in share links.
        '';
        example = [ "www.microsoft.com" ];
      };

      privateKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to the REALITY x25519 private key, as produced by
          `xray x25519`. Read at service start time; never lands in the Nix
          store.
        '';
        example = "/run/secrets/proxy-inbound-reality-key";
      };

      privateKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Literal REALITY x25519 private key.

          This value is embedded in the Nix store. Prefer privateKeyFile.
        '';
        example = "gG1Yz...";
      };

      publicKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          REALITY x25519 public key matching privateKeyFile, as printed
          alongside it by `xray x25519`. Not a secret: clients need it, and it
          is what generated share links carry as `pbk`.

          Required when proxyInbounds.shareLinks is enabled.
        '';
        example = "jNXH...";
      };

      shortIds = mkOption {
        type = types.listOf types.str;
        default = [ "" ];
        description = ''
          Accepted REALITY short IDs (hex, up to 16 characters). The default
          accepts the empty short ID. The first entry is used in share links.
        '';
        example = [ "0123abcd" ];
      };
    };
  };

  inboundType = types.submodule {
    options = {
      type = mkOption {
        type = types.nullOr (types.enum [
          "vless"
          "vmess"
          "trojan"
          "shadowsocks"
          "socks"
          "http"
        ]);
        default = null;
        description = ''
          Proxy protocol served by this listener.

          Set exactly one of type, xrayJson, or jsonFile for each listener.
        '';
        example = "vless";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = ''
          Port this listener binds. Opened in the firewall automatically unless
          proxyInbounds.openFirewall is disabled.
        '';
        example = 443;
      };

      sharePort = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = ''
          Port generated share links advertise, for when clients do not reach
          this listener on the port it binds. Set it when something in front of
          it owns the public port: an nginx vhost proxying to a loopback bind,
          a container port mapping, a DNAT rule.

          Leave null to advertise port.
        '';
        example = 443;
      };

      listenAddress = mkOption {
        type = types.strMatching "[^[:space:]]+";
        default = "::";
        description = ''
          Address this listener binds. The default accepts both IPv4 and IPv6
          connections from anywhere.
        '';
        example = "0.0.0.0";
      };

      via = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Egress for traffic arriving on this listener: "proxy" (out through
          the local proxy stack, following its current selection), a
          proxy.outbounds tag (pinned to that specific server), "direct" (out
          from this machine), or "block".

          Give two listeners two different tags to have them leave through two
          different servers.

          Leave null to inherit proxyInbounds.via.
        '';
        example = "nl-vps";
      };

      users = mkOption {
        type = types.listOf userType;
        default = [ ];
        description = ''
          Accounts accepted by this listener. vless and vmess use uuid/uuidFile;
          trojan, shadowsocks, socks, and http use password/passwordFile.

          A share link is generated for the first user of each listener.
        '';
        example = [ { uuidFile = "/run/secrets/proxy-inbound-uuid"; } ];
      };

      flow = mkOption {
        type = types.nullOr (types.enum [ "xtls-rprx-vision" ]);
        default = null;
        description = ''
          VLESS flow control. "xtls-rprx-vision" is the usual pairing with
          REALITY on the "raw" transport; it is not valid over ws, grpc,
          httpupgrade, or xhttp.
        '';
        example = "xtls-rprx-vision";
      };

      method = mkOption {
        type = types.str;
        default = "2022-blake3-aes-128-gcm";
        description = ''
          Shadowsocks cipher. Ignored by other protocols.

          The 2022 ciphers require a base64 pre-shared key of the matching
          length as the password, not a passphrase.
        '';
        example = "aes-128-gcm";
      };

      transport = mkOption {
        type = transportType;
        default = { };
        description = ''
          Stream transport settings for this listener.
        '';
      };

      tls = mkOption {
        type = tlsType;
        default = { };
        description = ''
          TLS termination settings for this listener. Mutually exclusive with
          reality.
        '';
      };

      reality = mkOption {
        type = realityType;
        default = { };
        description = ''
          REALITY settings for this listener. Mutually exclusive with tls.
        '';
      };

      xrayJson = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = ''
          Raw XRay inbound configuration as a Nix attribute set, for protocols
          or options the typed fields do not cover. Embedded into the config at
          build time, so avoid putting credentials here; use jsonFile instead.
          The tag field is overridden by the listener name.

          Set exactly one of type, xrayJson, or jsonFile for each listener.
        '';
        example = {
          protocol = "dokodemo-door";
          settings = {
            address = "127.0.0.1";
            port = 8080;
          };
        };
      };

      jsonFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing a complete XRay inbound object as
          JSON. Read at service start time, so the whole inbound including its
          credentials can be rendered by a secret manager and never lands in
          the Nix store. The tag field is overridden by the listener name.

          No share link is generated for listeners defined this way.

          Set exactly one of type, xrayJson, or jsonFile for each listener.
        '';
        example = "/run/secrets/proxy-inbound-vless.json";
      };
    };
  };
in
{
  inherit inboundType;
}
