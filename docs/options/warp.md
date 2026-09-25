# services.proxy-suite.warp

Cloudflare WARP, as an outbound or an AmneziaWG profile.

Part of the [proxy-suite options reference](./index.md).

## Options

- warp
  - [enable](#services-proxy-suite-warp-enable)
  - [asAmneziaWg](#services-proxy-suite-warp-asamneziawg)
  - [asOutbound](#services-proxy-suite-warp-asoutbound)
  - [configFile](#services-proxy-suite-warp-configfile)
  - [endpoint](#services-proxy-suite-warp-endpoint)
  - [generatorUrl](#services-proxy-suite-warp-generatorurl)

<a id="services-proxy-suite-warp-enable"></a>
## services\.proxy-suite\.warp\.enable

Run Cloudflare WARP\. Also set ` asOutbound ` or ` asAmneziaWg `\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-warp-asamneziawg"></a>
## services\.proxy-suite\.warp\.asAmneziaWg

Add a global AmneziaWG profile named “warp” (` proxy-ctl awg on warp `)\. Needs
` amneziaWg.enable `\. Cannot be used with ` asOutbound `\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-warp-asoutbound"></a>
## services\.proxy-suite\.warp\.asOutbound

Add WARP as an outbound tagged “warp”\.

 - “singBox”: plain WireGuard in sing-box, ignoring AmneziaWG fields\. Restarts itself when
   WARP stops answering\.
 - “userspace”: an AmneziaWG profile, without root\. Needs ` amneziaWg.enable `\.
 - “interface”: an AmneziaWG profile with its own interface\. Needs ` amneziaWg.enable `\.

**Type:** null or one of “singBox”, “userspace”, “interface”\
**Default:** `null`

<a id="services-proxy-suite-warp-configfile"></a>
## services\.proxy-suite\.warp\.configFile

File with a WARP WireGuard profile, from ` wgcf register && wgcf generate `\. AmneziaWG
fields in it only take effect in the AmneziaWG modes\.

` null `: register a new device with wgcf on first start (accepting Cloudflare’s terms),
through the local proxy if enabled\. WARP does not work until that succeeds\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/wgcf-profile.conf"`

<a id="services-proxy-suite-warp-endpoint"></a>
## services\.proxy-suite\.warp\.endpoint

host:port (IPv6 in brackets) to use instead of the profile’s endpoint, if the default one
is blocked: another Cloudflare address, another WARP port (500, 1701, 4500, …), or a relay\.

**Type:** null or string matching the pattern (\\\[\[0-9A-Fa-f:\.]+]|\[^]:\[]+):\[0-9]+\
**Default:** `null`\
**Example:** `"162.159.192.1:500"`

<a id="services-proxy-suite-warp-generatorurl"></a>
## services\.proxy-suite\.warp\.generatorUrl

URL of a WARP profile generator, used if wgcf registration fails (for example, when the
Cloudflare API is blocked)\. It must return a WireGuard profile, or JSON with the base64
profile in ` .content `\.

Its operator sees your private key\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"https://valokda-amnezia.vercel.app/api/warp?mode=awg2"`
