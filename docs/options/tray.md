# services.proxy-suite.tray

Part of the [proxy-suite options reference](./index.md).

## Options

- tray
  - [enable](#services-proxy-suite-tray-enable)
  - [autostart](#services-proxy-suite-tray-autostart)
  - [pollInterval](#services-proxy-suite-tray-pollinterval)

<a id="services-proxy-suite-tray-enable"></a>
## services\.proxy-suite\.tray\.enable

Whether to enable the system tray indicator\.

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

<a id="services-proxy-suite-tray-autostart"></a>
## services\.proxy-suite\.tray\.autostart

Start the tray in graphical sessions (XDG autostart)\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-tray-pollinterval"></a>
## services\.proxy-suite\.tray\.pollInterval

Status refresh interval, in seconds\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
5
```
