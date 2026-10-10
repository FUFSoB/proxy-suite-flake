# services.proxy-suite.gui

The desktop app with a tray icon.

Part of the [proxy-suite options reference](./index.md).

## Options

- gui
  - [enable](#services-proxy-suite-gui-enable)
  - [autostart](#services-proxy-suite-gui-autostart)
  - [floating](#services-proxy-suite-gui-floating)
  - [refreshInterval](#services-proxy-suite-gui-refreshinterval)

<a id="services-proxy-suite-gui-enable"></a>
## services\.proxy-suite\.gui\.enable

Whether to enable Proxy Suite GUI, a desktop app with a tray icon\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-gui-autostart"></a>
## services\.proxy-suite\.gui\.autostart

Start the GUI in the tray on login to a graphical session\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-gui-floating"></a>
## services\.proxy-suite\.gui\.floating

Open the window floating, sized to the screen, where a tiling compositor (niri, sway,
Hyprland, i3) would tile it\. It opens at a fixed size, which those compositors float,
then resizes as usual\. Turn off to let the compositor tile it\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-gui-refreshinterval"></a>
## services\.proxy-suite\.gui\.refreshInterval

How often the status refreshes, in seconds\.

**Type:** positive integer, meaning >0\
**Default:** `3`
