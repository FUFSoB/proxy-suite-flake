{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  domains = (import ./lib.nix { inherit lib; }).list;
in
{
  options.services.proxy-suite.tgWsProxy = {
    enable = mkEnableOption "the Telegram WebSocket proxy (MTProto)";

    listener = {
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Listening address.";
      };

      port = mkOption {
        type = types.port;
        default = 1443;
        description = "Listening port.";
      };
    };

    secret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "MTProto secret (`openssl rand -hex 16`). Ends up in the Nix store; prefer `secretFile`.";
      example = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    };

    secretFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "File with the MTProto secret.";
      example = "/run/secrets/tg-ws-proxy-secret";
    };

    dcIps = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Relay IP for each Telegram DC ID.";
      example = {
        "2" = "149.154.167.220";
      };
    };

    fakeTlsDomain = mkOption {
      type = types.nullOr (types.strMatching ".+");
      default = null;
      description = "Domain to disguise traffic as, with Fake TLS (ee-secret links).";
      example = "www.example.com";
    };

    cloudflare = {
      domains = domains "Domains behind Cloudflare to fall back to." [ "cdn.example.com" ];
      workerDomains = domains "Cloudflare Worker domains, tried first." [ "worker.example.com" ];

      fallback = mkOption {
        type = types.bool;
        default = true;
        description = "Fall back to Cloudflare when a direct WebSocket fails.";
      };
    };

    poolSize = mkOption {
      type = types.ints.unsigned;
      default = 4;
      description = "Idle WebSockets kept open per DC. 0 disables.";
    };

    bufferKiB = mkOption {
      type = types.ints.between 4 2147483647;
      default = 256;
      description = "Socket buffer size, in KiB.";
    };

    proxyProtocol = mkOption {
      type = types.bool;
      default = false;
      description = "Accept a PROXY protocol v1 header from a reverse proxy in front.";
    };

    bypassTransparentProxy = mkOption {
      type = types.bool;
      default = true;
      description = "Keep the relay's own connections out of TUN and TProxy, so they do not loop.";
    };

    fwmark = mkOption {
      type = types.int;
      default = 4;
      description = "Firewall mark for `bypassTransparentProxy`.";
    };

    log = {
      verbose = mkOption {
        type = types.bool;
        default = false;
        description = "Log debug messages.";
      };

      file = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Log file, rotated. `null`: log to the journal.";
        example = "/var/log/proxy-suite-tg-ws-proxy/tg-ws-proxy.log";
      };

      maxSizeMiB = mkOption {
        type = types.numbers.positive;
        default = 5.0;
        description = "Rotate the log at this size, in MiB.";
      };

      keep = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of rotated logs to keep.";
      };
    };
  };
}
