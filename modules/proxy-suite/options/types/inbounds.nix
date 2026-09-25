{ lib }:

let
  inherit (lib) mkOption types;
  inherit (import ./amnezia-wg.nix { inherit lib; }) obfuscationType;
  inherit (import ../lib.nix { inherit lib; }) nullStr;

  userType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        default = "";
        description = "Account label: the share link's name, and what subscriptions and stats group by.";
        example = "phone";
      };
      uuid = nullStr "UUID (vless, vmess). Ends up in the Nix store; prefer uuidFile." "b831381d-6324-4d53-ad4f-8cda48b30811";
      uuidFile = nullStr "Runtime path to the UUID." "/run/secrets/proxy-inbound-uuid";
      password = nullStr "Password (trojan, shadowsocks, socks, http). Ends up in the Nix store; prefer passwordFile." "hunter2";
      passwordFile = nullStr "Runtime path to the password." "/run/secrets/proxy-inbound-password";

      publicKey = nullStr ''
        AmneziaWG public key of a peer that keeps its private key to itself. It gets no client
        config or link. Null generates a key pair, kept in the state directory.
      '' "jNXH...";
      privateKeyFile = nullStr "Runtime path to the AmneziaWG client private key, instead of a generated one." "/run/secrets/awg-phone-key";
      presharedKeyFile = nullStr "Runtime path to the AmneziaWG preshared key, instead of a generated one." "/run/secrets/awg-phone-psk";
      address = nullStr ''
        AmneziaWG tunnel IPv4 address, inside amneziaWg.subnet. Null takes the lowest free one, which
        the user keeps for as long as it exists.
      '' "10.66.0.10";
    };
  };

  # The listener's tag names the default interface; a submodule's own name is its option's.
  mkAmneziaWgType =
    tag:
    types.submodule {
      options = {
        mode = mkOption {
          type = types.enum [
            "proxy"
            "lan"
          ];
          default = "proxy";
          description = ''
            What clients reach besides the internet, which they reach the listener's `via` way either way:
            - "proxy": nothing else. This host, its private networks and the other peers are cut off.
            - "lan": also this host, its private networks and the other peers, directly (masqueraded
              behind this host), not through `via`. It turns on IP forwarding.
            Only TCP and UDP can follow `via`: anything else to the internet (ping) is dropped.
          '';
        };

        interfaceName = mkOption {
          type = types.strMatching "^[A-Za-z0-9_.-]+$";
          default = "awgi-${tag}";
          defaultText = lib.literalExpression ''"awgi-<tag>"'';
          description = "Linux interface name. It must fit Linux's 15-character limit.";
        };

        subnet = mkOption {
          type = types.strMatching "[0-9.]+/[0-9]+";
          default = "10.66.0.0/24";
          description = ''
            Tunnel IPv4 subnet, private and unused elsewhere. This host takes the first address, clients
            the rest.
          '';
        };

        subnet6 = nullStr ''
          Tunnel IPv6 subnet (ULA), laid out as subnet. Null keeps the tunnel IPv4-only. With mode = "lan"
          it turns on IPv6 forwarding, which stops this host configuring itself from router advertisements.
        '' "fd66:66::/64";

        privateKeyFile = nullStr "Runtime path to the server private key, instead of a generated one." "/run/secrets/awg-server-key";

        obfuscation = mkOption {
          type = obfuscationType;
          default = { };
          description = ''
            Obfuscation parameters, shared with every client. Jc, Jmin, Jmax, S1, S2 and H1-H4 left
            null are generated once and kept in the state directory; the rest stay unset.
          '';
        };

        dns = mkOption {
          type = types.listOf types.str;
          default = [
            "1.1.1.1"
            "1.0.0.1"
          ];
          description = "DNS servers in client configs. Queries leave like any other traffic.";
        };

        mtu = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = null;
          description = "Interface MTU, on both ends. Null leaves awg-quick's (1280 with AWG 3 fields).";
        };

        persistentKeepalive = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = 25;
          description = "PersistentKeepalive in client configs, which keeps NAT mappings open.";
        };

        clientAllowedIPs = mkOption {
          type = types.listOf types.str;
          default = [
            "0.0.0.0/0"
            "::/0"
          ];
          description = "AllowedIPs in client configs: what clients send through the tunnel.";
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
        description = ''Stream transport. "raw" is plain TCP, the usual choice for REALITY.'';
        example = "ws";
      };

      path = mkOption {
        type = types.str;
        default = "/";
        description = "Request path (ws, httpupgrade, xhttp).";
        example = "/download";
      };

      host = nullStr "Expected Host header (ws, httpupgrade, xhttp). Null accepts any." "cdn.example.com";

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
        description = ''xhttp mode. Null lets the client choose; behind an HTTP/1.1 proxy use "packet-up".'';
        example = "packet-up";
      };

      serviceName = mkOption {
        type = types.str;
        default = "";
        description = "gRPC service name.";
        example = "GunService";
      };

      trustedXForwardedFor = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Header names that mark a request as coming from the web server in front (ws, httpupgrade,
          xhttp, grpc). When one of them is present, XRay takes the client address from
          "X-Forwarded-For" instead of the socket. Needed for a listener on a loopback `address`:
          XRay otherwise sees 127.0.0.1, which it refuses to record, so `proxy-ctl inbounds online`
          shows every user as never seen and the stats keep no last-seen time.

          Set it only when the web server in front sets both the named header and "X-Forwarded-For"
          on every request it forwards, overwriting whatever the client sent: any client that can
          reach the listener directly could otherwise claim any address.
        '';
        example = [ "X-Real-IP" ];
      };
    };
  };

  tlsType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Terminate TLS (always on for trojan). Exclusive with reality.";
      };
      certificateFile = nullStr "Runtime path to the PEM certificate chain." "/var/lib/acme/example.com/fullchain.pem";
      keyFile = nullStr "Runtime path to the PEM private key." "/var/lib/acme/example.com/key.pem";
      serverName = nullStr "SNI in share links. Defaults to inbounds.serverAddress." "example.com";

      alpn = mkOption {
        type = types.nullOr (
          types.listOf (
            types.enum [
              "h3"
              "h2"
              "http/1.1"
            ]
          )
        );
        default = null;
        description = ''
          ALPN offered and put in share links. [ "h3" ] alone makes an xhttp listener UDP-only, so
          a web server can keep the TCP port.
        '';
        example = [ "h3" ];
      };
    };
  };

  realityType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable REALITY. Exclusive with tls.";
      };

      dest = mkOption {
        type = types.str;
        default = "www.microsoft.com:443";
        description = "TLS 1.3 + HTTP/2 server that unauthenticated probes are forwarded to.";
      };

      serverNames = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Accepted SNIs, served by dest. The first goes into share links.";
        example = [ "www.microsoft.com" ];
      };

      privateKeyFile = nullStr "Runtime path to the x25519 private key (`xray x25519`)." "/run/secrets/proxy-inbound-reality-key";
      privateKey = nullStr "x25519 private key. Ends up in the Nix store; prefer privateKeyFile." "gG1Yz...";
      publicKey = nullStr "x25519 public key, required for share links." "jNXH...";

      shortIds = mkOption {
        type = types.listOf types.str;
        default = [ "" ];
        description = "Accepted short IDs (hex). The first goes into share links.";
        example = [ "0123abcd" ];
      };
    };
  };

  fallbackType = types.submodule {
    options = {
      name = nullStr "SNI to match. Null matches any." "www.example.com";

      alpn = mkOption {
        type = types.nullOr (
          types.enum [
            "h2"
            "http/1.1"
          ]
        );
        default = null;
        description = "Negotiated ALPN to match. Null matches any.";
        example = "h2";
      };

      path = nullStr ''
        Request path to match. Null matches any. XRay reads it from HTTP/1.1 only, so a `listener`
        must be on ws or httpupgrade, with this as its transport.path; xhttp and grpc clients speak h2
        and go by alpn = "h2" or a catch-all instead.
      '' "/ws";

      dest = mkOption {
        type = types.nullOr (types.either types.port types.str);
        default = null;
        description = "Where matching connections go: a port, host:port, or a unix socket path. Exclusive with listener.";
        example = "127.0.0.1:8080";
      };

      listener = nullStr ''
        Tag of another listener that matching connections go to, instead of dest. It must be a
        vless listener without tls or reality, on a loopback address: it gets the connection
        decrypted, with the client address in PROXY protocol, and its share links advertise this
        listener's port and TLS or REALITY. Behind REALITY it must be xhttp or grpc, the only
        transports REALITY clients run besides raw.
      '' "ws-in";

      xver = mkOption {
        type = types.enum [
          0
          1
          2
        ];
        default = 0;
        description = "PROXY protocol version sent to dest; 0 sends none. A listener always gets 2.";
      };
    };
  };

  inboundType = types.submodule (
    { name, ... }:
    {
      options = {
        type = mkOption {
          type = types.nullOr (
            types.enum [
              "vless"
              "vmess"
              "trojan"
              "hysteria2"
              "shadowsocks"
              "socks"
              "http"
              "amneziawg"
            ]
          );
          default = null;
          description = ''
            Protocol. Set exactly one of type, xrayJson, or jsonFile. "amneziawg" is an AmneziaWG
            server on UDP port, with its own interface (see amneziaWg); its traffic is handed to XRay
            and leaves like any other listener's. "hysteria2" is QUIC on UDP port: it needs tls (a
            certificate) and takes passwords, and no transport, reality or flow.
          '';
          example = "vless";
        };

        port = mkOption {
          type = types.port;
          default = 443;
          description = "Bound port. A raw-JSON listener's port must match it: the firewall and the port checks go by this one.";
        };

        sharePort = mkOption {
          type = types.nullOr types.port;
          default = null;
          description = "Port share links advertise, when something in front owns the public port. Null uses port.";
          example = 443;
        };

        address = mkOption {
          type = types.strMatching "[^[:space:]]+";
          default = "::";
          description = "Bound address. A loopback address keeps the port closed in the firewall.";
          example = "127.0.0.1";
        };

        via = nullStr "Egress, as in inbounds.routing.via. Null inherits it." "nl-vps";

        users = mkOption {
          type = types.listOf userType;
          default = [ ];
          description = "Accepted accounts.";
          example = [ { uuidFile = "/run/secrets/proxy-inbound-uuid"; } ];
        };

        flow = mkOption {
          type = types.nullOr (types.enum [ "xtls-rprx-vision" ]);
          default = null;
          description = "VLESS flow; raw transport only.";
          example = "xtls-rprx-vision";
        };

        method = mkOption {
          type = types.str;
          default = "2022-blake3-aes-128-gcm";
          description = "Shadowsocks cipher. 2022 ciphers take a base64 key of matching length as password; more than one user needs a 2022-blake3-aes cipher and serverPassword.";
          example = "aes-128-gcm";
        };

        serverPassword = nullStr "Server key of a multi-user shadowsocks 2022 listener, shared by its users. Ends up in the Nix store; prefer serverPasswordFile." "c2VydmVyLWtleS0xNmJ5dGU=";
        serverPasswordFile = nullStr "Runtime path to the server key." "/run/secrets/proxy-inbound-ss-server-key";

        transport = mkOption {
          type = transportType;
          default = { };
          description = "Stream transport.";
        };

        tls = mkOption {
          type = tlsType;
          default = { };
          description = "TLS termination.";
        };

        reality = mkOption {
          type = realityType;
          default = { };
          description = "REALITY.";
        };

        fallbacks = mkOption {
          type = types.listOf fallbackType;
          default = [ ];
          description = ''
            Where XRay sends connections that are not this listener's protocol, so several share
            one port (vless or trojan on the raw transport). Matched in order on SNI, ALPN and path;
            the first entry without any is the catch-all, such as a decoy web server. Browsers
            negotiate h2 unless tls.alpn says otherwise, so a dest that speaks only HTTP/1.1 needs
            tls.alpn = [ "http/1.1" ], or an alpn = "h2" entry to one that speaks h2c.
          '';
          example = lib.literalExpression ''
            [
              { path = "/ws"; listener = "ws-in"; }  # ws-in: vless, ws, address = "127.0.0.1"
              { dest = 8080; }
            ]
          '';
        };

        xrayJson = mkOption {
          type = types.nullOr types.attrs;
          default = null;
          description = "Raw XRay inbound, built into the store; tag is overridden and port, if left out, filled in.";
          example = {
            protocol = "dokodemo-door";
            settings.port = 8080;
          };
        };

        jsonFile = nullStr "Runtime path to a raw XRay inbound (no share link); tag is overridden and port, if left out, filled in." "/run/secrets/proxy-inbound-vless.json";

        hysteria.masquerade = nullStr ''
          Site that a hysteria2 listener serves, reverse-proxied, to anything that is not a client
          (a browser, a prober). Null answers them with 404.
        '' "https://www.example.com";

        amneziaWg = mkOption {
          type = mkAmneziaWgType name;
          default = { };
          description = ''The AmneziaWG server of a type = "amneziawg" listener.'';
        };
      };
    }
  );
in
{
  inherit inboundType;
}
