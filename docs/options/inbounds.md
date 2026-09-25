# services.proxy-suite.inbounds

Server side: listeners for remote clients, share links, subscriptions and stats.

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

Whether to enable server inbounds, which accept proxy clients from outside\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-inbounds-package"></a>
## services\.proxy-suite\.inbounds\.package

XRay package that runs the inbounds, whichever client backend is used\.

**Type:** package\
**Default:** proxy-suite’s ` xray ` (` pkgs/xray.nix `)\
**Example:** `pkgs.xray`

<a id="services-proxy-suite-inbounds-listeners"></a>
## services\.proxy-suite\.inbounds\.listeners

Server listeners, by tag\.

**Type:** attribute set of (submodule)\
**Default:** `{ }`\
**Example:**

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

Listening address\. A loopback address keeps the port closed in the firewall\.

**Type:** string matching the pattern \[^\[:space:]]+\
**Default:** `"::"`\
**Example:** `"127.0.0.1"`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg

AmneziaWG server settings, for ` type = "amneziawg" `\.

**Type:** submodule\
**Default:** `{ }`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-clientallowedips"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.clientAllowedIPs

AllowedIPs in client configs: what clients send through the tunnel\.

**Type:** list of string\
**Default:** `[ "0.0.0.0/0" "::/0" ]`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-dns"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.dns

DNS servers in client configs\. Queries exit like any other traffic\.

**Type:** list of string\
**Default:** `[ "1.1.1.1" "1.0.0.1" ]`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-interfacename"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.interfaceName

Interface name, at most 15 characters\.

**Type:** string matching the pattern ^\[A-Za-z0-9_\.-]+$\
**Default:** `"awgi-<tag>"`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-mode"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.mode

What clients can reach besides the internet, which always goes through the listener’s ` via `:

 - “proxy”: nothing else\. This host, its LAN and other peers are cut off\.
 - “lan”: also this host, its LAN and other peers, directly\. Turns on IP forwarding\.
   Only TCP and UDP reach the internet; ping and other protocols are dropped\.

**Type:** one of “proxy”, “lan”\
**Default:** `"proxy"`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-mtu"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.mtu

Interface MTU on both ends\. ` null `: awg-quick’s default (1280 with AWG 3 fields)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation

Obfuscation parameters, shared with every client\. Jc, Jmin, Jmax, S1, S2 and H1-H4 are
generated once if left ` null `; the rest stay unset\.

**Type:** submodule\
**Default:** `{ }`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-contentpaddingaddition"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.contentPaddingAddition

AWG 3 content-padding addition or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-disablecookies"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.disableCookies

AWG 3 cookie suppression (DisableCookies)\.

**Type:** null or boolean\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h1"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.h1

Handshake-init header or range (H1)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h2"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.h2

Handshake-response header or range (H2)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h3"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.h3

Cookie-reply header or range (H3)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-h4"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.h4

Transport-message header or range (H4)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-headerprotectionkey"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.headerProtectionKey

AWG 3 header-protection key\. Ends up in the Nix store; prefer ` headerProtectionKeyFile `\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-headerprotectionkeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.headerProtectionKeyFile

File with the AWG 3 header-protection key\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i1"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i1

First custom signature packet (I1)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i2"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i2

Second custom signature packet (I2)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i3"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i3

Third custom signature packet (I3)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i4"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i4

Fourth custom signature packet (I4)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-i5"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.i5

Fifth custom signature packet (I5)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jc"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.jc

Junk packet count (Jc)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jmax"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.jmax

Maximum junk packet size (Jmax)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-jmin"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.jmin

Minimum junk packet size (Jmin)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-keepalivetimeout"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.keepaliveTimeout

AWG 3 keepalive timeout or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-maxhandshakeattempts"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.maxHandshakeAttempts

AWG 3 maximum handshake attempts or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-randomtrailers"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.randomTrailers

AWG 3 random transport trailers (RandomTrailers)\.

**Type:** null or boolean\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rejectaftertime"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.rejectAfterTime

AWG 3 reject-after interval or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rekeyaftertime"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.rekeyAfterTime

AWG 3 rekey interval or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-rekeytimeout"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.rekeyTimeout

AWG 3 rekey timeout or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s1"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.s1

