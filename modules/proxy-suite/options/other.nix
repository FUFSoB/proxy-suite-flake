# Top-level, userControl, tray, and tgWsProxy options.
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.services.proxy-suite = {
    enable = mkEnableOption "proxy suite (proxy backend + zapret + tg-ws-proxy)";

    userControl = {
      group = mkOption {
        type = types.strMatching "^[a-z_][a-z0-9_-]*$";
        default = "proxy-suite";
        description = ''
          Local group allowed to use passwordless polkit-backed `proxy-ctl`
          commands when userControl.global.enable or userControl.perApp.enable
          is turned on.
        '';
        example = "proxy-suite";
      };

      global.enable = (mkEnableOption "passwordless proxy-ctl control over global proxy-suite units") // {
        default = true;
        description = ''
          Whether members of userControl.group may manage global
          proxy-suite units without password prompts via commands like
          `proxy-ctl tun on|off`, `proxy-ctl tproxy on|off`,
          `proxy-ctl restart`, or `proxy-ctl subscription update`.
        '';
      };

      perApp.enable = (mkEnableOption "passwordless proxy-ctl control over per-app routing helpers") // {
        default = true;
        description = ''
          Whether members of userControl.group may start and stop the
          app-scoped backend units used by `proxy-ctl wrap ...` for
          route = "tun", route = "tproxy", or route = "zapret" profiles
          without password prompts.
        '';
      };
    };

    tray = {
      enable = mkEnableOption "system tray indicator for proxy-suite";

      pollInterval = mkOption {
        type = types.int;
        default = 5;
        description = ''
          Tray status refresh interval in seconds.
          Lower values make UI state changes appear faster, while higher values
          reduce background polling overhead.
        '';
        example = 5;
      };

      autostart = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to install an XDG autostart entry for the tray application
          for graphical users.
        '';
        example = true;
      };
    };

    tgWsProxy = {
      enable = mkEnableOption "Telegram MTProto WebSocket proxy";

      port = mkOption {
        type = types.port;
        default = 1443;
        description = ''
          TCP listen port for tg-ws-proxy.
          Telegram clients connect to this endpoint when using the local MTProto
          WebSocket proxy.
        '';
        example = 1076;
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Bind address for tg-ws-proxy.
          Keep `127.0.0.1` for local-only usage; bind to `0.0.0.0` only when you
          intentionally expose the proxy to other hosts.
        '';
        example = "127.0.0.1";
      };

      secret = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          MTProto proxy secret (hex string). Legacy inline form; this value ends up
          in the Nix store. Prefer secretFile for real deployments.

          Set exactly one of secret or secretFile when tgWsProxy.enable = true.
          Generate one with: openssl rand -hex 16
        '';
        example = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };

      secretFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the MTProto proxy secret.
          Intended for use with secret managers so the secret stays out of the Nix store.

          Set exactly one of secretFile or secret when tgWsProxy.enable = true.
        '';
        example = "/run/secrets/tg-ws-proxy-secret";
      };

      dcIps = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Mapping of Telegram DC IDs to relay IPs.
          Keys are DC IDs as strings and values are IPv4/IPv6 addresses used by
          tg-ws-proxy for MTProto relay selection.
        '';
        example = {
          "2" = "149.154.167.220";
          "4" = "149.154.167.220";
          "203" = "149.154.167.220";
        };
      };

      verbose = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable debug logging in tg-ws-proxy.
        '';
        example = true;
      };

      logFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Optional path where tg-ws-proxy writes rotating logs.
          When unset, tg-ws-proxy logs to stderr only.
        '';
        example = "/var/log/tg-ws-proxy.log";
      };

      logMaxMb = mkOption {
        type = types.numbers.positive;
        default = 5.0;
        description = ''
          Maximum tg-ws-proxy log file size in MiB before rotation.
          Only used when tgWsProxy.logFile is set.
        '';
        example = 10.0;
      };

      logBackups = mkOption {
        type = types.ints.positive;
        default = 1;
        description = ''
          Number of rotated tg-ws-proxy log files to keep.
          Only used when tgWsProxy.logFile is set.
        '';
        example = 3;
      };

      bufKb = mkOption {
        type = types.ints.between 4 2147483647;
        default = 256;
        description = ''
          Socket send and receive buffer size for tg-ws-proxy, in KiB.
        '';
        example = 512;
      };

      poolSize = mkOption {
        type = types.ints.unsigned;
        default = 4;
        description = ''
          WebSocket connection pool size per Telegram DC.
          Set to 0 to disable connection pooling.
        '';
        example = 8;
      };

      cfProxyDomains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          User-defined Cloudflare-proxied domains used by tg-ws-proxy for
          WebSocket fallback. Each entry is passed as a separate
          --cfproxy-domain argument.
        '';
        example = [
          "cdn.example.com"
          "edge.example.net"
        ];
      };

      cfProxyWorkerDomains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Cloudflare Worker domains used by tg-ws-proxy for WebSocket fallback.
          These are tried before other fallback methods.
        '';
        example = [ "worker.example.com" ];
      };

      cfProxyFallback = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to allow tg-ws-proxy to use Cloudflare proxy fallback when
          direct WebSocket routing is unavailable.
        '';
        example = false;
      };

      fakeTlsDomain = mkOption {
        type = types.nullOr (types.strMatching ".+");
        default = null;
        description = ''
          Optional SNI domain used to enable tg-ws-proxy Fake TLS masking.
          When set, tg-ws-proxy emits an ee-secret connection link.
        '';
        example = "www.example.com";
      };

      proxyProtocol = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether tg-ws-proxy should accept a PROXY protocol v1 header from a
          fronting reverse proxy such as nginx or HAProxy.
        '';
        example = true;
      };

      bypassTransparentProxy = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to keep tg-ws-proxy's own relay connections out of proxy-suite
          transparent routing backends.

          When enabled and global TUN or TProxy mode is configured, the
          tg-ws-proxy systemd service receives a packet mark and an earlier
          policy-routing rule back to the main table. This prevents global TUN
          from routing the local Telegram MTProto relay through the proxy backend again,
          which can otherwise break tg-ws-proxy after enabling TUN mode.
        '';
        example = true;
      };

      routingMark = mkOption {
        type = types.int;
        default = 4;
        description = ''
          Packet mark used by tgWsProxy.bypassTransparentProxy to bypass
          proxy-suite transparent routing. Override this only if it collides
          with another local policy-routing mark on your host.
        '';
        example = 4;
      };
    };
  };
}
