{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.proxy-suite.gui = {
    enable = mkEnableOption "Proxy Suite GUI, a desktop app with a tray icon for everything proxy-ctl controls at runtime";

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start the GUI hidden in the tray with graphical sessions, as the
        `proxy-suite-gui` systemd user unit on `graphical-session.target`.
      '';
    };

    refreshInterval = mkOption {
      type = types.ints.positive;
      default = 3;
      description = "Status refresh interval, in seconds.";
    };
  };
}
