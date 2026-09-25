{ lib, ... }:
{
  options.services.proxy-suite.tui.enable = lib.mkEnableOption "proxy-tui, a terminal UI" // {
    default = true;
  };
}
