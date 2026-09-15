# services.proxy-suite.amneziaWg

Part of the [proxy-suite options reference](./index.md).

## Options

- amneziaWg
  - [enable](#services-proxy-suite-amneziawg-enable)
  - [kernelModulePackage](#services-proxy-suite-amneziawg-kernelmodulepackage)
  - [profiles](#services-proxy-suite-amneziawg-profiles)
    - `<name>`
      - [allowConfigHooks](#services-proxy-suite-amneziawg-profiles-name-allowconfighooks)
      - [autostart](#services-proxy-suite-amneziawg-profiles-name-autostart)
      - [configFile](#services-proxy-suite-amneziawg-profiles-name-configfile)
      - [interfaceName](#services-proxy-suite-amneziawg-profiles-name-interfacename)
      - [settings](#services-proxy-suite-amneziawg-profiles-name-settings)
        - [addresses](#services-proxy-suite-amneziawg-profiles-name-settings-addresses)
        - [dns](#services-proxy-suite-amneziawg-profiles-name-settings-dns)
        - [listenPort](#services-proxy-suite-amneziawg-profiles-name-settings-listenport)
        - [mtu](#services-proxy-suite-amneziawg-profiles-name-settings-mtu)
        - [obfuscation](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation)
          - [contentPaddingAddition](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-contentpaddingaddition)
          - [disableCookies](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-disablecookies)
          - [h1](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h1)
          - [h2](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h2)
          - [h3](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h3)
          - [h4](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h4)
          - [headerProtectionKey](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-headerprotectionkey)
          - [headerProtectionKeyFile](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-headerprotectionkeyfile)
          - [i1](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i1)
          - [i2](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i2)
          - [i3](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i3)
          - [i4](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i4)
          - [i5](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i5)
          - [jc](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jc)
          - [jmax](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jmax)
          - [jmin](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jmin)
          - [keepaliveTimeout](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-keepalivetimeout)
          - [maxHandshakeAttempts](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-maxhandshakeattempts)
          - [randomTrailers](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-randomtrailers)
          - [rejectAfterTime](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rejectaftertime)
          - [rekeyAfterTime](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rekeyaftertime)
          - [rekeyTimeout](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rekeytimeout)
          - [s1](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s1)
          - [s2](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s2)
          - [s3](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s3)
          - [s4](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s4)
        - [obfuscationFile](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscationfile)
        - [peers](#services-proxy-suite-amneziawg-profiles-name-settings-peers)
          - item
            - [advancedSecurity](#services-proxy-suite-amneziawg-profiles-name-settings-peers-advancedsecurity)
            - [allowedIPs](#services-proxy-suite-amneziawg-profiles-name-settings-peers-allowedips)
            - [endpoint](#services-proxy-suite-amneziawg-profiles-name-settings-peers-endpoint)
            - [persistentKeepalive](#services-proxy-suite-amneziawg-profiles-name-settings-peers-persistentkeepalive)
            - [presharedKey](#services-proxy-suite-amneziawg-profiles-name-settings-peers-presharedkey)
            - [presharedKeyFile](#services-proxy-suite-amneziawg-profiles-name-settings-peers-presharedkeyfile)
            - [publicKey](#services-proxy-suite-amneziawg-profiles-name-settings-peers-publickey)
        - [privateKey](#services-proxy-suite-amneziawg-profiles-name-settings-privatekey)
        - [privateKeyFile](#services-proxy-suite-amneziawg-profiles-name-settings-privatekeyfile)
        - [table](#services-proxy-suite-amneziawg-profiles-name-settings-table)
      - [vpn](#services-proxy-suite-amneziawg-profiles-name-vpn)
      - [vpnContainer](#services-proxy-suite-amneziawg-profiles-name-vpncontainer)
      - [vpnFile](#services-proxy-suite-amneziawg-profiles-name-vpnfile)
  - [toolsPackage](#services-proxy-suite-amneziawg-toolspackage)
  - [userspacePackage](#services-proxy-suite-amneziawg-userspacepackage)

<a id="services-proxy-suite-amneziawg-enable"></a>
## services\.proxy-suite\.amneziaWg\.enable

Whether to enable native AmneziaWG client profiles\.

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

<a id="services-proxy-suite-amneziawg-kernelmodulepackage"></a>
## services\.proxy-suite\.amneziaWg\.kernelModulePackage

AWG 3\.1 kernel module package\. Set null to use userspace-only fallback\.

*Type:*
null or package

*Default:*

```nix
<derivation amneziawg-3.1.20260828>
```

<a id="services-proxy-suite-amneziawg-profiles"></a>
## services\.proxy-suite\.amneziaWg\.profiles

Named AmneziaWG client profiles\. Only one global profile can be active\.

A profile moves to a new source port, keeping its routes, when a handshake goes
unanswered: every 5 seconds while it starts (it gives up after 20), and when
proxy-suite-awg-NAME-watchdog sees a rekey not getting through\. settings\.listenPort
pins the port and turns that off\.

*Type:*
attribute set of (submodule)

*Default:*

```nix
{ }
```

<a id="services-proxy-suite-amneziawg-profiles-name-allowconfighooks"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.allowConfigHooks

Allow trusted imported configs to execute wg-quick hooks or use SaveConfig\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-amneziawg-profiles-name-autostart"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.autostart

Whether to start this profile at boot\. At most one profile may autostart\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-amneziawg-profiles-name-configfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.configFile

Runtime path to an AmneziaWG \.conf file\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-interfacename"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.interfaceName

Linux interface name\. It must fit Linux’s 15-character limit\.

*Type:*
string matching the pattern ^\[A-Za-z0-9_\.-]{1,15}$

*Default:*

```nix
"awg-‹name›"
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings

Typed declarative AmneziaWG client configuration\.

*Type:*
null or (submodule)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-addresses"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.addresses

IP prefixes assigned to the AWG interface\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "10.8.0.2/32"
]
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-dns"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.dns

DNS servers installed while this profile is active\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-listenport"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.listenPort

Optional local UDP listen port\.

*Type:*
null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-mtu"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.mtu

Optional interface MTU\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation

AmneziaWG 1\.x through 3\.x obfuscation parameters\.

*Type:*
submodule

*Default:*

```nix
{ }
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-contentpaddingaddition"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.contentPaddingAddition

AWG 3 content-padding addition or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-disablecookies"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.disableCookies

AWG 3 cookie suppression (DisableCookies)\.

*Type:*
null or boolean

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h1"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.h1

Handshake-init header or range (H1)\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h2"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.h2

Handshake-response header or range (H2)\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h3"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.h3

Cookie-reply header or range (H3)\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h4"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.h4

Transport-message header or range (H4)\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-headerprotectionkey"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.headerProtectionKey

Inline AWG 3 header-protection key\. Prefer headerProtectionKeyFile\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-headerprotectionkeyfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.headerProtectionKeyFile

Runtime path containing the AWG 3 header-protection key\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i1"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i1

First custom signature packet (I1)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i2"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i2

Second custom signature packet (I2)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i3"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i3

Third custom signature packet (I3)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i4"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i4

Fourth custom signature packet (I4)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i5"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i5

Fifth custom signature packet (I5)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jc"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.jc

Junk packet count (Jc)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jmax"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.jmax

Maximum junk packet size (Jmax)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jmin"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.jmin

Minimum junk packet size (Jmin)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-keepalivetimeout"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.keepaliveTimeout

AWG 3 keepalive timeout or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-maxhandshakeattempts"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.maxHandshakeAttempts

AWG 3 maximum handshake attempts or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-randomtrailers"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.randomTrailers

AWG 3 random transport trailers (RandomTrailers)\.

*Type:*
null or boolean

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rejectaftertime"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.rejectAfterTime

AWG 3 reject-after interval or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rekeyaftertime"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.rekeyAfterTime

AWG 3 rekey interval or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rekeytimeout"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.rekeyTimeout

AWG 3 rekey timeout or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s1"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.s1

Handshake-init padding (S1)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s2"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.s2

Handshake-response padding (S2)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s3"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.s3

Cookie-reply padding (S3)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s4"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.s4

Transport-message padding (S4)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscationfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscationFile

Runtime path to a partial JSON object using the same field names and
value types as obfuscation, excluding headerProtectionKeyFile\.
Values are combined with public obfuscation settings at service startup
without putting the file contents in the Nix store\. Omitted or null
fields are unset; duplicate JSON keys and fields set in both sources
are rejected\. A file-provided headerProtectionKey also conflicts with
obfuscation\.headerProtectionKeyFile\. Private and preshared keys use
their existing file options\. Restart the profile after secret rotation\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/awg-obfuscation.json"
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers

AmneziaWG peers\.

*Type:*
list of (submodule)

*Default:*

```nix
[ ]
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-advancedsecurity"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.advancedSecurity

Optional AWG peer AdvancedSecurity setting\.

*Type:*
null or boolean

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-allowedips"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.allowedIPs

IP prefixes routed to and accepted from this peer\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "0.0.0.0/0"
  "::/0"
]
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-endpoint"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.endpoint

Optional peer endpoint in host:port form\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"vpn.example.com:51820"
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-persistentkeepalive"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.persistentKeepalive

Persistent keepalive seconds, optionally expressed as an AWG 3 range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-presharedkey"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.presharedKey

Inline peer preshared key\. Prefer presharedKeyFile for secrets\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-presharedkeyfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.presharedKeyFile

Runtime path containing the peer preshared key\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-publickey"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.publicKey

AmneziaWG peer public key\.

*Type:*
string matching the pattern \[^\[:space:]]+

<a id="services-proxy-suite-amneziawg-profiles-name-settings-privatekey"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.privateKey

Inline client private key\. Prefer privateKeyFile\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-privatekeyfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.privateKeyFile

Runtime path containing the client private key\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-settings-table"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.table

wg-quick routing table name/number, auto, or off\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-vpn"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.vpn

Inline self-contained vpn:// export\. This value is stored in the Nix store\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-vpncontainer"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.vpnContainer

AWG container/protocol identifier to select when a vpn:// bundle is ambiguous\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-profiles-name-vpnfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.vpnFile

Runtime path containing a self-contained vpn:// export\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-amneziawg-toolspackage"></a>
## services\.proxy-suite\.amneziaWg\.toolsPackage

AWG 3\.1 package providing awg and awg-quick\.

*Type:*
package

*Default:*

```nix
<derivation amneziawg-tools-3.1.20260812>
```

<a id="services-proxy-suite-amneziawg-userspacepackage"></a>
## services\.proxy-suite\.amneziaWg\.userspacePackage

AWG 3\.1 userspace implementation used when the kernel interface is unavailable\.

*Type:*
package

*Default:*

```nix
<derivation amneziawg-go-3.1.20260828>
```
