# Miscellaneous top-level proxy-suite options.
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;

  tgWsProxyOptions = import ./other/tg-ws-proxy.nix { inherit lib; };

  userControlOptions = {
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
  };

  trayOptions = {
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
  };
in
{
  options.services.proxy-suite = {
    enable = lib.mkEnableOption "proxy suite (proxy backend + AmneziaWG + zapret + tg-ws-proxy)";
  }
  // userControlOptions
  // trayOptions
  // tgWsProxyOptions;
}
