# services.proxy-suite.proxy

Part of the [proxy-suite options reference](./index.md).

## Options

- proxy
  - [enable](#services-proxy-suite-proxy-enable)
  - autoProxy
    - [enable](#services-proxy-suite-proxy-autoproxy-enable)
    - [exclude](#services-proxy-suite-proxy-autoproxy-exclude)
    - [interval](#services-proxy-suite-proxy-autoproxy-interval)
    - [maxExits](#services-proxy-suite-proxy-autoproxy-maxexits)
    - [probeBasePort](#services-proxy-suite-proxy-autoproxy-probebaseport)
    - [probesPerRun](#services-proxy-suite-proxy-autoproxy-probesperrun)
    - [slowBelowKiBps](#services-proxy-suite-proxy-autoproxy-slowbelowkibps)
    - [ttlDays](#services-proxy-suite-proxy-autoproxy-ttldays)
  - [autostart](#services-proxy-suite-proxy-autostart)
  - [backend](#services-proxy-suite-proxy-backend)
  - dns
    - [clientSubnet](#services-proxy-suite-proxy-dns-clientsubnet)
    - fakeIp
      - [enable](#services-proxy-suite-proxy-dns-fakeip-enable)
      - [inet4Range](#services-proxy-suite-proxy-dns-fakeip-inet4range)
    - [local](#services-proxy-suite-proxy-dns-local)
      - [address](#services-proxy-suite-proxy-dns-local-address)
      - [port](#services-proxy-suite-proxy-dns-local-port)
      - [type](#services-proxy-suite-proxy-dns-local-type)
    - [remote](#services-proxy-suite-proxy-dns-remote)
      - [address](#services-proxy-suite-proxy-dns-remote-address)
      - [port](#services-proxy-suite-proxy-dns-remote-port)
      - [type](#services-proxy-suite-proxy-dns-remote-type)
    - singBox
      - [rules](#services-proxy-suite-proxy-dns-singbox-rules)
      - [servers](#services-proxy-suite-proxy-dns-singbox-servers)
    - [strategy](#services-proxy-suite-proxy-dns-strategy)
  - listener
    - [address](#services-proxy-suite-proxy-listener-address)
    - auth
      - [password](#services-proxy-suite-proxy-listener-auth-password)
      - [passwordFile](#services-proxy-suite-proxy-listener-auth-passwordfile)
      - [username](#services-proxy-suite-proxy-listener-auth-username)
    - [port](#services-proxy-suite-proxy-listener-port)
  - [outbounds](#services-proxy-suite-proxy-outbounds)
    - item
      - [backend](#services-proxy-suite-proxy-outbounds-backend)
      - [detour](#services-proxy-suite-proxy-outbounds-detour)
      - routing
        - [domains](#services-proxy-suite-proxy-outbounds-routing-domains)
        - [geoips](#services-proxy-suite-proxy-outbounds-routing-geoips)
        - [geosites](#services-proxy-suite-proxy-outbounds-routing-geosites)
        - [ips](#services-proxy-suite-proxy-outbounds-routing-ips)
      - [singBoxJson](#services-proxy-suite-proxy-outbounds-singboxjson)
      - [tag](#services-proxy-suite-proxy-outbounds-tag)
      - [url](#services-proxy-suite-proxy-outbounds-url)
      - [urlFile](#services-proxy-suite-proxy-outbounds-urlfile)
      - [xrayJson](#services-proxy-suite-proxy-outbounds-xrayjson)
  - routing
    - block
      - [domains](#services-proxy-suite-proxy-routing-block-domains)
      - [geoips](#services-proxy-suite-proxy-routing-block-geoips)
      - [geosites](#services-proxy-suite-proxy-routing-block-geosites)
      - [ips](#services-proxy-suite-proxy-routing-block-ips)
    - [default](#services-proxy-suite-proxy-routing-default)
    - direct
      - [domains](#services-proxy-suite-proxy-routing-direct-domains)
      - [geoips](#services-proxy-suite-proxy-routing-direct-geoips)
      - [geosites](#services-proxy-suite-proxy-routing-direct-geosites)
      - [ips](#services-proxy-suite-proxy-routing-direct-ips)
    - [directRu](#services-proxy-suite-proxy-routing-directru)
    - proxy
      - [domains](#services-proxy-suite-proxy-routing-proxy-domains)
      - [geoips](#services-proxy-suite-proxy-routing-proxy-geoips)
      - [geosites](#services-proxy-suite-proxy-routing-proxy-geosites)
      - [ips](#services-proxy-suite-proxy-routing-proxy-ips)
    - [rules](#services-proxy-suite-proxy-routing-rules)
      - item
        - [domains](#services-proxy-suite-proxy-routing-rules-domains)
        - [geoips](#services-proxy-suite-proxy-routing-rules-geoips)
        - [geosites](#services-proxy-suite-proxy-routing-rules-geosites)
        - [ips](#services-proxy-suite-proxy-routing-rules-ips)
        - [outbound](#services-proxy-suite-proxy-routing-rules-outbound)
  - [selection](#services-proxy-suite-proxy-selection)
  - [selectionExclude](#services-proxy-suite-proxy-selectionexclude)
  - singBox
    - [package](#services-proxy-suite-proxy-singbox-package)
    - [clashApiPort](#services-proxy-suite-proxy-singbox-clashapiport)
  - [subscriptionUpdateInterval](#services-proxy-suite-proxy-subscriptionupdateinterval)
  - [subscriptions](#services-proxy-suite-proxy-subscriptions)
    - item
      - [detour](#services-proxy-suite-proxy-subscriptions-detour)
      - [tag](#services-proxy-suite-proxy-subscriptions-tag)
      - [url](#services-proxy-suite-proxy-subscriptions-url)
      - [urlFile](#services-proxy-suite-proxy-subscriptions-urlfile)
  - tproxy
    - [enable](#services-proxy-suite-proxy-tproxy-enable)
    - [fwmark](#services-proxy-suite-proxy-tproxy-fwmark)
    - [localSubnets](#services-proxy-suite-proxy-tproxy-localsubnets)
    - [port](#services-proxy-suite-proxy-tproxy-port)
    - [proxyMark](#services-proxy-suite-proxy-tproxy-proxymark)
    - [routeTable](#services-proxy-suite-proxy-tproxy-routetable)
  - tun
    - [enable](#services-proxy-suite-proxy-tun-enable)
    - [address](#services-proxy-suite-proxy-tun-address)
    - [interface](#services-proxy-suite-proxy-tun-interface)
    - [mtu](#services-proxy-suite-proxy-tun-mtu)
  - urlTest
    - [interval](#services-proxy-suite-proxy-urltest-interval)
    - [tolerance](#services-proxy-suite-proxy-urltest-tolerance)
    - [url](#services-proxy-suite-proxy-urltest-url)
  - xray
    - [package](#services-proxy-suite-proxy-xray-package)

<a id="services-proxy-suite-proxy-enable"></a>
## services\.proxy-suite\.proxy\.enable

Whether to enable the local proxy\.

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

<a id="services-proxy-suite-proxy-autoproxy-enable"></a>
## services\.proxy-suite\.proxy\.autoProxy\.enable

Probe each exit for the destinations clients dial, and route each one through the first
exit that reaches it for as long as it keeps working (` proxy-ctl proxy auto probe ` shows a
verdict)\. Censor-side failures stay direct for zapret\. Needs the sing-box backend, and
makes this host fetch every new destination itself\.

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

<a id="services-proxy-suite-proxy-autoproxy-exclude"></a>
## services\.proxy-suite\.proxy\.autoProxy\.exclude

Domain suffixes never probed or auto-routed\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "internal.example"
]
```

<a id="services-proxy-suite-proxy-autoproxy-interval"></a>
## services\.proxy-suite\.proxy\.autoProxy\.interval

Time between probe runs\. ` proxy-ctl proxy auto learn ` does not wait for it\.

*Type:*
string

*Default:*

```nix
"10m"
```

*Example:*

```nix
"30m"
```

<a id="services-proxy-suite-proxy-autoproxy-maxexits"></a>
## services\.proxy-suite\.proxy\.autoProxy\.maxExits

Most exits probed, direct included\. The first round tries one exit per network (AS), a
second round the rest\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
12
```

<a id="services-proxy-suite-proxy-autoproxy-probebaseport"></a>
## services\.proxy-suite\.proxy\.autoProxy\.probeBasePort

First loopback port of the per-exit probe listeners (one per exit, maxExits in total)\.
They are unauthenticated even when proxy\.listener\.auth is set\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
18540
```

<a id="services-proxy-suite-proxy-autoproxy-probesperrun"></a>
## services\.proxy-suite\.proxy\.autoProxy\.probesPerRun

Most destinations probed per run; the rest wait in a backlog, most-dialled first\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
200
```

<a id="services-proxy-suite-proxy-autoproxy-slowbelowkibps"></a>
## services\.proxy-suite\.proxy\.autoProxy\.slowBelowKiBps

Also route destinations that work directly but crawl: at least 300 KiB in a 10 s sample,
never faster than this\. 0 disables\. Needs ` selection ` other than “first”\.

*Type:*
unsigned integer, meaning >=0

*Default:*

```nix
150
```

*Example:*

```nix
0
```

<a id="services-proxy-suite-proxy-autoproxy-ttldays"></a>
## services\.proxy-suite\.proxy\.autoProxy\.ttlDays

Days a verdict stands, routed destinations included: a route is re-probed once this long
has passed\. Everything is relearned when this host’s public address changes, and
` proxy-ctl proxy auto learn <domain> ` re-probes one destination right away\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
30
```

<a id="services-proxy-suite-proxy-autostart"></a>
## services\.proxy-suite\.proxy\.autostart

Transparent mode started at boot, or null for neither\. The mode named here must
also be enabled (proxy\.tun\.enable or proxy\.tproxy\.enable)\.

*Type:*
null or one of “tun”, “tproxy”

*Default:*

```nix
null
```

*Example:*

```nix
"tun"
```

<a id="services-proxy-suite-proxy-backend"></a>
## services\.proxy-suite\.proxy\.backend

Proxy backend\. “hybrid” runs sing-box in front and hands XRay-only outbounds
(XHTTP, ECH) to XRay\.

*Type:*
one of “sing-box”, “xray”, “hybrid”

*Default:*

```nix
"sing-box"
```

*Example:*

```nix
"hybrid"
```

<a id="services-proxy-suite-proxy-dns-clientsubnet"></a>
## services\.proxy-suite\.proxy\.dns\.clientSubnet

EDNS client subnet sent with every query, so a resolver reached through the proxy still
answers with CDN nodes near this network\. sing-box and hybrid backends\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"203.0.113.0/24"
```

<a id="services-proxy-suite-proxy-dns-fakeip-enable"></a>
## services\.proxy-suite\.proxy\.dns\.fakeIp\.enable

In TUN mode (global and per-app), answer A queries from the TUN with a fake address and
AAAA ones with nothing; sing-box maps the address back to the name when the connection
comes\. Saves a lookup per new site and no real lookup leaves for proxied names\. Names that
proxy\.dns\.singBox\.rules or the direct routing lists send elsewhere keep real answers\. The
addresses handed out are kept in /var/lib/proxy-suite/fakeip, so they survive a restart\.
sing-box and hybrid backends; XRay’s TUN already uses its own fake DNS\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-proxy-dns-fakeip-inet4range"></a>
## services\.proxy-suite\.proxy\.dns\.fakeIp\.inet4Range

Range the fake addresses come from\.

*Type:*
string

*Default:*

```nix
"198.18.0.0/15"
```

<a id="services-proxy-suite-proxy-dns-local"></a>
## services\.proxy-suite\.proxy\.dns\.local

Resolver for direct traffic and the default domain resolver\. Goes through the proxy in global TUN mode\.

*Type:*
submodule

*Default:*

```nix
{
  address = "1.1.1.1";
  port = 53;
  type = "udp";
}
```

*Example:*

```nix
{
  address = "9.9.9.9";
  type = "tcp";
}
```

<a id="services-proxy-suite-proxy-dns-local-address"></a>
## services\.proxy-suite\.proxy\.dns\.local\.address

Resolver address\.

*Type:*
string matching the pattern \.+

*Example:*

```nix
"1.1.1.1"
```

<a id="services-proxy-suite-proxy-dns-local-port"></a>
## services\.proxy-suite\.proxy\.dns\.local\.port

Resolver port\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
53
```

<a id="services-proxy-suite-proxy-dns-local-type"></a>
## services\.proxy-suite\.proxy\.dns\.local\.type

DNS transport\.

*Type:*
one of “udp”, “tcp”, “tls”

*Default:*

```nix
"udp"
```

<a id="services-proxy-suite-proxy-dns-remote"></a>
## services\.proxy-suite\.proxy\.dns\.remote

Resolver used through the proxy; the DNS default when proxy\.routing\.default is proxy\. On
sing-box, names the routing sends through the proxy are always looked up here, so the ISP
never sees them, and direct ones locally\.

*Type:*
submodule

*Default:*

```nix
{
  address = "1.1.1.1";
  port = 53;
  type = "udp";
}
```

*Example:*

```nix
{
  address = "1.1.1.1";
  port = 853;
  type = "tls";
}
```

<a id="services-proxy-suite-proxy-dns-remote-address"></a>
## services\.proxy-suite\.proxy\.dns\.remote\.address

Resolver address\.

*Type:*
string matching the pattern \.+

*Example:*

```nix
"1.1.1.1"
```

<a id="services-proxy-suite-proxy-dns-remote-port"></a>
## services\.proxy-suite\.proxy\.dns\.remote\.port

Resolver port\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
53
```

<a id="services-proxy-suite-proxy-dns-remote-type"></a>
## services\.proxy-suite\.proxy\.dns\.remote\.type

DNS transport\.

*Type:*
one of “udp”, “tcp”, “tls”

*Default:*

```nix
"udp"
```

<a id="services-proxy-suite-proxy-dns-singbox-rules"></a>
## services\.proxy-suite\.proxy\.dns\.singBox\.rules

sing-box DNS rules, as sing-box JSON, checked before the generated ones\. Kept when the
route mode is all-proxy or all-bypass, which drop the generated ones\.

*Type:*
list of (attribute set)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  {
    domain_suffix = [
      "corp.example"
    ];
    server = "corp";
  }
]
```

<a id="services-proxy-suite-proxy-dns-singbox-servers"></a>
## services\.proxy-suite\.proxy\.dns\.singBox\.servers

Extra sing-box DNS servers, as sing-box JSON, for proxy\.dns\.singBox\.rules to name\. The
built-in ones are ` local `, ` remote `, and ` fakeip ` when fakeIp is on\.

*Type:*
list of (attribute set)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  {
    server = "10.0.0.53";
    tag = "corp";
    type = "udp";
  }
]
```

<a id="services-proxy-suite-proxy-dns-strategy"></a>
## services\.proxy-suite\.proxy\.dns\.strategy

Which addresses sing-box asks for\. ` ipv4_only ` for an uplink without IPv6\. sing-box and hybrid backends\.

*Type:*
null or one of “prefer_ipv4”, “prefer_ipv6”, “ipv4_only”, “ipv6_only”

*Default:*

```nix
null
```

*Example:*

```nix
"ipv4_only"
```

<a id="services-proxy-suite-proxy-listener-address"></a>
## services\.proxy-suite\.proxy\.listener\.address

Bind address of the local SOCKS5/HTTP proxy\. Use “0\.0\.0\.0” only to expose it to the network\.

*Type:*
string

*Default:*

```nix
"127.0.0.1"
```

<a id="services-proxy-suite-proxy-listener-auth-password"></a>
## services\.proxy-suite\.proxy\.listener\.auth\.password

Inline local proxy password\. Ends up in the Nix store; prefer passwordFile\.

*Type:*
null or string matching the pattern \[^\[:space:]]+

*Default:*

```nix
null
```

*Example:*

```nix
"change-me"
```

<a id="services-proxy-suite-proxy-listener-auth-passwordfile"></a>
## services\.proxy-suite\.proxy\.listener\.auth\.passwordFile

Runtime path to the local proxy password\. With perAppRouting\.proxychains it must be a
single token, and it is readable by userControl\.group through the proxychains config\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-suite-local-proxy-password"
```

<a id="services-proxy-suite-proxy-listener-auth-username"></a>
## services\.proxy-suite\.proxy\.listener\.auth\.username

Username the local proxy requires\. Set together with password or passwordFile\.

*Type:*
null or string matching the pattern \[^\[:space:]]+

*Default:*

```nix
null
```

*Example:*

```nix
"proxy-user"
```

<a id="services-proxy-suite-proxy-listener-port"></a>
## services\.proxy-suite\.proxy\.listener\.port

Port of the local SOCKS5/HTTP proxy\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
1080
```

<a id="services-proxy-suite-proxy-outbounds"></a>
## services\.proxy-suite\.proxy\.outbounds

Static proxy outbounds\. The proxy needs at least one outbound or subscription to start;
` proxy-ctl proxy outbounds add ` supplies one at runtime if none is declared here\.

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
    tag = "de-vps";
    urlFile = "/run/secrets/proxy-de-url";
  }
  {
    tag = "nl-vps";
    url = "hy2://password@example.com:443?sni=example.com";
  }
]
```

<a id="services-proxy-suite-proxy-outbounds-backend"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.backend

Backend for this outbound when both run\. “auto” prefers sing-box and falls back to XRay
for XRay-only transports (XHTTP, ECH)\.

*Type:*
one of “auto”, “sing-box”, “xray”

*Default:*

```nix
"auto"
```

*Example:*

```nix
"xray"
```

<a id="services-proxy-suite-proxy-outbounds-detour"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.detour

Tag of the outbound this one connects through: a proxy chain\. Any outbound can be the hop,
subscription entries, ` warp `, ` ssh-proxy ` and AmneziaWG ones included\. On hybrid, an
outbound that runs on XRay can only chain through another XRay one\. ShadowTLS works this
way too: a ` shadowtls ` outbound in singBoxJson, and the shadowsocks one with detour naming it\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"ru-vps"
```

<a id="services-proxy-suite-proxy-outbounds-routing-domains"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.domains

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

<a id="services-proxy-suite-proxy-outbounds-routing-geoips"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.geoips

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

<a id="services-proxy-suite-proxy-outbounds-routing-geosites"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.geosites

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

<a id="services-proxy-suite-proxy-outbounds-routing-ips"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.ips

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

<a id="services-proxy-suite-proxy-outbounds-singboxjson"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.singBoxJson

Raw sing-box outbound (sing-box backend); tag is overridden\.

*Type:*
null or (attribute set)

*Default:*

```nix
null
```

*Example:*

```nix
{
  server = "example.com";
  server_port = 443;
  type = "vless";
}
```

<a id="services-proxy-suite-proxy-outbounds-tag"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.tag

Outbound tag, for routing rules and selection\.

*Type:*
string

*Example:*

```nix
"vps-de"
```

<a id="services-proxy-suite-proxy-outbounds-url"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.url

Proxy URL\. Ends up in the Nix store; prefer urlFile\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"hy2://password@example.com:443?sni=example.com"
```

<a id="services-proxy-suite-proxy-outbounds-urlfile"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.urlFile

Runtime path to the proxy URL\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/my-proxy-url"
```

<a id="services-proxy-suite-proxy-outbounds-xrayjson"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.xrayJson

Raw XRay outbound (XRay backend); tag is overridden\.

*Type:*
null or (attribute set)

*Default:*

```nix
null
```

*Example:*

```nix
{
  protocol = "vless";
  settings = {
    address = "example.com";
  };
}
```

<a id="services-proxy-suite-proxy-routing-block-domains"></a>
## services\.proxy-suite\.proxy\.routing\.block\.domains

Domain suffixes blocked\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "ads.example.com"
]
```

<a id="services-proxy-suite-proxy-routing-block-geoips"></a>
## services\.proxy-suite\.proxy\.routing\.block\.geoips

Geoip names blocked\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "cn"
]
```

<a id="services-proxy-suite-proxy-routing-block-geosites"></a>
## services\.proxy-suite\.proxy\.routing\.block\.geosites

Geosite names blocked\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "category-ads-all"
]
```

<a id="services-proxy-suite-proxy-routing-block-ips"></a>
## services\.proxy-suite\.proxy\.routing\.block\.ips

IP CIDRs blocked\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "203.0.113.0/24"
]
```

<a id="services-proxy-suite-proxy-routing-default"></a>
## services\.proxy-suite\.proxy\.routing\.default

Where traffic no routing rule matches goes\.

*Type:*
one of “proxy”, “direct”

*Default:*

```nix
"proxy"
```

*Example:*

```nix
"direct"
```

<a id="services-proxy-suite-proxy-routing-direct-domains"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.domains

Domain suffixes sent direct\. zapret hostlists join them when zapret\.directSync\.enable is on\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "internal.example"
]
```

<a id="services-proxy-suite-proxy-routing-direct-geoips"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.geoips

Geoip names sent direct\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "ru"
]
```

<a id="services-proxy-suite-proxy-routing-direct-geosites"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.geosites

Geosite names sent direct\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "category-ru"
]
```

<a id="services-proxy-suite-proxy-routing-direct-ips"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.ips

IP CIDRs sent direct\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "10.10.0.0/16"
]
```

<a id="services-proxy-suite-proxy-routing-directru"></a>
## services\.proxy-suite\.proxy\.routing\.directRu

Send geosite “category-ru” and geoip “ru” direct\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-proxy-routing-proxy-domains"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.domains

Domain suffixes sent through the proxy\.

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

<a id="services-proxy-suite-proxy-routing-proxy-geoips"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.geoips

Geoip names sent through the proxy\.

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

<a id="services-proxy-suite-proxy-routing-proxy-geosites"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.geosites

Geosite names sent through the proxy\.

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

<a id="services-proxy-suite-proxy-routing-proxy-ips"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.ips

IP CIDRs sent through the proxy\.

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

<a id="services-proxy-suite-proxy-routing-rules"></a>
## services\.proxy-suite\.proxy\.routing\.rules

Rules checked before the proxy/direct/block lists, in order; the first match wins\.

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
    geosites = [
      "netflix"
    ];
    outbound = "vps-de";
  }
  {
    domains = [
      "internal.corp"
    ];
    outbound = "direct";
  }
]
```

<a id="services-proxy-suite-proxy-routing-rules-domains"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.domains

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

<a id="services-proxy-suite-proxy-routing-rules-geoips"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.geoips

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

<a id="services-proxy-suite-proxy-routing-rules-geosites"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.geosites

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

<a id="services-proxy-suite-proxy-routing-rules-ips"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.ips

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

<a id="services-proxy-suite-proxy-routing-rules-outbound"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.outbound

Outbound tag, or “proxy”, “direct”, “block”\. With selection = “first” every proxy tag means “proxy”\.

*Type:*
string

*Example:*

```nix
"vps-de"
```

<a id="services-proxy-suite-proxy-selection"></a>
## services\.proxy-suite\.proxy\.selection

How to pick among outbounds:

 - “first”: one at a time - the pinned outbound, or the first available\.
 - “selector”: all of them, pick by hand\.
 - “urltest”: all of them, ranked by latency unless one is pinned\.

` proxy-ctl proxy pin ` pins an outbound in every mode, and the pin outlives a restart\.
“selector” and “urltest” switch without restarting the backend (sing-box only); “first”
and XRay restart it\.

*Type:*
one of “first”, “selector”, “urltest”

*Default:*

```nix
"first"
```

*Example:*

```nix
"urltest"
```

<a id="services-proxy-suite-proxy-selectionexclude"></a>
## services\.proxy-suite\.proxy\.selectionExclude

Outbound tags selection never picks on its own: hops other outbounds chain through
(` detour `), or exits only routing rules name\. Subscription entries, ` warp `, ` ssh-proxy `
and AmneziaWG tags work too\. A pin still reaches them, and so does a selector switched by
hand\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "ru-vps"
  "warp"
]
```

<a id="services-proxy-suite-proxy-singbox-package"></a>
## services\.proxy-suite\.proxy\.singBox\.package

sing-box package, used when backend is “sing-box” or “hybrid”\.

*Type:*
package

*Default:*
` sing-box ` from proxy-suite’s own ` nixpkgs ` input

*Example:*

```nix
pkgs.sing-box
```

<a id="services-proxy-suite-proxy-singbox-clashapiport"></a>
## services\.proxy-suite\.proxy\.singBox\.clashApiPort

Loopback port of sing-box’s Clash API, which switches and tests outbounds\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
9090
```

<a id="services-proxy-suite-proxy-subscriptionupdateinterval"></a>
## services\.proxy-suite\.proxy\.subscriptionUpdateInterval

How often subscriptions are refreshed (systemd time span)\.

*Type:*
string

*Default:*

```nix
"1d"
```

*Example:*

```nix
"6h"
```

<a id="services-proxy-suite-proxy-subscriptions"></a>
## services\.proxy-suite\.proxy\.subscriptions

Subscription URLs serving a base64 or plain list of proxy URIs\. Fetched on first start,
cached under /var/lib/proxy-suite/subscriptions, refreshed by a timer\. Ones added with
` proxy-ctl proxy subs add ` live in /var/lib/proxy-suite/subscriptions\.d and refresh alongside\.

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
    tag = "private";
    urlFile = "/run/secrets/private-sub-url";
  }
]
```

<a id="services-proxy-suite-proxy-subscriptions-detour"></a>
## services\.proxy-suite\.proxy\.subscriptions\.\*\.detour

Tag of the outbound every entry of this subscription connects through: a proxy chain\. Any outbound can be the hop,
subscription entries, ` warp `, ` ssh-proxy ` and AmneziaWG ones included\. On hybrid, an
outbound that runs on XRay can only chain through another XRay one\. ShadowTLS works this
way too: a ` shadowtls ` outbound in singBoxJson, and the shadowsocks one with detour naming it\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"ru-vps"
```

<a id="services-proxy-suite-proxy-subscriptions-tag"></a>
## services\.proxy-suite\.proxy\.subscriptions\.\*\.tag

Unique name; prefixes the tags of its outbounds and names its cache file\.

*Type:*
string matching the pattern ^\[A-Za-z0-9]\[A-Za-z0-9\._-]\*$

*Example:*

```nix
"community-list"
```

<a id="services-proxy-suite-proxy-subscriptions-url"></a>
## services\.proxy-suite\.proxy\.subscriptions\.\*\.url

Subscription URL\. Ends up in the Nix store; prefer urlFile\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"https://example.com/sub/token123"
```

<a id="services-proxy-suite-proxy-subscriptions-urlfile"></a>
## services\.proxy-suite\.proxy\.subscriptions\.\*\.urlFile

Runtime path to the subscription URL\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-subscription-url"
```

<a id="services-proxy-suite-proxy-tproxy-enable"></a>
## services\.proxy-suite\.proxy\.tproxy\.enable

Whether to enable global TProxy mode (proxy-suite-tproxy)\.

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

<a id="services-proxy-suite-proxy-tproxy-fwmark"></a>
## services\.proxy-suite\.proxy\.tproxy\.fwmark

Mark of intercepted packets, routed through routeTable\.

*Type:*
signed integer

*Default:*

```nix
1
```

<a id="services-proxy-suite-proxy-tproxy-localsubnets"></a>
## services\.proxy-suite\.proxy\.tproxy\.localSubnets

Subnets that bypass interception (DNS excepted): your LAN, VM bridges\.

*Type:*
list of string

*Default:*

```nix
[
  "192.168.0.0/16"
]
```

*Example:*

```nix
[
  "192.168.0.0/16"
  "10.0.0.0/8"
]
```

<a id="services-proxy-suite-proxy-tproxy-port"></a>
## services\.proxy-suite\.proxy\.tproxy\.port

Port of the TProxy inbound\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
1085
```

<a id="services-proxy-suite-proxy-tproxy-proxymark"></a>
## services\.proxy-suite\.proxy\.tproxy\.proxyMark

Mark of the backend’s own traffic, so it is not intercepted again\.

*Type:*
signed integer

*Default:*

```nix
2
```

<a id="services-proxy-suite-proxy-tproxy-routetable"></a>
## services\.proxy-suite\.proxy\.tproxy\.routeTable

Policy-routing table for intercepted traffic\.

*Type:*
signed integer

*Default:*

```nix
100
```

<a id="services-proxy-suite-proxy-tun-enable"></a>
## services\.proxy-suite\.proxy\.tun\.enable

Whether to enable global TUN mode (proxy-suite-tun)\.

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

<a id="services-proxy-suite-proxy-tun-address"></a>
## services\.proxy-suite\.proxy\.tun\.address

TUN interface address (CIDR)\.

*Type:*
string

*Default:*

```nix
"172.19.0.1/30"
```

<a id="services-proxy-suite-proxy-tun-interface"></a>
## services\.proxy-suite\.proxy\.tun\.interface

TUN interface name\.

*Type:*
string

*Default:*

```nix
"singtun0"
```

<a id="services-proxy-suite-proxy-tun-mtu"></a>
## services\.proxy-suite\.proxy\.tun\.mtu

TUN interface MTU\.

*Type:*
signed integer

*Default:*

```nix
1400
```

<a id="services-proxy-suite-proxy-urltest-interval"></a>
## services\.proxy-suite\.proxy\.urlTest\.interval

How often outbounds are re-tested (Go duration)\.

*Type:*
string

*Default:*

```nix
"3m"
```

*Example:*

```nix
"1m"
```

<a id="services-proxy-suite-proxy-urltest-tolerance"></a>
## services\.proxy-suite\.proxy\.urlTest\.tolerance

Milliseconds a faster outbound must win by to replace the current one (sing-box only)\.

*Type:*
signed integer

*Default:*

```nix
50
```

*Example:*

```nix
100
```

<a id="services-proxy-suite-proxy-urltest-url"></a>
## services\.proxy-suite\.proxy\.urlTest\.url

URL fetched through each outbound to rank them\. Pick one blocked in your region\.

*Type:*
string

*Default:*

```nix
"https://www.gstatic.com/generate_204"
```

*Example:*

```nix
"https://telegram.org"
```

<a id="services-proxy-suite-proxy-xray-package"></a>
## services\.proxy-suite\.proxy\.xray\.package

XRay package, used when backend is “xray” or “hybrid”\.

*Type:*
package

*Default:*
proxy-suite’s ` xray ` (` pkgs/xray.nix `)

*Example:*

```nix
pkgs.xray
```
