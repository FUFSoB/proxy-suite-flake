# services.proxy-suite.killSwitch

Block traffic outside the global tunnel.

Part of the [proxy-suite options reference](./index.md).

## Options

- killSwitch
  - [enable](#services-proxy-suite-killswitch-enable)

<a id="services-proxy-suite-killswitch-enable"></a>
## services\.proxy-suite\.killSwitch\.enable

Block outgoing traffic that bypasses the active global tunnel (TUN, TProxy or a global
AmneziaWG profile), including while it restarts or after it fails\. LAN, DHCP and NTP stay
open; ` proxy.tproxy.lanInterfaces ` devices keep the LAN but lose the internet\. Only turning
the tunnel off, or ` proxy-ctl killswitch off `, lifts it\.

**Type:** boolean\
**Default:** `false`
