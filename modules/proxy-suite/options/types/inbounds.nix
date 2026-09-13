{ lib }:

let
  inherit (lib) mkOption types;
  nullStr =
    description: example:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      inherit description example;
    };

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

  inboundType = types.submodule {
    options = {
      type = mkOption {
        type = types.nullOr (
          types.enum [
            "vless"
            "vmess"
            "trojan"
            "shadowsocks"
            "socks"
            "http"
          ]
        );
        default = null;
        description = "Protocol. Set exactly one of type, xrayJson, or jsonFile.";
        example = "vless";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Bound port.";
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
        description = "Shadowsocks cipher. 2022 ciphers take a base64 key of matching length as password.";
        example = "aes-128-gcm";
      };

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

      xrayJson = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "Raw XRay inbound, built into the store; tag is overridden.";
        example = {
          protocol = "dokodemo-door";
          settings.port = 8080;
        };
      };

      jsonFile = nullStr "Runtime path to a raw XRay inbound (no share link); tag is overridden." "/run/secrets/proxy-inbound-vless.json";
    };
  };
in
{
  inherit inboundType;
}
