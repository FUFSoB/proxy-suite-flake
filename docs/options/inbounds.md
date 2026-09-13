# services.proxy-suite.inbounds

Part of the [proxy-suite options reference](./index.md).

## Options

- inbounds
  - [enable](#services-proxy-suite-inbounds-enable)
  - [package](#services-proxy-suite-inbounds-package)
  - [listeners](#services-proxy-suite-inbounds-listeners)
    - `<name>`
      - [address](#services-proxy-suite-inbounds-listeners-name-address)
      - [flow](#services-proxy-suite-inbounds-listeners-name-flow)
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
        - [type](#services-proxy-suite-inbounds-listeners-name-transport-type)
      - [type](#services-proxy-suite-inbounds-listeners-name-type)
      - [users](#services-proxy-suite-inbounds-listeners-name-users)
        - item
          - [name](#services-proxy-suite-inbounds-listeners-name-users-name)
          - [password](#services-proxy-suite-inbounds-listeners-name-users-password)
          - [passwordFile](#services-proxy-suite-inbounds-listeners-name-users-passwordfile)
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

```nix
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
}

```

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

<a id="services-proxy-suite-inbounds-listeners-name-jsonfile"></a>
## services\.proxy-suite\.inbounds\.listeners\.\<name>\.jsonFile

Runtime path to a raw XRay inbound (no share link); tag is overridden\.

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

Shadowsocks cipher\. 2022 ciphers take a base64 key of matching length as password\.

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

Bound port\.

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

Protocol\. Set exactly one of type, xrayJson, or jsonFile\.

*Type:*
null or one of “vless”, “vmess”, “trojan”, “shadowsocks”, “socks”, “http”

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

Raw XRay inbound, built into the store; tag is overridden\.

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

Write client share links for ` proxy-ctl inbounds link ` (root and userControl\.group only)\.

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
