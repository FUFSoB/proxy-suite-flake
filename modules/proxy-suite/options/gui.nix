{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.proxy-suite.gui = {
    enable = mkEnableOption "Proxy Suite GUI, a desktop app with a tray icon";

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start the GUI in the tray on login to a graphical session.
      '';
    };

    refreshInterval = mkOption {
      type = types.ints.positive;
      default = 3;
      description = "How often the status refreshes, in seconds.";
    };

    floating = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the window floating, sized to the screen, where a tiling compositor (niri, sway,
        Hyprland, i3) would tile it. It opens at a fixed size, which those compositors float,
        then resizes as usual. Turn off to let the compositor tile it.
      '';
    };
  };
}
