# services.proxy-suite.gui

Part of the [proxy-suite options reference](./index.md).

## Options

- gui
  - [enable](#services-proxy-suite-gui-enable)
  - [autostart](#services-proxy-suite-gui-autostart)
  - [refreshInterval](#services-proxy-suite-gui-refreshinterval)

<a id="services-proxy-suite-gui-enable"></a>
## services\.proxy-suite\.gui\.enable

Whether to enable Proxy Suite GUI, a desktop app with a tray icon for everything proxy-ctl controls at runtime\.

*Type:*
boolean

*Default:*

```nix
false
```

*Example:*

```nix
true
```

<a id="services-proxy-suite-gui-autostart"></a>
## services\.proxy-suite\.gui\.autostart

Start the GUI hidden in the tray with graphical sessions, as the
` proxy-suite-gui ` systemd user unit on ` graphical-session.target `\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-gui-refreshinterval"></a>
## services\.proxy-suite\.gui\.refreshInterval

Status refresh interval, in seconds\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
3
```