Handshake-init padding (S1)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s2"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.s2

Handshake-response padding (S2)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s3"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.s3

Cookie-reply padding (S3)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-obfuscation-s4"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.obfuscation\.s4

Transport-message padding (S4)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-persistentkeepalive"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.persistentKeepalive

PersistentKeepalive in client configs, which keeps NAT open\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `25`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-privatekeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.privateKeyFile

File with the server private key, instead of a generated one\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/awg-server-key"`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-subnet"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.subnet

Tunnel IPv4 subnet, private and unused elsewhere\. This host takes the first address,
clients the rest\.

**Type:** string matching the pattern \[0-9\.]+/\[0-9]+\
**Default:** `"10.66.0.0/24"`

<a id="services-proxy-suite-inbounds-listeners-name-amneziawg-subnet6"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.amneziaWg\.subnet6

Tunnel IPv6 subnet (ULA)\. ` null `: IPv4 only\. With ` mode = "lan" ` it turns on IPv6
forwarding, which stops this host from configuring itself from router advertisements\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"fd66:66::/64"`

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks

Where to send connections that are not this listener’s protocol, so several services
share one port (vless or trojan on raw transport)\. Entries match in order by SNI, ALPN
and path; one with none of these is the catch-all, such as a decoy site\. Browsers use h2
by default, so an HTTP/1\.1-only ` dest ` needs ` tls.alpn = [ "http/1.1" ] `\.

**Type:** list of (submodule)\
**Default:** `[ ]`\
**Example:**

```nix
[
  { path = "/ws"; listener = "ws-in"; }  # ws-in: vless, ws, address = "127.0.0.1"
  { dest = 8080; }
]

```

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-alpn"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.alpn

ALPN to match\. ` null `: any\.

**Type:** null or one of “h2”, “http/1\.1”\
**Default:** `null`\
**Example:** `"h2"`

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-dest"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.dest

Where matching connections go: a port, host:port or unix socket path\. Cannot be used with ` listener `\.

**Type:** null or 16 bit unsigned integer; between 0 and 65535 (both inclusive) or string\
**Default:** `null`\
**Example:** `"127.0.0.1:8080"`

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-listener"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.listener

Another listener to hand matching connections to, instead of ` dest `\. It must be a vless
listener on loopback, without tls or reality\. It gets decrypted traffic, and its share
links use this listener’s port and TLS or REALITY\. Behind REALITY it must use xhttp or grpc\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"ws-in"`

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-name"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.name

SNI to match\. ` null `: any\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"www.example.com"`

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-path"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.path

Request path to match\. ` null `: any\. Works for HTTP/1\.1 only, so the target ` listener ` must
use ws or httpupgrade with this as its ` transport.path `\. For xhttp and grpc (h2), match
` alpn = "h2" ` or use a catch-all\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/ws"`

<a id="services-proxy-suite-inbounds-listeners-name-fallbacks-xver"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.fallbacks\.\*\.xver

PROXY protocol version sent to ` dest `, or 0 for none\. A ` listener ` always gets 2\.

**Type:** one of 0, 1, 2\
**Default:** `0`

<a id="services-proxy-suite-inbounds-listeners-name-flow"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.flow

VLESS flow\. Raw transport only\.

**Type:** null or value “xtls-rprx-vision” (singular enum)\
**Default:** `null`\
**Example:** `"xtls-rprx-vision"`

<a id="services-proxy-suite-inbounds-listeners-name-hysteria-masquerade"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.hysteria\.masquerade

Site shown to anything that is not a hysteria2 client, such as browsers and probes\.
` null `: answer 404\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"https://www.example.com"`

<a id="services-proxy-suite-inbounds-listeners-name-jsonfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.jsonFile

File with a raw XRay inbound JSON (no share link)\. Its tag is replaced; a missing port is filled in\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-inbound-vless.json"`

<a id="services-proxy-suite-inbounds-listeners-name-method"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.method

Shadowsocks cipher\. 2022 ciphers take a base64 key of matching length as the password\. Multiple users need a 2022-blake3-aes cipher and ` serverPassword `\.

**Type:** string\
**Default:** `"2022-blake3-aes-128-gcm"`\
**Example:** `"aes-128-gcm"`

<a id="services-proxy-suite-inbounds-listeners-name-port"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.port

