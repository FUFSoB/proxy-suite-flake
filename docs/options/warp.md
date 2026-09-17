# services.proxy-suite.warp

Part of the [proxy-suite options reference](./index.md).

## Options

- warp
  - [enable](#services-proxy-suite-warp-enable)
  - [asAmneziaWg](#services-proxy-suite-warp-asamneziawg)
  - [asOutbound](#services-proxy-suite-warp-asoutbound)
  - [configFile](#services-proxy-suite-warp-configfile)
  - [generatorUrl](#services-proxy-suite-warp-generatorurl)

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

Add an AmneziaWG profile named “warp” (` proxy-ctl awg on warp `)\. Requires amneziaWg\.enable,
and excludes asOutbound: both would use the same WARP key\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-warp-asoutbound"></a>
## services\.proxy-suite\.warp\.asOutbound

Add WARP as an outbound tagged “warp”\.

 - “singBox”: a SOCKS hop to proxy-suite-warp-tunnel, which runs WARP as a sing-box WireGuard
   endpoint on 127\.0\.0\.1:18538, as the proxy-suite-daemon user\. The tunnel starts again on a
   new source port when WARP does not answer within 15 seconds of a start, or misses three
   probes later on, unless the uplink itself is down\.
 - “userspace”: an AmneziaWG profile named “warp” with asOutbound = “userspace”, which honours
   the AmneziaWG lines of the profile without an interface or root\. Requires amneziaWg\.enable\.
 - “interface”: an AmneziaWG profile named “warp” with asOutbound = “interface”, which honours
   the AmneziaWG lines of the profile\. Requires amneziaWg\.enable\.

*Type:*
null or one of “singBox”, “userspace”, “interface”

*Default:*

```nix
null
```

<a id="services-proxy-suite-warp-configfile"></a>
## services\.proxy-suite\.warp\.configFile

Runtime path to a WireGuard profile for WARP, as written by ` wgcf register && wgcf generate `\.
AmneziaWG lines (Jc, S1-S4, H1-H4, I1-I5, AWG 3 timing) are honoured by the AmneziaWG profile
(asAmneziaWg, asOutbound = “interface”) only\.

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

<a id="services-proxy-suite-warp-generatorurl"></a>
## services\.proxy-suite\.warp\.generatorUrl

HTTPS URL of a WARP profile generator, fetched directly when wgcf registration fails
(e\.g\. the Cloudflare API is blocked and there is no local proxy)\. It must return a
WireGuard profile, or JSON with the base64 profile in ` .content `\.

The generator registers the device, so its operator sees the private key\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"https://valokda-amnezia.vercel.app/api/warp?mode=awg2"
```
