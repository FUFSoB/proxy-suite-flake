# services.proxy-suite.warp

Part of the [proxy-suite options reference](./index.md).

## Options

- warp
  - [enable](#services-proxy-suite-warp-enable)
  - [asAmneziaWg](#services-proxy-suite-warp-asamneziawg)
  - [asOutbound](#services-proxy-suite-warp-asoutbound)
  - [configFile](#services-proxy-suite-warp-configfile)

<a id="services-proxy-suite-warp-enable"></a>
## services\.proxy-suite\.warp\.enable

Whether to enable Cloudflare WARP\.

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

<a id="services-proxy-suite-warp-asamneziawg"></a>
## services\.proxy-suite\.warp\.asAmneziaWg

Add an AmneziaWG profile named “warp” (` proxy-ctl awg on warp `)\. Requires amneziaWg\.enable\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-warp-asoutbound"></a>
## services\.proxy-suite\.warp\.asOutbound

Add WARP as an outbound tagged “warp”: a SOCKS hop to proxy-suite-warp-tunnel, which
runs WARP as a sing-box WireGuard endpoint on 127\.0\.0\.1:18538 and restarts it on a new
source port when the handshake stops being answered\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-warp-configfile"></a>
## services\.proxy-suite\.warp\.configFile

Runtime path to a WireGuard profile for WARP, as written by ` wgcf register && wgcf generate `\.
Junk-packet lines (Jc, Jmin, Jmax) are honoured by the AmneziaWG profile only\.

When null, proxy-suite-warp registers a device with wgcf (accepting Cloudflare’s terms)
into /var/lib/proxy-suite/warp, through the local proxy when proxy\.enable is set, and
retries until it succeeds\. Until then warp connections fail\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/wgcf-profile.conf"
```
