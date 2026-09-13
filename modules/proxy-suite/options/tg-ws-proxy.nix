{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  domains =
    description: example:
    mkOption {
      type = types.listOf types.str;
      default = [ ];
      inherit description example;
    };
in
{
  options.services.proxy-suite.tgWsProxy = {
    enable = mkEnableOption "the Telegram MTProto WebSocket proxy";

    listener = {
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Bind address.";
      };

      port = mkOption {
        type = types.port;
        default = 1443;
        description = "Listen port.";
      };
    };

    secret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Inline MTProto secret (`openssl rand -hex 16`). Ends up in the Nix store; prefer secretFile.";
      example = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    };

    secretFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Runtime path to the MTProto secret.";
      example = "/run/secrets/tg-ws-proxy-secret";
    };

    dcIps = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Relay IP per Telegram DC ID.";
      example = {
        "2" = "149.154.167.220";
      };
    };

    fakeTlsDomain = mkOption {
      type = types.nullOr (types.strMatching ".+");
      default = null;
      description = "SNI for Fake TLS masking (ee-secret links).";
      example = "www.example.com";
    };

    cloudflare = {
      domains = domains "Cloudflare-proxied domains for WebSocket fallback." [ "cdn.example.com" ];
      workerDomains = domains "Cloudflare Worker domains, tried first." [ "worker.example.com" ];

      fallback = mkOption {
        type = types.bool;
        default = true;
        description = "Fall back to Cloudflare when direct WebSocket fails.";
      };
    };

    poolSize = mkOption {
      type = types.ints.unsigned;
      default = 4;
      description = "WebSocket pool size per DC; 0 disables pooling.";
    };

    bufferKiB = mkOption {
      type = types.ints.between 4 2147483647;
      default = 256;
      description = "Socket buffer size, in KiB.";
    };

    proxyProtocol = mkOption {
      type = types.bool;
      default = false;
      description = "Accept a PROXY protocol v1 header from a fronting reverse proxy.";
    };

    bypassTransparentProxy = mkOption {
      type = types.bool;
      default = true;
      description = "Keep the relay's own connections out of TUN/TProxy, which would otherwise loop them.";
    };

    fwmark = mkOption {
      type = types.int;
      default = 4;
      description = "Packet mark bypassTransparentProxy uses.";
    };

    log = {
      verbose = mkOption {
        type = types.bool;
        default = false;
        description = "Debug logging.";
      };

      file = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Rotating log file. Null logs to stderr.";
        example = "/var/log/tg-ws-proxy.log";
      };

      maxSizeMiB = mkOption {
        type = types.numbers.positive;
        default = 5.0;
        description = "Log size before rotation, in MiB.";
      };

      keep = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Rotated logs kept.";
      };
    };
  };
}