Listening port\. For raw JSON listeners it must match the JSON; the firewall uses this one\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `443`

<a id="services-proxy-suite-inbounds-listeners-name-reality"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality

REALITY settings\.

**Type:** submodule\
**Default:** `{ }`

<a id="services-proxy-suite-inbounds-listeners-name-reality-enable"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.enable

Enable REALITY\. Cannot be used with ` tls `\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-inbounds-listeners-name-reality-dest"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.dest

Real TLS 1\.3 + HTTP/2 site that non-client connections are forwarded to\.

**Type:** string\
**Default:** `"www.microsoft.com:443"`

<a id="services-proxy-suite-inbounds-listeners-name-reality-privatekey"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.privateKey

x25519 private key\. Ends up in the Nix store; prefer ` privateKeyFile `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"gG1Yz..."`

<a id="services-proxy-suite-inbounds-listeners-name-reality-privatekeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.privateKeyFile

File with the x25519 private key (from ` xray x25519 `)\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-inbound-reality-key"`

<a id="services-proxy-suite-inbounds-listeners-name-reality-publickey"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.publicKey

x25519 public key, needed for share links\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"jNXH..."`

<a id="services-proxy-suite-inbounds-listeners-name-reality-servernames"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.serverNames

Accepted SNIs, served by ` dest `\. The first goes into share links\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "www.microsoft.com" ]`

<a id="services-proxy-suite-inbounds-listeners-name-reality-shortids"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.reality\.shortIds

Accepted short IDs (hex)\. The first goes into share links\.

**Type:** list of string\
**Default:** `[ "" ]`\
**Example:** `[ "0123abcd" ]`

<a id="services-proxy-suite-inbounds-listeners-name-serverpassword"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.serverPassword

Shared server key of a multi-user shadowsocks 2022 listener\. Ends up in the Nix store; prefer ` serverPasswordFile `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"c2VydmVyLWtleS0xNmJ5dGU="`

<a id="services-proxy-suite-inbounds-listeners-name-serverpasswordfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.serverPasswordFile

File with the server key\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-inbound-ss-server-key"`

<a id="services-proxy-suite-inbounds-listeners-name-shareport"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.sharePort

Port in share links, if something in front owns the public port\. ` null `: ` port `\.

**Type:** null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `null`\
**Example:** `443`

<a id="services-proxy-suite-inbounds-listeners-name-tls"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls

TLS settings\.

**Type:** submodule\
**Default:** `{ }`

<a id="services-proxy-suite-inbounds-listeners-name-tls-enable"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.enable

Terminate TLS (always on for trojan)\. Cannot be used with ` reality `\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-inbounds-listeners-name-tls-alpn"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.alpn

ALPN offered and put in share links\. ` [ "h3" ] ` alone makes an xhttp listener UDP-only,
leaving the TCP port to a web server\.

**Type:** null or (list of (one of “h3”, “h2”, “http/1\.1”))\
**Default:** `null`\
**Example:** `[ "h3" ]`

<a id="services-proxy-suite-inbounds-listeners-name-tls-certificatefile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.certificateFile

File with the PEM certificate chain\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/var/lib/acme/example.com/fullchain.pem"`

<a id="services-proxy-suite-inbounds-listeners-name-tls-keyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.keyFile

File with the PEM private key\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/var/lib/acme/example.com/key.pem"`

<a id="services-proxy-suite-inbounds-listeners-name-tls-servername"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.tls\.serverName

SNI in share links\. Defaults to ` inbounds.serverAddress `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"example.com"`

<a id="services-proxy-suite-inbounds-listeners-name-transport"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport

Transport settings\.

**Type:** submodule\
**Default:** `{ }`

<a id="services-proxy-suite-inbounds-listeners-name-transport-host"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.host

Expected Host header (ws, httpupgrade, xhttp)\. ` null `: any\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"cdn.example.com"`

<a id="services-proxy-suite-inbounds-listeners-name-transport-mode"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.mode

xhttp mode\. ` null `: the client chooses\. Behind an HTTP/1\.1 proxy, use “packet-up”\.

**Type:** null or one of “auto”, “packet-up”, “stream-up”, “stream-one”\
**Default:** `null`\
**Example:** `"packet-up"`

