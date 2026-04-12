# Tray indicator module for proxy-suite
{
  config,
  lib,
  pkgs,
  cfg,
}:

let
  tray = cfg.tray;

  proxyTray = import ../../pkgs/proxy-suite-tray.nix {
    inherit pkgs;
    pollInterval = tray.pollInterval;
  };

  desktopEntryText = ''
    [Desktop Entry]
    Type=Application
    Version=1.0
    Name=Proxy Suite Tray
    Comment=System tray indicator for proxy-suite
    Exec=${proxyTray}/bin/proxy-suite-tray
    Icon=network-vpn
    Categories=Network;System;
    StartupNotify=false
    Terminal=false
  '';

  desktopEntry = pkgs.writeTextFile {
    name = "proxy-suite-tray.desktop";
    destination = "/share/applications/proxy-suite-tray.desktop";
    text = desktopEntryText;
  };

  autostartEntry = pkgs.writeTextFile {
    name = "proxy-suite-tray-autostart.desktop";
    destination = "/share/xdg/autostart/proxy-suite-tray.desktop";
    text = ''
      ${desktopEntryText}
      X-GNOME-Autostart-enabled=true
    '';
  };
in
{
  environment.systemPackages = [
    proxyTray
    desktopEntry
  ];

  environment.etc = lib.mkIf tray.autostart {
    "xdg/autostart/proxy-suite-tray.desktop".source =
      "${autostartEntry}/share/xdg/autostart/proxy-suite-tray.desktop";
  };
}
