# services.proxy-suite.killSwitch

Part of the [proxy-suite options reference](./index.md).

## Options

- killSwitch
  - [enable](#services-proxy-suite-killswitch-enable)

<a id="services-proxy-suite-killswitch-enable"></a>
## services\.proxy-suite\.killSwitch\.enable

Whether to enable a kill switch for the global tunnels (proxy\.tun, proxy\.tproxy and global AmneziaWG profiles):
once one starts, outgoing traffic that would leave outside it is rejected, also while it
restarts, after it crashes or after its handshake gives up\. LAN destinations, DHCP and NTP
stay open; tproxy\.lanInterfaces clients keep the LAN but lose the internet\. Only
` proxy-ctl killswitch off `, ` proxy off `, ` proxy tun off `, ` proxy tproxy off ` or ` awg off `
lift it (proxy-suite-killswitch)
\.

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
