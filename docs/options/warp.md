# services.proxy-suite.warp

Cloudflare WARP, as an outbound or an AmneziaWG profile.

Part of the [proxy-suite options reference](./index.md).

## Options

- warp
  - [enable](#services-proxy-suite-warp-enable)
  - [asAmneziaWg](#services-proxy-suite-warp-asamneziawg)
  - [asOutbound](#services-proxy-suite-warp-asoutbound)
  - [autostart](#services-proxy-suite-warp-autostart)
  - [configFile](#services-proxy-suite-warp-configfile)
  - [devices](#services-proxy-suite-warp-devices)
    - `<name>`
      - [configFile](#services-proxy-suite-warp-devices-name-configfile)
      - [endpoint](#services-proxy-suite-warp-devices-name-endpoint)
  - [domainStrategy](#services-proxy-suite-warp-domainstrategy)
  - [endpoint](#services-proxy-suite-warp-endpoint)
  - [endpoints](#services-proxy-suite-warp-endpoints)
  - [generatorUrl](#services-proxy-suite-warp-generatorurl)
  - group
    - [failback](#services-proxy-suite-warp-group-failback)
    - [strategy](#services-proxy-suite-warp-group-strategy)
  - [instances](#services-proxy-suite-warp-instances)
  - [obfuscation](#services-proxy-suite-warp-obfuscation)
    - [contentPaddingAddition](#services-proxy-suite-warp-obfuscation-contentpaddingaddition)
    - [disableCookies](#services-proxy-suite-warp-obfuscation-disablecookies)
    - [h1](#services-proxy-suite-warp-obfuscation-h1)
    - [h2](#services-proxy-suite-warp-obfuscation-h2)
    - [h3](#services-proxy-suite-warp-obfuscation-h3)
    - [h4](#services-proxy-suite-warp-obfuscation-h4)
    - [headerProtectionKey](#services-proxy-suite-warp-obfuscation-headerprotectionkey)
    - [headerProtectionKeyFile](#services-proxy-suite-warp-obfuscation-headerprotectionkeyfile)
    - [i1](#services-proxy-suite-warp-obfuscation-i1)
    - [i2](#services-proxy-suite-warp-obfuscation-i2)
    - [i3](#services-proxy-suite-warp-obfuscation-i3)
    - [i4](#services-proxy-suite-warp-obfuscation-i4)
    - [i5](#services-proxy-suite-warp-obfuscation-i5)
    - [jc](#services-proxy-suite-warp-obfuscation-jc)
    - [jmax](#services-proxy-suite-warp-obfuscation-jmax)
    - [jmin](#services-proxy-suite-warp-obfuscation-jmin)
    - [keepaliveTimeout](#services-proxy-suite-warp-obfuscation-keepalivetimeout)
    - [maxHandshakeAttempts](#services-proxy-suite-warp-obfuscation-maxhandshakeattempts)
    - [randomTrailers](#services-proxy-suite-warp-obfuscation-randomtrailers)
    - [rejectAfterTime](#services-proxy-suite-warp-obfuscation-rejectaftertime)
    - [rekeyAfterTime](#services-proxy-suite-warp-obfuscation-rekeyaftertime)
    - [rekeyTimeout](#services-proxy-suite-warp-obfuscation-rekeytimeout)
    - [s1](#services-proxy-suite-warp-obfuscation-s1)
    - [s2](#services-proxy-suite-warp-obfuscation-s2)
    - [s3](#services-proxy-suite-warp-obfuscation-s3)
    - [s4](#services-proxy-suite-warp-obfuscation-s4)

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

<a id="services-proxy-suite-warp-autostart"></a>
## services\.proxy-suite\.warp\.autostart

Bring the “warp” AmneziaWG profile up at boot, as ` autostart ` of an ` amneziaWg ` profile
does\. Needs ` asAmneziaWg `\. Only one global mode can autostart\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-warp-configfile"></a>
## services\.proxy-suite\.warp\.configFile

File with a WARP WireGuard profile, from ` wgcf register && wgcf generate `\. AmneziaWG
fields in it only take effect in the AmneziaWG modes\.

` null `: register a new device with wgcf on first start (accepting Cloudflare’s terms),
through the local proxy if enabled\. WARP does not work until that succeeds\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/wgcf-profile.conf"`

<a id="services-proxy-suite-warp-devices"></a>
## services\.proxy-suite\.warp\.devices

Several WARP devices, each registered on its own and each an outbound with its tag\. With
two or more, the tag “warp” names a group of them (` warp.group `), so rules, pins and
chains naming “warp” fail over between them\. A device cannot be named “warp” then\.
With “interface”, a tag holds at most 11 characters (its interface is awg-\<tag>)\.

Empty: one device, “warp”, as ` configFile ` and ` endpoint ` above say\.

**Type:** attribute set of (submodule)\
**Default:** `{ }`\
**Example:** `{ warp-a = { }; warp-b.endpoint = "162.159.193.10:500"; } `

<a id="services-proxy-suite-warp-devices-name-configfile"></a>
## services\.proxy-suite\.warp\.devices\.\<name>\.configFile

This device’s WireGuard profile, as ` warp.configFile `\. ` null `: registered with wgcf\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/warp-b.conf"`

<a id="services-proxy-suite-warp-devices-name-endpoint"></a>
## services\.proxy-suite\.warp\.devices\.\<name>\.endpoint

This device’s endpoint, as ` warp.endpoint ` (which it defaults to)\.

**Type:** null or string matching the pattern (\\\[\[0-9A-Fa-f:\.]+]|\[^]:\[]+):\[0-9]+\
**Default:** `null`\
**Example:** `"162.159.192.1:500"`

<a id="services-proxy-suite-warp-domainstrategy"></a>
## services\.proxy-suite\.warp\.domainStrategy

Which address family the “warp” outbound dials a name over first\. Ignored with
` asOutbound = "userspace" `\. Also applies to names resolved by the inbounds’
` routing.blockPrivate ` check, unless ` proxy.dns.strategy ` is set\.

**Type:** null or one of “prefer_ipv4”, “prefer_ipv6”, “ipv4_only”, “ipv6_only”\
**Default:** `if config.networking.enableIPv6 then "prefer_ipv6" else "prefer_ipv4"`\
**Example:** `"prefer_ipv4"`

<a id="services-proxy-suite-warp-endpoint"></a>
## services\.proxy-suite\.warp\.endpoint

host:port (IPv6 in brackets) to use instead of the profile’s endpoint, if the default one
is blocked: another Cloudflare address, another WARP port (500, 1701, 4500, …), or a relay\.

**Type:** null or string matching the pattern (\\\[\[0-9A-Fa-f:\.]+]|\[^]:\[]+):\[0-9]+\
**Default:** `null`\
**Example:** `"162.159.192.1:500"`

<a id="services-proxy-suite-warp-endpoints"></a>
## services\.proxy-suite\.warp\.endpoints

Other WARP endpoints, tried in turn after the profile’s own when the tunnel stops
answering (the uplink being up): another address or port often gets through where the
default one is blocked or throttled\. The one that worked is used again after a restart\.
Off when ` endpoint ` (or a device’s) pins one\. For the “singBox” and “userspace” tunnels;
“interface” and ` asAmneziaWg ` keep the profile’s endpoint\. ` [ ] `: the profile’s only\.

**Type:** list of string matching the pattern (\\\[\[0-9A-Fa-f:\.]+]|\[^]:\[]+):\[0-9]+\
**Default:**

```nix
[
  "162.159.192.8:894"
  "162.159.192.1:894"
  "162.159.192.8:2408"
  "162.159.192.1:2408"
  "162.159.193.10:2408"
  "188.114.96.1:2408"
  "188.114.97.1:2408"
  "162.159.192.1:945"
  "162.159.193.10:4500"
  "188.114.96.1:1701"
  "188.114.97.1:955"
]
```

<a id="services-proxy-suite-warp-generatorurl"></a>
## services\.proxy-suite\.warp\.generatorUrl

URL of a WARP profile generator, used if wgcf registration fails (for example, when the
Cloudflare API is blocked)\. It must return a WireGuard profile, or JSON with the base64
profile in ` .content `\.

Its operator sees your private key\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"https://valokda-amnezia.vercel.app/api/warp?mode=awg2"`

<a id="services-proxy-suite-warp-group-failback"></a>
## services\.proxy-suite\.warp\.group\.failback

With “failover”: go back to an earlier device once it works again\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-warp-group-strategy"></a>
## services\.proxy-suite\.warp\.group\.strategy

How the “warp” group of several devices picks one; see ` proxy.groups `\.

**Type:** one of “failover”, “urltest”, “selector”\
**Default:** `"failover"`

<a id="services-proxy-suite-warp-instances"></a>
## services\.proxy-suite\.warp\.instances

Shorthand for ` devices `: this many WARP devices, warp-1 to warp-N, each registered with
wgcf\. warp-1 keeps the registration a single “warp” device made\. Not with ` devices `\.

**Type:** null or (positive integer, meaning >0)\
**Default:** `null`\
**Example:** `2`

<a id="services-proxy-suite-warp-obfuscation"></a>
## services\.proxy-suite\.warp\.obfuscation

AmneziaWG obfuscation for WARP over AmneziaWG (` asOutbound = "userspace" ` or
` "interface" `, and ` asAmneziaWg `), where its profile has none of its own: a wgcf
profile never does, one from ` generatorUrl ` may\. Cloudflare takes only obfuscation
that leaves the handshake and data plain WireGuard, so this adds packets before each
handshake: against a DPI box that judges a flow by its first packets, not one that
checks every packet\. Cloudflare drops them, so it costs nothing where there is no
such box\. ` null `: none\. Plain WireGuard (` asOutbound = "singBox" `) has no obfuscation\.

**Type:** null or (submodule)\
**Default:** the Amnezia WARP preset (` modules/proxy-suite/warp-obfuscation.nix `): Jc 4, Jmin 40, Jmax 70, S1 = S2 = 0, H1-H4 = 1-4 and an I1 packet that reads as a QUIC Initial\
**Example:** `{ jc = 4; jmax = 70; jmin = 40; }`

<a id="services-proxy-suite-warp-obfuscation-contentpaddingaddition"></a>
## services\.proxy-suite\.warp\.obfuscation\.contentPaddingAddition

AWG 3 content-padding addition or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-disablecookies"></a>
## services\.proxy-suite\.warp\.obfuscation\.disableCookies

AWG 3 cookie suppression (DisableCookies)\.

**Type:** null or boolean\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-h1"></a>
## services\.proxy-suite\.warp\.obfuscation\.h1

Handshake-init header or range (H1)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-h2"></a>
## services\.proxy-suite\.warp\.obfuscation\.h2

Handshake-response header or range (H2)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-h3"></a>
## services\.proxy-suite\.warp\.obfuscation\.h3

Cookie-reply header or range (H3)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-h4"></a>
## services\.proxy-suite\.warp\.obfuscation\.h4

Transport-message header or range (H4)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-headerprotectionkey"></a>
## services\.proxy-suite\.warp\.obfuscation\.headerProtectionKey

AWG 3 header-protection key\. Ends up in the Nix store; prefer ` headerProtectionKeyFile `\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-headerprotectionkeyfile"></a>
## services\.proxy-suite\.warp\.obfuscation\.headerProtectionKeyFile

File with the AWG 3 header-protection key\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-i1"></a>
## services\.proxy-suite\.warp\.obfuscation\.i1

First custom signature packet (I1)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-i2"></a>
## services\.proxy-suite\.warp\.obfuscation\.i2

Second custom signature packet (I2)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-i3"></a>
## services\.proxy-suite\.warp\.obfuscation\.i3

Third custom signature packet (I3)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-i4"></a>
## services\.proxy-suite\.warp\.obfuscation\.i4

Fourth custom signature packet (I4)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-i5"></a>
## services\.proxy-suite\.warp\.obfuscation\.i5

Fifth custom signature packet (I5)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-jc"></a>
## services\.proxy-suite\.warp\.obfuscation\.jc

Junk packet count (Jc)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-jmax"></a>
## services\.proxy-suite\.warp\.obfuscation\.jmax

Maximum junk packet size (Jmax)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-jmin"></a>
## services\.proxy-suite\.warp\.obfuscation\.jmin

Minimum junk packet size (Jmin)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-keepalivetimeout"></a>
## services\.proxy-suite\.warp\.obfuscation\.keepaliveTimeout

AWG 3 keepalive timeout or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-maxhandshakeattempts"></a>
## services\.proxy-suite\.warp\.obfuscation\.maxHandshakeAttempts

AWG 3 maximum handshake attempts or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-randomtrailers"></a>
## services\.proxy-suite\.warp\.obfuscation\.randomTrailers

AWG 3 random transport trailers (RandomTrailers)\.

**Type:** null or boolean\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-rejectaftertime"></a>
## services\.proxy-suite\.warp\.obfuscation\.rejectAfterTime

AWG 3 reject-after interval or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-rekeyaftertime"></a>
## services\.proxy-suite\.warp\.obfuscation\.rekeyAfterTime

AWG 3 rekey interval or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-rekeytimeout"></a>
## services\.proxy-suite\.warp\.obfuscation\.rekeyTimeout

AWG 3 rekey timeout or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-s1"></a>
## services\.proxy-suite\.warp\.obfuscation\.s1

Handshake-init padding (S1)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-s2"></a>
## services\.proxy-suite\.warp\.obfuscation\.s2

Handshake-response padding (S2)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-s3"></a>
## services\.proxy-suite\.warp\.obfuscation\.s3

Cookie-reply padding (S3)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-warp-obfuscation-s4"></a>
## services\.proxy-suite\.warp\.obfuscation\.s4

Transport-message padding (S4)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`
