{ lib, ... }:

let
  p =
    path:
    [
      "services"
      "proxy-suite"
    ]
    ++ lib.splitString "." path;
in
{
  # The tray indicator became Proxy Suite GUI, which has the tray icon built in.
  imports = [
    (lib.mkRenamedOptionModule (p "tray.enable") (p "gui.enable"))
    (lib.mkRenamedOptionModule (p "tray.autostart") (p "gui.autostart"))
    (lib.mkRenamedOptionModule (p "tray.pollInterval") (p "gui.refreshInterval"))
  ];
}
