# services.proxy-suite.inbounds

Part of the [proxy-suite options reference](./index.md).

## Options

- inbounds
  - [enable](#services-proxy-suite-inbounds-enable)
  - [package](#services-proxy-suite-inbounds-package)
  - [listeners](#services-proxy-suite-inbounds-listeners)
    - `<name>`
      - [address](#services-proxy-suite-inbounds-listeners-name-address)
      - [amneziaWg](#services-proxy-suite-inbounds-listeners-name-amneziawg)
        - [clientAllowedIPs](#services-proxy-suite-inbounds-listeners-name-amneziawg-clientallowedips)
        - [dns](#services-proxy-suite-inbounds-listeners-name-amneziawg-dns)
        - [interfaceName](#services-proxy-suite-inbounds-listeners-name-amneziawg-interfacename)
        - [mode](#services-proxy-suite-inbounds-listeners-name-amneziawg-mode)
        - [mtu](#services-proxy-suite-inbounds-listeners-name-amneziawg-mtu)
        - [obfuscation](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation)
          - [contentPaddingAddition](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-contentpaddingaddition)
          - [disableCookies](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-disablecookies)
          - [h1](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h1)
          - [h2](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h2)
          - [h3](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h3)
          - [h4](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h4)
          - [headerProtectionKey](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-headerprotectionkey)
          - [headerProtectionKeyFile](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-headerprotectionkeyfile)
          - [i1](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i1)
          - [i2](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i2)
          - [i3](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i3)
          - [i4](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i4)
          - [i5](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i5)
          - [jc](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jc)
          - [jmax](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jmax)
          - [jmin](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jmin)
          - [keepaliveTimeout](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-keepalivetimeout)
          - [maxHandshakeAttempts](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-maxhandshakeattempts)
          - [randomTrailers](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-randomtrailers)
          - [rejectAfterTime](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rejectaftertime)
          - [rekeyAfterTime](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rekeyaftertime)
          - [rekeyTimeout](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rekeytimeout)
          - [s1](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s1)
          - [s2](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s2)
          - [s3](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s3)
          - [s4](#services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s4)
        - [persistentKeepalive](#services-proxy-suite-inbounds-listeners-name-amneziawg-persistentkeepalive)
        - [privateKeyFile](#services-proxy-suite-inbounds-listeners-name-amneziawg-privatekeyfile)
        - [subnet](#services-proxy-suite-inbounds-listeners-name-amneziawg-subnet)
        - [subnet6](#services-proxy-suite-inbounds-listeners-name-amneziawg-subnet6)
      - [fallbacks](#services-proxy-suite-inbounds-listeners-name-fallbacks)
        - item
          - [alpn](#services-proxy-suite-inbounds-listeners-name-fallbacks-alpn)
          - [dest](#services-proxy-suite-inbounds-listeners-name-fallbacks-dest)
          - [listener](#services-proxy-suite-inbounds-listeners-name-fallbacks-listener)
          - [name](#services-proxy-suite-inbounds-listeners-name-fallbacks-name)
          - [path](#services-proxy-suite-inbounds-listeners-name-fallbacks-path)
          - [xver](#services-proxy-suite-inbounds-listeners-name-fallbacks-xver)
      - [flow](#services-proxy-suite-inbounds-listeners-name-flow)
      - hysteria
        - [masquerade](#services-proxy-suite-inbounds-listeners-name-hysteria-masquerade)
      - [jsonFile](#services-proxy-suite-inbounds-listeners-name-jsonfile)
      - [method](#services-proxy-suite-inbounds-listeners-name-method)
      - [port](#services-proxy-suite-inbounds-listeners-name-port)
      - [reality](#services-proxy-suite-inbounds-listeners-name-reality)
        - [enable](#services-proxy-suite-inbounds-listeners-name-reality-enable)
        - [dest](#services-proxy-suite-inbounds-listeners-name-reality-dest)
        - [privateKey](#services-proxy-suite-inbounds-listeners-name-reality-privatekey)
        - [privateKeyFile](#services-proxy-suite-inbounds-listeners-name-reality-privatekeyfile)
        - [publicKey](#services-proxy-suite-inbounds-listeners-name-reality-publickey)
        - [serverNames](#services-proxy-suite-inbounds-listeners-name-reality-servernames)
        - [shortIds](#services-proxy-suite-inbounds-listeners-name-reality-shortids)
      - [serverPassword](#services-proxy-suite-inbounds-listeners-name-serverpassword)
      - [serverPasswordFile](#services-proxy-suite-inbounds-listeners-name-serverpasswordfile)
      - [sharePort](#services-proxy-suite-inbounds-listeners-name-shareport)
      - [tls](#services-proxy-suite-inbounds-listeners-name-tls)
        - [enable](#services-proxy-suite-inbounds-listeners-name-tls-enable)
        - [alpn](#services-proxy-suite-inbounds-listeners-name-tls-alpn)
        - [certificateFile](#services-proxy-suite-inbounds-listeners-name-tls-certificatefile)
        - [keyFile](#services-proxy-suite-inbounds-listeners-name-tls-keyfile)
        - [serverName](#services-proxy-suite-inbounds-listeners-name-tls-servername)
      - [transport](#services-proxy-suite-inbounds-listeners-name-transport)
        - [host](#services-proxy-suite-inbounds-listeners-name-transport-host)
        - [mode](#services-proxy-suite-inbounds-listeners-name-transport-mode)
        - [path](#services-proxy-suite-inbounds-listeners-name-transport-path)
        - [serviceName](#services-proxy-suite-inbounds-listeners-name-transport-servicename)
        - [trustedXForwardedFor](#services-proxy-suite-inbounds-listeners-name-transport-trustedxforwardedfor)
        - [type](#services-proxy-suite-inbounds-listeners-name-transport-type)
      - [type](#services-proxy-suite-inbounds-listeners-name-type)
      - [users](#services-proxy-suite-inbounds-listeners-name-users)
        - item
          - [address](#services-proxy-suite-inbounds-listeners-name-users-address)
          - [name](#services-proxy-suite-inbounds-listeners-name-users-name)
          - [password](#services-proxy-suite-inbounds-listeners-name-users-password)
          - [passwordFile](#services-proxy-suite-inbounds-listeners-name-users-passwordfile)
          - [presharedKeyFile](#services-proxy-suite-inbounds-listeners-name-users-presharedkeyfile)
          - [privateKeyFile](#services-proxy-suite-inbounds-listeners-name-users-privatekeyfile)
          - [publicKey](#services-proxy-suite-inbounds-listeners-name-users-publickey)
          - [uuid](#services-proxy-suite-inbounds-listeners-name-users-uuid)
          - [uuidFile](#services-proxy-suite-inbounds-listeners-name-users-uuidfile)
      - [via](#services-proxy-suite-inbounds-listeners-name-via)
      - [xrayJson](#services-proxy-suite-inbounds-listeners-name-xrayjson)
  - [openFirewall](#services-proxy-suite-inbounds-openfirewall)
  - routing
    - [blockPrivate](#services-proxy-suite-inbounds-routing-blockprivate)
    - [blockRu](#services-proxy-suite-inbounds-routing-blockru)
    - proxy
      - [domains](#services-proxy-suite-inbounds-routing-proxy-domains)
      - [geoips](#services-proxy-suite-inbounds-routing-proxy-geoips)
      - [geosites](#services-proxy-suite-inbounds-routing-proxy-geosites)
      - [ips](#services-proxy-suite-inbounds-routing-proxy-ips)
    - [via](#services-proxy-suite-inbounds-routing-via)
    - [zapretDirect](#services-proxy-suite-inbounds-routing-zapretdirect)
  - [serverAddress](#services-proxy-suite-inbounds-serveraddress)
  - [shareLinks](#services-proxy-suite-inbounds-sharelinks)
  - subscriptions
    - [enable](#services-proxy-suite-inbounds-subscriptions-enable)
    - [baseUrl](#services-proxy-suite-inbounds-subscriptions-baseurl)
    - [group](#services-proxy-suite-inbounds-subscriptions-group)

<a id="services-proxy-suite-inbounds-enable"></a>
## services\.proxy-suite\.inbounds\.enable

Whether to enable server inbounds that accept proxy connections from outside\.

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

<a id="services-proxy-suite-inbounds-package"></a>
## services\.proxy-suite\.inbounds\.package

XRay package serving the inbounds, whatever the client-side backend\.

*Type:*
package

*Default:*
proxy-suite’s ` xray ` (` pkgs/xray.nix `)

*Example:*

```nix
pkgs.xray
```

<a id="services-proxy-suite-inbounds-listeners"></a>
## services\.proxy-suite\.inbounds\.listeners

Listeners by tag\.

*Type:*
attribute set of (submodule)

*Default:*

```nix
{ }
```

*Example:*

````nix
{
  vless-reality = {
    type = "vless";
    port = 443;
    users = [ { uuidFile = "/run/secrets/proxy-inbound-uuid"; } ];
    flow = "xtls-rprx-vision";
    reality = {
      enable = true;
      serverNames = [ "www.microsoft.com" ];
      privateKeyFile = "/run/secrets/proxy-inbound-reality-key";
      publicKey = "jNXH...";
      shortIds = [ "0123abcd" ];
    };
  };
  # `proxy-ctl inbounds link home phone` prints a vpn:// link; add --config for the .conf.
  home = {
    type = "amneziawg";
    port = 51820;
    users = [ { name = "phone"; } { name = "laptop"; } ];
    amneziaWg.mode = "lan";
  };
}

````

<a id="services-proxy-suite-inbounds-listeners-name-address"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.address

Bound address\. A loopback address keeps the port closed in the firewall\.

*Type:*
string matching the pattern \[^\[:space:]]+

*Default:*

```nix
"::"
```

*Example:*

```nix
"127.0.0.1"
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg

The AmneziaWG server of a type = “amneziawg” listener\.

*Type:*
submodule

*Default:*

```nix
{ }
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-clientallowedips"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.clientAllowedIPs

AllowedIPs in client configs: what clients send through the tunnel\.

*Type:*
list of string

*Default:*

```nix
[
  "0.0.0.0/0"
  "::/0"
]
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-dns"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.dns

DNS servers in client configs\. Queries leave like any other traffic\.

*Type:*
list of string

*Default:*

```nix
[
  "1.1.1.1"
  "1.0.0.1"
]
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-interfacename"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.interfaceName

Linux interface name\. It must fit Linux’s 15-character limit\.

*Type:*
string matching the pattern ^\[A-Za-z0-9_\.-]+$

*Default:*

```nix
"awgi-<tag>"
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-mode"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.mode

What clients reach besides the internet, which they reach the listener’s ` via ` way either way:

 - “proxy”: nothing else\. This host, its private networks and the other peers are cut off\.
 - “lan”: also this host, its private networks and the other peers, directly (masqueraded
   behind this host), not through ` via `\. It turns on IP forwarding\.
   Only TCP and UDP can follow ` via `: anything else to the internet (ping) is dropped\.

*Type:*
one of “proxy”, “lan”

*Default:*

```nix
"proxy"
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-mtu"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.mtu

Interface MTU, on both ends\. Null leaves awg-quick’s (1280 with AWG 3 fields)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation

Obfuscation parameters, shared with every client\. Jc, Jmin, Jmax, S1, S2 and H1-H4 left
null are generated once and kept in the state directory; the rest stay unset\.

*Type:*
submodule

*Default:*

```nix
{ }
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-contentpaddingaddition"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.contentPaddingAddition

AWG 3 content-padding addition or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-disablecookies"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.disableCookies

AWG 3 cookie suppression (DisableCookies)\.

*Type:*
null or boolean

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h1"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.h1

Handshake-init header or range (H1)\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h2"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.h2

Handshake-response header or range (H2)\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h3"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.h3

Cookie-reply header or range (H3)\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h4"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.h4

Transport-message header or range (H4)\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-headerprotectionkey"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.headerProtectionKey

Inline AWG 3 header-protection key\. Prefer headerProtectionKeyFile\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-headerprotectionkeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.headerProtectionKeyFile

Runtime path containing the AWG 3 header-protection key\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i1"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i1

First custom signature packet (I1)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i2"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i2

Second custom signature packet (I2)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i3"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i3

Third custom signature packet (I3)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i4"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i4

Fourth custom signature packet (I4)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i5"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i5

Fifth custom signature packet (I5)\.

*Type:*
null or string

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jc"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.jc

Junk packet count (Jc)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jmax"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.jmax

Maximum junk packet size (Jmax)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jmin"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.jmin

Minimum junk packet size (Jmin)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-keepalivetimeout"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.keepaliveTimeout

AWG 3 keepalive timeout or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-maxhandshakeattempts"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.maxHandshakeAttempts

AWG 3 maximum handshake attempts or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-randomtrailers"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.randomTrailers

AWG 3 random transport trailers (RandomTrailers)\.

*Type:*
null or boolean

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rejectaftertime"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.rejectAfterTime

AWG 3 reject-after interval or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rekeyaftertime"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.rekeyAfterTime

AWG 3 rekey interval or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rekeytimeout"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.rekeyTimeout

AWG 3 rekey timeout or range\.

*Type:*
null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s1"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.s1

Handshake-init padding (S1)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s2"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.s2

Handshake-response padding (S2)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s3"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.s3

Cookie-reply padding (S3)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s4"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.s4

Transport-message padding (S4)\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
null
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-persistentkeepalive"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.persistentKeepalive

PersistentKeepalive in client configs, which keeps NAT mappings open\.

*Type:*
null or (unsigned integer, meaning >=0)

*Default:*

```nix
25
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-privatekeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.privateKeyFile

Runtime path to the server private key, instead of a generated one\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/awg-server-key"
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-subnet"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.subnet

Tunnel IPv4 subnet, private and unused elsewhere\. This host takes the first address, clients
the rest\.

*Type:*
string matching the pattern \[0-9\.]+/\[0-9]+

*Default:*

```nix
"10.66.0.0/24"
```

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-subnet6"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.subnet6

Tunnel IPv6 subnet (ULA), laid out as subnet\. Null keeps the tunnel IPv4-only\. With mode = “lan”
it turns on IPv6 forwarding, which stops this host configuring itself from router advertisements\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"fd66:66::/64"
```

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks

Where XRay sends connections that are not this listener’s protocol, so several share
one port (vless or trojan on the raw transport)\. Matched in order on SNI, ALPN and path;
the first entry without any is the catch-all, such as a decoy web server\. Browsers
negotiate h2 unless tls\.alpn says otherwise, so a dest that speaks only HTTP/1\.1 needs
tls\.alpn = \[ “http/1\.1” ], or an alpn = “h2” entry to one that speaks h2c\.

*Type:*
list of (submodule)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  { path = "/ws"; listener = "ws-in"; }  # ws-in: vless, ws, address = "127.0.0.1"
  { dest = 8080; }
]

```

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-alpn"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.alpn

Negotiated ALPN to match\. Null matches any\.

*Type:*
null or one of “h2”, “http/1\.1”

*Default:*

```nix
null
```

*Example:*

```nix
"h2"
```

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-dest"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.dest

Where matching connections go: a port, host:port, or a unix socket path\. Exclusive with listener\.

*Type:*
null or 16 bit unsigned integer; between 0 and 65535 (both inclusive) or string

*Default:*

```nix
null
```

*Example:*

```nix
"127.0.0.1:8080"
```

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-listener"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.listener

Tag of another listener that matching connections go to, instead of dest\. It must be a
vless listener without tls or reality, on a loopback address: it gets the connection
decrypted, with the client address in PROXY protocol, and its share links advertise this
listener’s port and TLS or REALITY\. Behind REALITY it must be xhttp or grpc, the only
transports REALITY clients run besides raw\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"ws-in"
```

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-name"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.name

SNI to match\. Null matches any\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"www.example.com"
```

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-path"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.path

Request path to match\. Null matches any\. XRay reads it from HTTP/1\.1 only, so a ` listener `
must be on ws or httpupgrade, with this as its transport\.path; xhttp and grpc clients speak h2
and go by alpn = “h2” or a catch-all instead\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/ws"
```

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-xver"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.xver

PROXY protocol version sent to dest; 0 sends none\. A listener always gets 2\.

*Type:*
one of 0, 1, 2

*Default:*

```nix
0
```

<a id="services-proxy-suite-inbounds-listeners-name-flow"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.flow

VLESS flow; raw transport only\.

*Type:*
null or value “xtls-rprx-vision” (singular enum)

*Default:*

```nix
null
```

*Example:*

```nix
"xtls-rprx-vision"
```

<a id="services-proxy-suite-inbounds-listeners-name-hysteria-masquerade"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.hysteria\.masquerade

Site that a hysteria2 listener serves, reverse-proxied, to anything that is not a client
(a browser, a prober)\. Null answers them with 404\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"https://www.example.com"
```

<a id="services-proxy-suite-inbounds-listeners-name-jsonfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.jsonFile

Runtime path to a raw XRay inbound (no share link); tag is overridden and port, if left out, filled in\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-inbound-vless.json"
```

<a id="services-proxy-suite-inbounds-listeners-name-method"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.method

Shadowsocks cipher\. 2022 ciphers take a base64 key of matching length as password; more than one user needs a 2022-blake3-aes cipher and serverPassword\.

*Type:*
string

*Default:*

```nix
"2022-blake3-aes-128-gcm"
```

*Example:*

```nix
"aes-128-gcm"
```

<a id="services-proxy-suite-inbounds-listeners-name-port"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.port

Bound port\. A raw-JSON listener’s port must match it: the firewall and the port checks go by this one\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
443
```

<a id="services-proxy-suite-inbounds-listeners-name-reality"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality

REALITY\.

*Type:*
submodule

*Default:*

```nix
{ }
```

<a id="services-proxy-suite-inbounds-listeners-name-reality-enable"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.enable

Enable REALITY\. Exclusive with tls\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-inbounds-listeners-name-reality-dest"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.dest

TLS 1\.3 + HTTP/2 server that unauthenticated probes are forwarded to\.

*Type:*
string

*Default:*

```nix
"www.microsoft.com:443"
```

<a id="services-proxy-suite-inbounds-listeners-name-reality-privatekey"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.privateKey

x25519 private key\. Ends up in the Nix store; prefer privateKeyFile\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"gG1Yz..."
```

<a id="services-proxy-suite-inbounds-listeners-name-reality-privatekeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.privateKeyFile

Runtime path to the x25519 private key (` xray x25519 `)\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-inbound-reality-key"
```

<a id="services-proxy-suite-inbounds-listeners-name-reality-publickey"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.publicKey

x25519 public key, required for share links\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"jNXH..."
```

<a id="services-proxy-suite-inbounds-listeners-name-reality-servernames"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.serverNames

Accepted SNIs, served by dest\. The first goes into share links\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "www.microsoft.com"
]
```

<a id="services-proxy-suite-inbounds-listeners-name-reality-shortids"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.shortIds

Accepted short IDs (hex)\. The first goes into share links\.

*Type:*
list of string

*Default:*

```nix
[
  ""
]
```

*Example:*

```nix
[
  "0123abcd"
]
```

<a id="services-proxy-suite-inbounds-listeners-name-serverpassword"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.serverPassword

Server key of a multi-user shadowsocks 2022 listener, shared by its users\. Ends up in the Nix store; prefer serverPasswordFile\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"c2VydmVyLWtleS0xNmJ5dGU="
```

<a id="services-proxy-suite-inbounds-listeners-name-serverpasswordfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.serverPasswordFile

Runtime path to the server key\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-inbound-ss-server-key"
```

<a id="services-proxy-suite-inbounds-listeners-name-shareport"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.sharePort

Port share links advertise, when something in front owns the public port\. Null uses port\.

*Type:*
null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
null
```

*Example:*

```nix
443
```

<a id="services-proxy-suite-inbounds-listeners-name-tls"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls

TLS termination\.

*Type:*
submodule

*Default:*

```nix
{ }
```

<a id="services-proxy-suite-inbounds-listeners-name-tls-enable"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.enable

Terminate TLS (always on for trojan)\. Exclusive with reality\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-inbounds-listeners-name-tls-alpn"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.alpn

ALPN offered and put in share links\. \[ “h3” ] alone makes an xhttp listener UDP-only, so
a web server can keep the TCP port\.

*Type:*
null or (list of (one of “h3”, “h2”, “http/1\.1”))

*Default:*

```nix
null
```

*Example:*

```nix
[
  "h3"
]
```

<a id="services-proxy-suite-inbounds-listeners-name-tls-certificatefile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.certificateFile

Runtime path to the PEM certificate chain\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/var/lib/acme/example.com/fullchain.pem"
```

<a id="services-proxy-suite-inbounds-listeners-name-tls-keyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.keyFile

Runtime path to the PEM private key\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/var/lib/acme/example.com/key.pem"
```

<a id="services-proxy-suite-inbounds-listeners-name-tls-servername"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.serverName

SNI in share links\. Defaults to inbounds\.serverAddress\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"example.com"
```

<a id="services-proxy-suite-inbounds-listeners-name-transport"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport

Stream transport\.

*Type:*
submodule

*Default:*

```nix
{ }
```

<a id="services-proxy-suite-inbounds-listeners-name-transport-host"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.host

Expected Host header (ws, httpupgrade, xhttp)\. Null accepts any\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"cdn.example.com"
```

<a id="services-proxy-suite-inbounds-listeners-name-transport-mode"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.mode

xhttp mode\. Null lets the client choose; behind an HTTP/1\.1 proxy use “packet-up”\.

*Type:*
null or one of “auto”, “packet-up”, “stream-up”, “stream-one”

*Default:*

```nix
null
```

*Example:*

```nix
"packet-up"
```

<a id="services-proxy-suite-inbounds-listeners-name-transport-path"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.path

Request path (ws, httpupgrade, xhttp)\.

*Type:*
string

*Default:*

```nix
"/"
```

*Example:*

```nix
"/download"
```

<a id="services-proxy-suite-inbounds-listeners-name-transport-servicename"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.serviceName

gRPC service name\.

*Type:*
string

*Default:*

```nix
""
```

*Example:*

```nix
"GunService"
```

<a id="services-proxy-suite-inbounds-listeners-name-transport-trustedxforwardedfor"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.trustedXForwardedFor

Header names that mark a request as coming from the web server in front (ws, httpupgrade,
xhttp, grpc)\. When one of them is present, XRay takes the client address from
“X-Forwarded-For” instead of the socket\. Needed for a listener on a loopback ` address `:
XRay otherwise sees 127\.0\.0\.1, which it refuses to record, so ` proxy-ctl inbounds online `
shows every user as never seen and the stats keep no last-seen time\.

Set it only when the web server in front sets both the named header and “X-Forwarded-For”
on every request it forwards, overwriting whatever the client sent: any client that can
reach the listener directly could otherwise claim any address\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "X-Real-IP"
]
```

<a id="services-proxy-suite-inbounds-listeners-name-transport-type"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.type

Stream transport\. “raw” is plain TCP, the usual choice for REALITY\.

*Type:*
one of “raw”, “ws”, “grpc”, “httpupgrade”, “xhttp”

*Default:*

```nix
"raw"
```

*Example:*

```nix
"ws"
```

<a id="services-proxy-suite-inbounds-listeners-name-type"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.type

Protocol\. Set exactly one of type, xrayJson, or jsonFile\. “amneziawg” is an AmneziaWG
server on UDP port, with its own interface (see amneziaWg); its traffic is handed to XRay
and leaves like any other listener’s\. “hysteria2” is QUIC on UDP port: it needs tls (a
certificate) and takes passwords, and no transport, reality or flow\.

*Type:*
null or one of “vless”, “vmess”, “trojan”, “hysteria2”, “shadowsocks”, “socks”, “http”, “amneziawg”

*Default:*

```nix
null
```

*Example:*

```nix
"vless"
```

<a id="services-proxy-suite-inbounds-listeners-name-users"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users

Accepted accounts\.

*Type:*
list of (submodule)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  {
    uuidFile = "/run/secrets/proxy-inbound-uuid";
  }
]
```

<a id="services-proxy-suite-inbounds-listeners-name-users-address"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.address

AmneziaWG tunnel IPv4 address, inside amneziaWg\.subnet\. Null takes the lowest free one, which
the user keeps for as long as it exists\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"10.66.0.10"
```

<a id="services-proxy-suite-inbounds-listeners-name-users-name"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.name

Account label: the share link’s name, and what subscriptions and stats group by\.

*Type:*
string

*Default:*

```nix
""
```

*Example:*

```nix
"phone"
```

<a id="services-proxy-suite-inbounds-listeners-name-users-password"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.password

Password (trojan, shadowsocks, socks, http)\. Ends up in the Nix store; prefer passwordFile\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"hunter2"
```

<a id="services-proxy-suite-inbounds-listeners-name-users-passwordfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.passwordFile

Runtime path to the password\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-inbound-password"
```

<a id="services-proxy-suite-inbounds-listeners-name-users-presharedkeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.presharedKeyFile

Runtime path to the AmneziaWG preshared key, instead of a generated one\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/awg-phone-psk"
```

<a id="services-proxy-suite-inbounds-listeners-name-users-privatekeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.privateKeyFile

Runtime path to the AmneziaWG client private key, instead of a generated one\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/awg-phone-key"
```

<a id="services-proxy-suite-inbounds-listeners-name-users-publickey"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.publicKey

AmneziaWG public key of a peer that keeps its private key to itself\. It gets no client
config or link\. Null generates a key pair, kept in the state directory\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"jNXH..."
```

<a id="services-proxy-suite-inbounds-listeners-name-users-uuid"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.uuid

UUID (vless, vmess)\. Ends up in the Nix store; prefer uuidFile\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"b831381d-6324-4d53-ad4f-8cda48b30811"
```

<a id="services-proxy-suite-inbounds-listeners-name-users-uuidfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.uuidFile

Runtime path to the UUID\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-inbound-uuid"
```

<a id="services-proxy-suite-inbounds-listeners-name-via"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.via

Egress, as in inbounds\.routing\.via\. Null inherits it\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"nl-vps"
```

<a id="services-proxy-suite-inbounds-listeners-name-xrayjson"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.xrayJson

Raw XRay inbound, built into the store; tag is overridden and port, if left out, filled in\.

*Type:*
null or (attribute set)

*Default:*

```nix
null
```

*Example:*

```nix
{
  protocol = "dokodemo-door";
  settings = {
    port = 8080;
  };
}
```

<a id="services-proxy-suite-inbounds-openfirewall"></a>
## services\.proxy-suite\.inbounds\.openFirewall

Open every non-loopback listener port\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-inbounds-routing-blockprivate"></a>
## services\.proxy-suite\.inbounds\.routing\.blockPrivate

Block private and loopback destinations, so clients cannot reach this host’s LAN or local services\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-inbounds-routing-blockru"></a>
## services\.proxy-suite\.inbounds\.routing\.blockRu

Block Russian destinations (geosite “category-ru”, geoip “ru”)\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-inbounds-routing-proxy-domains"></a>
## services\.proxy-suite\.inbounds\.routing\.proxy\.domains

Domain suffixes to match\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "youtube.com"
]
```

<a id="services-proxy-suite-inbounds-routing-proxy-geoips"></a>
## services\.proxy-suite\.inbounds\.routing\.proxy\.geoips

Geoip names to match (see geodata; the defaults are country codes only)\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "us"
]
```

<a id="services-proxy-suite-inbounds-routing-proxy-geosites"></a>
## services\.proxy-suite\.inbounds\.routing\.proxy\.geosites

Geosite names to match (see geodata)\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "netflix"
]
```

<a id="services-proxy-suite-inbounds-routing-proxy-ips"></a>
## services\.proxy-suite\.inbounds\.routing\.proxy\.ips

IP CIDRs to match\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "1.1.1.0/24"
]
```

<a id="services-proxy-suite-inbounds-routing-via"></a>
## services\.proxy-suite\.inbounds\.routing\.via

Default egress of inbound traffic; listeners can override it:

 - “proxy”: through the local proxy and its current selection (needs proxy\.enable)\.
 - a proxy\.outbounds tag: pinned to that server (url, urlFile or xrayJson outbounds only)\.
 - “direct”: out from this machine\.
 - “block”: dropped\.

*Type:*
string

*Default:*

```nix
"proxy"
```

*Example:*

```nix
"direct"
```

<a id="services-proxy-suite-inbounds-routing-zapretdirect"></a>
## services\.proxy-suite\.inbounds\.routing\.zapretDirect

Send zapret’s hostlist destinations direct, so this host’s zapret unblocks them (default via only)\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-inbounds-serveraddress"></a>
## services\.proxy-suite\.inbounds\.serverAddress

Public address clients connect to, used in share links\. Null detects the uplink IPv4\.

*Type:*
null or string matching the pattern \[^\[:space:]]+

*Default:*

```nix
null
```

*Example:*

```nix
"vpn.example.com"
```

<a id="services-proxy-suite-inbounds-sharelinks"></a>
## services\.proxy-suite\.inbounds\.shareLinks

Write client share links for ` proxy-ctl inbounds link ` (root, and userControl\.group with the secrets scope)\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-inbounds-subscriptions-enable"></a>
## services\.proxy-suite\.inbounds\.subscriptions\.enable

Write one subscription file per user (their links from every listener, base64) to
/run/proxy-suite-inbounds/subscriptions/\<token>\. Serve that directory with a web server;
see the README\.

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

<a id="services-proxy-suite-inbounds-subscriptions-baseurl"></a>
## services\.proxy-suite\.inbounds\.subscriptions\.baseUrl

URL the subscription directory is served at, for ` proxy-ctl inbounds sub `\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"https://vpn.example.com/sub"
```

<a id="services-proxy-suite-inbounds-subscriptions-group"></a>
## services\.proxy-suite\.inbounds\.subscriptions\.group

Group allowed to read the subscription files: the web server serving them\.

*Type:*
string

*Default:*

```nix
"nginx"
```

*Example:*

```nix
"caddy"
```
