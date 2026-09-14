{ lib, ... }:
{
  options.services.proxy-suite.tui.enable =
    lib.mkEnableOption "proxy-tui, an interactive terminal UI for everything proxy-ctl controls at runtime"
    // {
      default = true;
    };
}
