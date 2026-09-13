{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.proxy-suite.tray = {
    enable = mkEnableOption "the system tray indicator";

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = "Start the tray in graphical sessions (XDG autostart).";
    };

    pollInterval = mkOption {
      type = types.ints.positive;
      default = 5;
      description = "Status refresh interval, in seconds.";
    };
  };
}
