# services.proxy-suite.userControl

Part of the [proxy-suite options reference](./index.md).

## Options

- userControl
  - [allow](#services-proxy-suite-usercontrol-allow)
  - [group](#services-proxy-suite-usercontrol-group)

<a id="services-proxy-suite-usercontrol-allow"></a>
## services\.proxy-suite\.userControl\.allow

What userControl\.group may control without a password:

 - “global”: the global units (proxy, tun, tproxy, zapret, restart, subs update)\.
 - “perApp”: the per-app backend units used by ` proxy-ctl apps run `\.
   Empty grants no passwordless control\.

*Type:*
list of (one of “global”, “perApp”)

*Default:*

```nix
[
  "global"
  "perApp"
]
```

*Example:*

```nix
[
  "global"
]
```

<a id="services-proxy-suite-usercontrol-group"></a>
## services\.proxy-suite\.userControl\.group

Group whose members may run privileged ` proxy-ctl ` commands without a password\.

*Type:*
string matching the pattern ^\[a-z_]\[a-z0-9_-]\*$

*Default:*

```nix
"proxy-suite"
```
