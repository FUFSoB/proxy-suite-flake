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
        description = "User name, shown in share links, subscriptions and stats.";
        example = "phone";
      };
      uuid = nullStr "UUID (vless, vmess). Ends up in the Nix store; prefer `uuidFile`." "b831381d-6324-4d53-ad4f-8cda48b30811";
      uuidFile = nullStr "File with the UUID." "/run/secrets/proxy-inbound-uuid";
      password = nullStr "Password (trojan, shadowsocks, socks, http). Ends up in the Nix store; prefer `passwordFile`." "hunter2";
      passwordFile = nullStr "File with the password." "/run/secrets/proxy-inbound-password";

      publicKey = nullStr ''
        AmneziaWG public key, for a client that keeps its own private key (no config or link is
        generated for it). `null`: generate a key pair.
      '' "jNXH...";
      privateKeyFile = nullStr "File with the AmneziaWG client private key, instead of a generated one." "/run/secrets/awg-phone-key";
      presharedKeyFile = nullStr "File with the AmneziaWG preshared key, instead of a generated one." "/run/secrets/awg-phone-psk";
      address = nullStr ''
        AmneziaWG tunnel IPv4 address, inside `amneziaWg.subnet`. `null`: the lowest free one,
        kept for as long as the user exists.
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
            What clients can reach besides the internet, which always goes through the listener's `via`:
            - "proxy": nothing else. This host, its LAN and other peers are cut off.
            - "lan": also this host, its LAN and other peers, directly. Turns on IP forwarding.
            Only TCP and UDP reach the internet; ping and other protocols are dropped.
          '';
        };

        interfaceName = mkOption {
          type = types.strMatching "^[A-Za-z0-9_.-]+$";
          default = "awgi-${tag}";
          defaultText = lib.literalExpression ''"awgi-<tag>"'';
          description = "Interface name, at most 15 characters.";
        };

        subnet = mkOption {
          type = types.strMatching "[0-9.]+/[0-9]+";
          default = "10.66.0.0/24";
          description = ''
            Tunnel IPv4 subnet, private and unused elsewhere. This host takes the first address,
            clients the rest.
          '';
        };

        subnet6 = nullStr ''
          Tunnel IPv6 subnet (ULA). `null`: IPv4 only. With `mode = "lan"` it turns on IPv6
          forwarding, which stops this host from configuring itself from router advertisements.
        '' "fd66:66::/64";

        privateKeyFile = nullStr "File with the server private key, instead of a generated one." "/run/secrets/awg-server-key";

        obfuscation = mkOption {
          type = obfuscationType;
          default = { };
          description = ''
            Obfuscation parameters, shared with every client. Jc, Jmin, Jmax, S1, S2 and H1-H4 are
            generated once if left `null`; the rest stay unset.
          '';
        };

        dns = mkOption {
          type = types.listOf types.str;
          default = [
            "1.1.1.1"
            "1.0.0.1"
          ];
          description = "DNS servers in client configs. Queries exit like any other traffic.";
        };

        mtu = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = null;
          description = "Interface MTU on both ends. `null`: awg-quick's default (1280 with AWG 3 fields).";
        };

        persistentKeepalive = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = 25;
          description = "PersistentKeepalive in client configs, which keeps NAT open.";
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
        description = ''Stream transport. "raw" is plain TCP, the usual pick for REALITY.'';
        example = "ws";
      };

      path = mkOption {
        type = types.str;
        default = "/";
        description = "Request path (ws, httpupgrade, xhttp).";
        example = "/download";
      };

      host = nullStr "Expected Host header (ws, httpupgrade, xhttp). `null`: any." "cdn.example.com";

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
        description = ''xhttp mode. `null`: the client chooses. Behind an HTTP/1.1 proxy, use "packet-up".'';
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
          Headers that mark a request as coming from your web server (ws, httpupgrade, xhttp,
          grpc). If one is present, XRay takes the client address from "X-Forwarded-For". Needed
          behind a web server on loopback, or `proxy-ctl inbounds online` and the stats show no
          client addresses.

          Only set it if the web server overwrites both headers on every request. Otherwise any
          client that reaches the listener directly can fake its address.
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
        description = "Terminate TLS (always on for trojan). Cannot be used with `reality`.";
      };
      certificateFile = nullStr "File with the PEM certificate chain." "/var/lib/acme/example.com/fullchain.pem";
      keyFile = nullStr "File with the PEM private key." "/var/lib/acme/example.com/key.pem";
      serverName = nullStr "SNI in share links. Defaults to `inbounds.serverAddress`." "example.com";

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
          ALPN offered and put in share links. `[ "h3" ]` alone makes an xhttp listener UDP-only,
          leaving the TCP port to a web server.
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
        description = "Enable REALITY. Cannot be used with `tls`.";
      };

      dest = mkOption {
        type = types.str;
        default = "www.microsoft.com:443";
        description = "Real TLS 1.3 + HTTP/2 site that non-client connections are forwarded to.";
      };

      serverNames = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Accepted SNIs, served by `dest`. The first goes into share links.";
        example = [ "www.microsoft.com" ];
      };

      privateKeyFile = nullStr "File with the x25519 private key (from `xray x25519`)." "/run/secrets/proxy-inbound-reality-key";
      privateKey = nullStr "x25519 private key. Ends up in the Nix store; prefer `privateKeyFile`." "gG1Yz...";
      publicKey = nullStr "x25519 public key, needed for share links." "jNXH...";

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
      name = nullStr "SNI to match. `null`: any." "www.example.com";

      alpn = mkOption {
        type = types.nullOr (
          types.enum [
            "h2"
            "http/1.1"
          ]
        );
        default = null;
        description = "ALPN to match. `null`: any.";
        example = "h2";
      };

      path = nullStr ''
        Request path to match. `null`: any. Works for HTTP/1.1 only, so the target `listener` must
        use ws or httpupgrade with this as its `transport.path`. For xhttp and grpc (h2), match
        `alpn = "h2"` or use a catch-all.
      '' "/ws";

      dest = mkOption {
        type = types.nullOr (types.either types.port types.str);
        default = null;
        description = "Where matching connections go: a port, host:port or unix socket path. Cannot be used with `listener`.";
        example = "127.0.0.1:8080";
      };

      listener = nullStr ''
        Another listener to hand matching connections to, instead of `dest`. It must be a vless
        listener on loopback, without tls or reality. It gets decrypted traffic, and its share
        links use this listener's port and TLS or REALITY. Behind REALITY it must use xhttp or grpc.
      '' "ws-in";

      xver = mkOption {
        type = types.enum [
          0
          1
          2
        ];
        default = 0;
        description = "PROXY protocol version sent to `dest`, or 0 for none. A `listener` always gets 2.";
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
            Protocol. Set exactly one of `type`, `xrayJson` or `jsonFile`.
            - "amneziawg": an AmneziaWG server on a UDP port (see `amneziaWg`). Its traffic exits
              like any other listener's.
            - "hysteria2": QUIC on a UDP port. Needs `tls` and passwords; no transport, reality or flow.
          '';
          example = "vless";
        };

        port = mkOption {
          type = types.port;
          default = 443;
          description = "Listening port. For raw JSON listeners it must match the JSON; the firewall uses this one.";
        };

        sharePort = mkOption {
          type = types.nullOr types.port;
          default = null;
          description = "Port in share links, if something in front owns the public port. `null`: `port`.";
          example = 443;
        };

        address = mkOption {
          type = types.strMatching "[^[:space:]]+";
          default = "::";
          description = "Listening address. A loopback address keeps the port closed in the firewall.";
          example = "127.0.0.1";
        };

        via = nullStr "Where this listener's traffic exits, as in `inbounds.routing.via`. `null`: use that default." "nl-vps";

        users = mkOption {
          type = types.listOf userType;
          default = [ ];
          description = "Accepted users.";
          example = [ { uuidFile = "/run/secrets/proxy-inbound-uuid"; } ];
        };

        flow = mkOption {
          type = types.nullOr (types.enum [ "xtls-rprx-vision" ]);
          default = null;
          description = "VLESS flow. Raw transport only.";
          example = "xtls-rprx-vision";
        };

        method = mkOption {
          type = types.str;
          default = "2022-blake3-aes-128-gcm";
          description = "Shadowsocks cipher. 2022 ciphers take a base64 key of matching length as the password. Multiple users need a 2022-blake3-aes cipher and `serverPassword`.";
          example = "aes-128-gcm";
        };

        serverPassword = nullStr "Shared server key of a multi-user shadowsocks 2022 listener. Ends up in the Nix store; prefer `serverPasswordFile`." "c2VydmVyLWtleS0xNmJ5dGU=";
        serverPasswordFile = nullStr "File with the server key." "/run/secrets/proxy-inbound-ss-server-key";

        transport = mkOption {
          type = transportType;
          default = { };
          description = "Transport settings.";
        };

        tls = mkOption {
          type = tlsType;
          default = { };
          description = "TLS settings.";
        };

        reality = mkOption {
          type = realityType;
          default = { };
          description = "REALITY settings.";
        };

        fallbacks = mkOption {
          type = types.listOf fallbackType;
          default = [ ];
          description = ''
            Where to send connections that are not this listener's protocol, so several services
            share one port (vless or trojan on raw transport). Entries match in order by SNI, ALPN
            and path; one with none of these is the catch-all, such as a decoy site. Browsers use h2
            by default, so an HTTP/1.1-only `dest` needs `tls.alpn = [ "http/1.1" ]`.
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
          description = "Raw XRay inbound JSON (ends up in the Nix store). Its tag is replaced; a missing port is filled in.";
          example = {
            protocol = "dokodemo-door";
            settings.port = 8080;
          };
        };

        jsonFile = nullStr "File with a raw XRay inbound JSON (no share link). Its tag is replaced; a missing port is filled in." "/run/secrets/proxy-inbound-vless.json";

        hysteria.masquerade = nullStr ''
          Site shown to anything that is not a hysteria2 client, such as browsers and probes.
          `null`: answer 404.
        '' "https://www.example.com";

        amneziaWg = mkOption {
          type = mkAmneziaWgType name;
          default = { };
          description = ''AmneziaWG server settings, for `type = "amneziawg"`.'';
        };
      };
    }
  );
in
{
  inherit inboundType;
}