<a id="services-proxy-suite-inbounds-listeners-name-transport-path"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.path

Request path (ws, httpupgrade, xhttp)\.

**Type:** string\
**Default:** `"/"`\
**Example:** `"/download"`

<a id="services-proxy-suite-inbounds-listeners-name-transport-servicename"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.serviceName

gRPC service name\.

**Type:** string\
**Default:** `""`\
**Example:** `"GunService"`

<a id="services-proxy-suite-inbounds-listeners-name-transport-trustedxforwardedfor"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.trustedXForwardedFor

Headers that mark a request as coming from your web server (ws, httpupgrade, xhttp,
grpc)\. If one is present, XRay takes the client address from “X-Forwarded-For”\. Needed
behind a web server on loopback, or ` proxy-ctl inbounds online ` and the stats show no
client addresses\.

Only set it if the web server overwrites both headers on every request\. Otherwise any
client that reaches the listener directly can fake its address\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "X-Real-IP" ]`

<a id="services-proxy-suite-inbounds-listeners-name-transport-type"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.transport\.type

Stream transport\. “raw” is plain TCP, the usual pick for REALITY\.

**Type:** one of “raw”, “ws”, “grpc”, “httpupgrade”, “xhttp”\
**Default:** `"raw"`\
**Example:** `"ws"`

<a id="services-proxy-suite-inbounds-listeners-name-type"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.type

Protocol\. Set exactly one of ` type `, ` xrayJson ` or ` jsonFile `\.

 - “amneziawg”: an AmneziaWG server on a UDP port (see ` amneziaWg `)\. Its traffic exits
   like any other listener’s\.
 - “hysteria2”: QUIC on a UDP port\. Needs ` tls ` and passwords; no transport, reality or flow\.

**Type:** null or one of “vless”, “vmess”, “trojan”, “hysteria2”, “shadowsocks”, “socks”, “http”, “amneziawg”\
**Default:** `null`\
**Example:** `"vless"`

<a id="services-proxy-suite-inbounds-listeners-name-users"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users

Accepted users\.

**Type:** list of (submodule)\
**Default:** `[ ]`\
**Example:** `[ { uuidFile = "/run/secrets/proxy-inbound-uuid"; } ]`

<a id="services-proxy-suite-inbounds-listeners-name-users-address"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.address

AmneziaWG tunnel IPv4 address, inside ` amneziaWg.subnet `\. ` null `: the lowest free one,
kept for as long as the user exists\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"10.66.0.10"`

<a id="services-proxy-suite-inbounds-listeners-name-users-name"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.name

User name, shown in share links, subscriptions and stats\.

**Type:** string\
**Default:** `""`\
**Example:** `"phone"`

<a id="services-proxy-suite-inbounds-listeners-name-users-password"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.password

Password (trojan, shadowsocks, socks, http)\. Ends up in the Nix store; prefer ` passwordFile `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"hunter2"`

<a id="services-proxy-suite-inbounds-listeners-name-users-passwordfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.passwordFile

File with the password\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-inbound-password"`

<a id="services-proxy-suite-inbounds-listeners-name-users-presharedkeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.presharedKeyFile

File with the AmneziaWG preshared key, instead of a generated one\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/awg-phone-psk"`

<a id="services-proxy-suite-inbounds-listeners-name-users-privatekeyfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.privateKeyFile

File with the AmneziaWG client private key, instead of a generated one\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/awg-phone-key"`

<a id="services-proxy-suite-inbounds-listeners-name-users-publickey"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.publicKey

AmneziaWG public key, for a client that keeps its own private key (no config or link is
generated for it)\. ` null `: generate a key pair\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"jNXH..."`

<a id="services-proxy-suite-inbounds-listeners-name-users-uuid"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.uuid

UUID (vless, vmess)\. Ends up in the Nix store; prefer ` uuidFile `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"b831381d-6324-4d53-ad4f-8cda48b30811"`

<a id="services-proxy-suite-inbounds-listeners-name-users-uuidfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.users\.\*\.uuidFile

File with the UUID\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-inbound-uuid"`

<a id="services-proxy-suite-inbounds-listeners-name-via"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.via

