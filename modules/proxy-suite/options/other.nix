# Top-level, userControl, tray, and tgWsProxy options.
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.services.proxy-suite = {
    enable = mkEnableOption "proxy suite (sing-box + zapret + tg-ws-proxy)";

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

      global.enable =
        (mkEnableOption "passwordless proxy-ctl control over global proxy-suite units")
        // {
          default = true;
          description = ''
            Whether members of userControl.group may manage global
            proxy-suite units without password prompts via commands like
            `proxy-ctl tun on|off`, `proxy-ctl tproxy on|off`,
            `proxy-ctl restart`, or `proxy-ctl subscription update`.
          '';
        };

      perApp.enable =
        (mkEnableOption "passwordless proxy-ctl control over per-app routing helpers")
        // {
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
        default = 1076;
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
    };
  };
}
