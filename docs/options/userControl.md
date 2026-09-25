# services.proxy-suite.userControl

Part of the [proxy-suite options reference](./index.md).

## Options

- userControl
  - [enable](#services-proxy-suite-usercontrol-enable)
  - [group](#services-proxy-suite-usercontrol-group)
  - [scopes](#services-proxy-suite-usercontrol-scopes)

<a id="services-proxy-suite-usercontrol-enable"></a>
## services\.proxy-suite\.userControl\.enable

Whether to enable passwordless ` proxy-ctl ` control for the members of userControl\.group\.

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

<a id="services-proxy-suite-usercontrol-group"></a>
## services\.proxy-suite\.userControl\.group

Group whose members may run privileged ` proxy-ctl ` commands without a password\.

*Type:*
string matching the pattern ^\[a-z_]\[a-z0-9_-]\*$

*Default:*

```nix
"proxy-suite"
```

<a id="services-proxy-suite-usercontrol-scopes"></a>
## services\.proxy-suite\.userControl\.scopes

What userControl\.group may do; empty allows every scope\.

 - “services”: turn the proxy-suite units on and off (proxy, tun, tproxy, zapret, ssh, warp, tor, tg, awg, inbounds), ` restart `, and ` tor status|newnym ` on Tor’s control socket\.
 - “perApp”: the per-app backend units used by ` proxy-ctl apps run `\.
 - “routing”: ` proxy pin `, ` proxy unpin ` and ` proxy mode `\.
 - “outbounds”: add and remove runtime outbounds and subscriptions, disable and enable outbounds, and update subscriptions\.
 - “secrets”: read share links, subscription URLs and the running configs\.
 - “autoProxy”: read what autoProxy learned, and ` proxy auto learn|forget|relearn|clear `\.
 - “zapret”: edit zapret2’s learned hosts, and ` zapret cutoff probe `\.
 - “stats”: ` inbounds stats `\.
 - “whitelistBypass”: the whitelist-bypass creators and joiners: ` wl on|off|toggle|restart `, their calls (` wl link `), and their logins and links (` wl auth|join|new `)\.

*Type:*
list of (one of “services”, “perApp”, “routing”, “outbounds”, “secrets”, “autoProxy”, “zapret”, “stats”, “whitelistBypass”)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "services"
  "routing"
]
```