Where this listener’s traffic exits, as in ` inbounds.routing.via `\. ` null `: use that default\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"nl-vps"`

<a id="services-proxy-suite-inbounds-listeners-name-xrayjson"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.xrayJson

Raw XRay inbound JSON (ends up in the Nix store)\. Its tag is replaced; a missing port is filled in\.

**Type:** null or (attribute set)\
**Default:** `null`\
**Example:** `{ protocol = "dokodemo-door"; settings = { port = 8080; }; }`

<a id="services-proxy-suite-inbounds-openfirewall"></a>
## services\.proxy-suite\.inbounds\.openFirewall

Open the firewall for every listener not on loopback\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-inbounds-routing-blockprivate"></a>
## services\.proxy-suite\.inbounds\.routing\.blockPrivate

Block private and loopback addresses, so clients cannot reach this host’s LAN or local services\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-inbounds-routing-blockru"></a>
## services\.proxy-suite\.inbounds\.routing\.blockRu

Block Russian destinations (geosite “category-ru”, geoip “ru”)\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-inbounds-routing-proxy-domains"></a>
## services\.proxy-suite\.inbounds\.routing\.proxy\.domains

Domains, with their subdomains, that clients always reach through the local proxy, whatever the listener’s ` via `\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "youtube.com" ]`

<a id="services-proxy-suite-inbounds-routing-proxy-geoips"></a>
## services\.proxy-suite\.inbounds\.routing\.proxy\.geoips

Geoip codes that clients always reach through the local proxy, whatever the listener’s ` via `; countries by default (see ` geodata `)\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "us" ]`

<a id="services-proxy-suite-inbounds-routing-proxy-geosites"></a>
## services\.proxy-suite\.inbounds\.routing\.proxy\.geosites

Geosite categories that clients always reach through the local proxy, whatever the listener’s ` via ` (see ` geodata `)\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "netflix" ]`

<a id="services-proxy-suite-inbounds-routing-proxy-ips"></a>
## services\.proxy-suite\.inbounds\.routing\.proxy\.ips

IP ranges (CIDR) that clients always reach through the local proxy, whatever the listener’s ` via `\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "1.1.1.0/24" ]`

<a id="services-proxy-suite-inbounds-routing-via"></a>
## services\.proxy-suite\.inbounds\.routing\.via

Where client traffic exits by default\. Each listener can override it\.

 - “proxy”: through the local proxy and its current pick (needs ` proxy.enable `)\.
 - an outbound tag from ` proxy.outbounds `: always that one (` url `, ` urlFile ` or ` xrayJson ` only)\.
 - “direct”: straight from this host\.
 - “block”: dropped\.

**Type:** string\
**Default:** `"proxy"`\
**Example:** `"direct"`

<a id="services-proxy-suite-inbounds-routing-zapretdirect"></a>
## services\.proxy-suite\.inbounds\.routing\.zapretDirect

Send zapret hostlist sites direct, so this host’s zapret unblocks them\. Only for the default ` via `\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-inbounds-serveraddress"></a>
## services\.proxy-suite\.inbounds\.serverAddress

Public address for share links\. ` null `: detect the uplink IPv4\.

**Type:** null or string matching the pattern \[^\[:space:]]+\
**Default:** `null`\
**Example:** `"vpn.example.com"`

<a id="services-proxy-suite-inbounds-sharelinks"></a>
## services\.proxy-suite\.inbounds\.shareLinks

Generate client share links for ` proxy-ctl inbounds link `\. Readable by root, and by ` userControl.group ` with the secrets scope\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-inbounds-subscriptions-enable"></a>
## services\.proxy-suite\.inbounds\.subscriptions\.enable

Generate a subscription per user, with their links from every listener, in
/run/proxy-suite-inbounds/subscriptions/\<token>\. Serve that directory with a web server\.
Needs ` shareLinks `\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-inbounds-subscriptions-baseurl"></a>
## services\.proxy-suite\.inbounds\.subscriptions\.baseUrl

Public URL of the subscription directory, used by ` proxy-ctl inbounds sub `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"https://vpn.example.com/sub"`

<a id="services-proxy-suite-inbounds-subscriptions-group"></a>
## services\.proxy-suite\.inbounds\.subscriptions\.group

Group of the web server that serves the subscription files\.

**Type:** string\
**Default:** `"nginx"`\
**Example:** `"caddy"`
