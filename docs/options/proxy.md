# services.proxy-suite.proxy

The local proxy: outbounds, subscriptions, selection, routing, DNS, TUN and TProxy.

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
  - [ipv6](#services-proxy-suite-proxy-ipv6)
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
        - [ruleSets](#services-proxy-suite-proxy-outbounds-routing-rulesets)
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
      - [ruleSets](#services-proxy-suite-proxy-routing-block-rulesets)
    - [default](#services-proxy-suite-proxy-routing-default)
    - direct
      - [domains](#services-proxy-suite-proxy-routing-direct-domains)
      - [geoips](#services-proxy-suite-proxy-routing-direct-geoips)
      - [geosites](#services-proxy-suite-proxy-routing-direct-geosites)
      - [ips](#services-proxy-suite-proxy-routing-direct-ips)
      - [ruleSets](#services-proxy-suite-proxy-routing-direct-rulesets)
    - [directRu](#services-proxy-suite-proxy-routing-directru)
    - proxy
      - [domains](#services-proxy-suite-proxy-routing-proxy-domains)
      - [geoips](#services-proxy-suite-proxy-routing-proxy-geoips)
      - [geosites](#services-proxy-suite-proxy-routing-proxy-geosites)
      - [ips](#services-proxy-suite-proxy-routing-proxy-ips)
      - [ruleSets](#services-proxy-suite-proxy-routing-proxy-rulesets)
    - [ruleSetUpdateInterval](#services-proxy-suite-proxy-routing-rulesetupdateinterval)
    - [ruleSets](#services-proxy-suite-proxy-routing-rulesets)
      - `<name>`
        - [detour](#services-proxy-suite-proxy-routing-rulesets-name-detour)
        - [format](#services-proxy-suite-proxy-routing-rulesets-name-format)
        - [url](#services-proxy-suite-proxy-routing-rulesets-name-url)
    - [rules](#services-proxy-suite-proxy-routing-rules)
      - item
        - [domains](#services-proxy-suite-proxy-routing-rules-domains)
        - [geoips](#services-proxy-suite-proxy-routing-rules-geoips)
        - [geosites](#services-proxy-suite-proxy-routing-rules-geosites)
        - [ips](#services-proxy-suite-proxy-routing-rules-ips)
        - [outbound](#services-proxy-suite-proxy-routing-rules-outbound)
        - [ruleSets](#services-proxy-suite-proxy-routing-rules-rulesets)
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
    - [lanInterfaces](#services-proxy-suite-proxy-tproxy-laninterfaces)
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

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-proxy-autoproxy-enable"></a>
## services\.proxy-suite\.proxy\.autoProxy\.enable

Find out which destinations are blocked and route each one through the first exit that
reaches it\. Blocks that zapret can fix stay direct\. Needs the sing-box backend\. This host
fetches every new destination itself to test it; ` proxy-ctl proxy auto probe ` shows the result\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-proxy-autoproxy-exclude"></a>
## services\.proxy-suite\.proxy\.autoProxy\.exclude

Domains (with subdomains) never probed or routed by autoProxy\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "internal.example" ]`

<a id="services-proxy-suite-proxy-autoproxy-interval"></a>
## services\.proxy-suite\.proxy\.autoProxy\.interval

Time between probe runs\. ` proxy-ctl proxy auto learn ` probes right away\.

**Type:** string\
**Default:** `"10m"`\
**Example:** `"30m"`

<a id="services-proxy-suite-proxy-autoproxy-maxexits"></a>
## services\.proxy-suite\.proxy\.autoProxy\.maxExits

Maximum exits tried per destination, direct included\. One exit per network is tried
first, then the rest\.

**Type:** positive integer, meaning >0\
**Default:** `12`

<a id="services-proxy-suite-proxy-autoproxy-probebaseport"></a>
## services\.proxy-suite\.proxy\.autoProxy\.probeBasePort

First of ` maxExits ` loopback ports used for probing, one per exit\. They have no
authentication, even with ` proxy.listener.auth ` set\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18540`

<a id="services-proxy-suite-proxy-autoproxy-probesperrun"></a>
## services\.proxy-suite\.proxy\.autoProxy\.probesPerRun

Maximum destinations probed per run\. The rest wait for the next run, most-used first\.

**Type:** positive integer, meaning >0\
**Default:** `200`

<a id="services-proxy-suite-proxy-autoproxy-slowbelowkibps"></a>
## services\.proxy-suite\.proxy\.autoProxy\.slowBelowKiBps

Also route destinations that work directly but stay slower than this, in KiB/s\. 0 disables\.
Needs ` selection ` other than “first”\.

**Type:** unsigned integer, meaning >=0\
**Default:** `150`\
**Example:** `0`

<a id="services-proxy-suite-proxy-autoproxy-ttldays"></a>
## services\.proxy-suite\.proxy\.autoProxy\.ttlDays

Days before a result is probed again\. Everything is probed again when this host’s public
address changes\.

**Type:** positive integer, meaning >0\
**Default:** `30`

<a id="services-proxy-suite-proxy-autostart"></a>
## services\.proxy-suite\.proxy\.autostart

Transparent mode to start at boot, or ` null ` for none\. That mode must also be enabled
(` proxy.tun.enable ` or ` proxy.tproxy.enable `)\.

**Type:** null or one of “tun”, “tproxy”\
**Default:** `null`\
**Example:** `"tun"`

<a id="services-proxy-suite-proxy-backend"></a>
## services\.proxy-suite\.proxy\.backend

Proxy engine\. “hybrid” runs sing-box and hands XRay-only outbounds (XHTTP, ECH) to XRay\.

**Type:** one of “sing-box”, “xray”, “hybrid”\
**Default:** `"sing-box"`\
**Example:** `"hybrid"`

<a id="services-proxy-suite-proxy-dns-clientsubnet"></a>
## services\.proxy-suite\.proxy\.dns\.clientSubnet

EDNS client subnet sent with every query, so CDNs pick servers near you even through the
proxy\. sing-box and hybrid only\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"203.0.113.0/24"`

<a id="services-proxy-suite-proxy-dns-fakeip-enable"></a>
## services\.proxy-suite\.proxy\.dns\.fakeIp\.enable

Answer DNS in TUN mode with fake addresses that sing-box maps back to names\. Saves a
lookup per new site, and proxied names are never resolved locally\. Direct names and those
matched by ` proxy.dns.singBox.rules ` still get real answers\. sing-box and hybrid only;
XRay’s TUN has its own fake DNS\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-proxy-dns-fakeip-inet4range"></a>
## services\.proxy-suite\.proxy\.dns\.fakeIp\.inet4Range

Address range for fake IPs\.

**Type:** string\
**Default:** `"198.18.0.0/15"`

<a id="services-proxy-suite-proxy-dns-local"></a>
## services\.proxy-suite\.proxy\.dns\.local

Resolver for direct traffic\. In global TUN mode it goes through the proxy\. TCP by default,
because ISP DPI often fakes UDP answers from well-known resolvers, which breaks zapret\.

**Type:** submodule\
**Default:** `{ address = "1.1.1.1"; port = 53; type = "tcp"; }`\
**Example:** `{ address = "1.1.1.1"; port = 853; type = "tls"; }`

<a id="services-proxy-suite-proxy-dns-local-address"></a>
## services\.proxy-suite\.proxy\.dns\.local\.address

Resolver address\.

**Type:** string matching the pattern \.+\
**Example:** `"1.1.1.1"`

<a id="services-proxy-suite-proxy-dns-local-port"></a>
## services\.proxy-suite\.proxy\.dns\.local\.port

Resolver port\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `53`

<a id="services-proxy-suite-proxy-dns-local-type"></a>
## services\.proxy-suite\.proxy\.dns\.local\.type

DNS transport\.

**Type:** one of “udp”, “tcp”, “tls”\
**Default:** `"udp"`

<a id="services-proxy-suite-proxy-dns-remote"></a>
## services\.proxy-suite\.proxy\.dns\.remote

Resolver reached through the proxy\. On sing-box, proxied names are always resolved here,
so the ISP never sees them\. Also the default resolver when ` proxy.routing.default ` is “proxy”\.

**Type:** submodule\
**Default:** `{ address = "1.1.1.1"; port = 53; type = "udp"; }`\
**Example:** `{ address = "1.1.1.1"; port = 853; type = "tls"; }`

<a id="services-proxy-suite-proxy-dns-remote-address"></a>
## services\.proxy-suite\.proxy\.dns\.remote\.address

Resolver address\.

**Type:** string matching the pattern \.+\
**Example:** `"1.1.1.1"`

<a id="services-proxy-suite-proxy-dns-remote-port"></a>
## services\.proxy-suite\.proxy\.dns\.remote\.port

Resolver port\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `53`

<a id="services-proxy-suite-proxy-dns-remote-type"></a>
## services\.proxy-suite\.proxy\.dns\.remote\.type

DNS transport\.

**Type:** one of “udp”, “tcp”, “tls”\
**Default:** `"udp"`

<a id="services-proxy-suite-proxy-dns-singbox-rules"></a>
## services\.proxy-suite\.proxy\.dns\.singBox\.rules

DNS rules in sing-box JSON, checked before the generated ones\. Unlike those, they stay
active in the all-proxy and all-bypass modes\.

**Type:** list of (attribute set)\
**Default:** `[ ]`\
**Example:** `[ { domain_suffix = [ "corp.example" ]; server = "corp"; } ]`

<a id="services-proxy-suite-proxy-dns-singbox-servers"></a>
## services\.proxy-suite\.proxy\.dns\.singBox\.servers

Extra DNS servers in sing-box JSON, for use in ` proxy.dns.singBox.rules `\. Built-in
servers: ` local `, ` remote `, and ` fakeip ` when fake IP is on\.

**Type:** list of (attribute set)\
**Default:** `[ ]`\
**Example:** `[ { server = "10.0.0.53"; tag = "corp"; type = "udp"; } ]`

<a id="services-proxy-suite-proxy-dns-strategy"></a>
## services\.proxy-suite\.proxy\.dns\.strategy

Which IP versions to resolve\. Use ` ipv4_only ` if the uplink has no IPv6\. sing-box and hybrid only\.

**Type:** null or one of “prefer_ipv4”, “prefer_ipv6”, “ipv4_only”, “ipv6_only”\
**Default:** `null`\
**Example:** `"ipv4_only"`

<a id="services-proxy-suite-proxy-ipv6"></a>
## services\.proxy-suite\.proxy\.ipv6

Route IPv6 through TUN and TProxy too\. When off, TProxy ignores IPv6 and the TUNs block
it, so apps fall back to IPv4\. If the uplink has no IPv6, also set
` proxy.dns.strategy = "ipv4_only" `, or direct IPv6 connections hang instead of falling back\.

**Type:** boolean\
**Default:** `config.networking.enableIPv6`

<a id="services-proxy-suite-proxy-listener-address"></a>
## services\.proxy-suite\.proxy\.listener\.address

Address of the local SOCKS5/HTTP proxy\. Use “0\.0\.0\.0” only to expose it to the network\.

**Type:** string\
**Default:** `"127.0.0.1"`

<a id="services-proxy-suite-proxy-listener-auth-password"></a>
## services\.proxy-suite\.proxy\.listener\.auth\.password

Password for the local proxy\. Ends up in the Nix store; prefer ` passwordFile `\.

**Type:** null or string matching the pattern \[^\[:space:]]+\
**Default:** `null`\
**Example:** `"change-me"`

<a id="services-proxy-suite-proxy-listener-auth-passwordfile"></a>
## services\.proxy-suite\.proxy\.listener\.auth\.passwordFile

File with the local proxy password\. With ` perAppRouting.proxychains ` it must be a single
word, and ` userControl.group ` can read it through the proxychains config\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-suite-local-proxy-password"`

<a id="services-proxy-suite-proxy-listener-auth-username"></a>
## services\.proxy-suite\.proxy\.listener\.auth\.username

Username for the local proxy\. Needs ` password ` or ` passwordFile `\.

**Type:** null or string matching the pattern \[^\[:space:]]+\
**Default:** `null`\
**Example:** `"proxy-user"`

<a id="services-proxy-suite-proxy-listener-port"></a>
## services\.proxy-suite\.proxy\.listener\.port

Port of the local SOCKS5/HTTP proxy\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `1080`

<a id="services-proxy-suite-proxy-outbounds"></a>
## services\.proxy-suite\.proxy\.outbounds

Proxy servers to connect through\. Each sets exactly one of ` url `, ` urlFile `, ` singBoxJson `
or ` xrayJson `\. The proxy needs at least one outbound or subscription to start;
` proxy-ctl proxy outbounds add ` can add one at runtime\.

**Type:** list of (submodule)\
**Default:** `[ ]`\
**Example:**

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

Which engine runs this outbound on the hybrid backend\. “auto” uses sing-box, or XRay for
XRay-only transports (XHTTP, ECH)\.

**Type:** one of “auto”, “sing-box”, “xray”\
**Default:** `"auto"`\
**Example:** `"xray"`

<a id="services-proxy-suite-proxy-outbounds-detour"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.detour

Tag of an outbound that this outbound connects through (a proxy chain)\. Any outbound works,
including subscription entries, ` warp `, ` ssh-proxy ` and AmneziaWG\. On hybrid, an XRay
outbound can only chain through another XRay one\. For ShadowTLS, put a ` shadowtls `
outbound in ` singBoxJson ` and point the shadowsocks outbound’s ` detour ` at it\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"ru-vps"`

<a id="services-proxy-suite-proxy-outbounds-routing-domains"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.domains

Domains, with their subdomains, always sent to this outbound, whatever the selection\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "youtube.com" ]`

<a id="services-proxy-suite-proxy-outbounds-routing-geoips"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.geoips

Geoip codes always sent to this outbound, whatever the selection; countries by default (see ` geodata `)\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "us" ]`

<a id="services-proxy-suite-proxy-outbounds-routing-geosites"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.geosites

Geosite categories always sent to this outbound, whatever the selection (see ` geodata `)\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "netflix" ]`

<a id="services-proxy-suite-proxy-outbounds-routing-ips"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.ips

IP ranges (CIDR) always sent to this outbound, whatever the selection\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "1.1.1.0/24" ]`

<a id="services-proxy-suite-proxy-outbounds-routing-rulesets"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.routing\.ruleSets

Rule sets from ` proxy.routing.ruleSets ` always sent to this outbound, whatever the selection (sing-box and hybrid only)\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "antifilter" ]`

<a id="services-proxy-suite-proxy-outbounds-singboxjson"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.singBoxJson

Raw sing-box outbound JSON, instead of ` url ` (sing-box backend)\. Its tag is replaced\.

**Type:** null or (attribute set)\
**Default:** `null`\
**Example:** `{ server = "example.com"; server_port = 443; type = "vless"; }`

<a id="services-proxy-suite-proxy-outbounds-tag"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.tag

Unique name, used in routing rules, ` detour ` and ` proxy-ctl `\. Not “proxy”, “direct” or “block”\.

**Type:** string\
**Example:** `"vps-de"`

<a id="services-proxy-suite-proxy-outbounds-url"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.url

Proxy link\. Ends up in the Nix store; prefer ` urlFile `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"hy2://password@example.com:443?sni=example.com"`

<a id="services-proxy-suite-proxy-outbounds-urlfile"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.urlFile

File with the proxy link\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/my-proxy-url"`

<a id="services-proxy-suite-proxy-outbounds-xrayjson"></a>
## services\.proxy-suite\.proxy\.outbounds\.\*\.xrayJson

Raw XRay outbound JSON, instead of ` url ` (XRay backend)\. Its tag is replaced\.

**Type:** null or (attribute set)\
**Default:** `null`\
**Example:** `{ protocol = "vless"; settings = { address = "example.com"; }; }`

<a id="services-proxy-suite-proxy-routing-block-domains"></a>
## services\.proxy-suite\.proxy\.routing\.block\.domains

Domains, with their subdomains, to block\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "ads.example.com" ]`

<a id="services-proxy-suite-proxy-routing-block-geoips"></a>
## services\.proxy-suite\.proxy\.routing\.block\.geoips

Geoip codes to block\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "cn" ]`

<a id="services-proxy-suite-proxy-routing-block-geosites"></a>
## services\.proxy-suite\.proxy\.routing\.block\.geosites

Geosite categories to block\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "category-ads-all" ]`

<a id="services-proxy-suite-proxy-routing-block-ips"></a>
## services\.proxy-suite\.proxy\.routing\.block\.ips

IP ranges (CIDR) to block\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "203.0.113.0/24" ]`

<a id="services-proxy-suite-proxy-routing-block-rulesets"></a>
## services\.proxy-suite\.proxy\.routing\.block\.ruleSets

Rule sets from ` ruleSets ` to block\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "ads" ]`

<a id="services-proxy-suite-proxy-routing-default"></a>
## services\.proxy-suite\.proxy\.routing\.default

Where traffic goes when no rule matches\.

**Type:** one of “proxy”, “direct”\
**Default:** `"proxy"`\
**Example:** `"direct"`

<a id="services-proxy-suite-proxy-routing-direct-domains"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.domains

Domains, with their subdomains, sent direct\. ` zapret.directSync ` adds zapret’s domains\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "internal.example" ]`

<a id="services-proxy-suite-proxy-routing-direct-geoips"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.geoips

Geoip codes sent direct\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "ru" ]`

<a id="services-proxy-suite-proxy-routing-direct-geosites"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.geosites

Geosite categories sent direct\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "category-ru" ]`

<a id="services-proxy-suite-proxy-routing-direct-ips"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.ips

IP ranges (CIDR) sent direct\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "10.10.0.0/16" ]`

<a id="services-proxy-suite-proxy-routing-direct-rulesets"></a>
## services\.proxy-suite\.proxy\.routing\.direct\.ruleSets

Rule sets from ` ruleSets ` sent direct\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "ru-services" ]`

<a id="services-proxy-suite-proxy-routing-directru"></a>
## services\.proxy-suite\.proxy\.routing\.directRu

Send Russian sites and IPs (geosite “category-ru”, geoip “ru”) direct\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-proxy-routing-proxy-domains"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.domains

Domains, with their subdomains, sent through the proxy\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "youtube.com" ]`

<a id="services-proxy-suite-proxy-routing-proxy-geoips"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.geoips

Geoip codes sent through the proxy\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "us" ]`

<a id="services-proxy-suite-proxy-routing-proxy-geosites"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.geosites

Geosite categories sent through the proxy\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "netflix" ]`

<a id="services-proxy-suite-proxy-routing-proxy-ips"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.ips

IP ranges (CIDR) sent through the proxy\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "1.1.1.0/24" ]`

<a id="services-proxy-suite-proxy-routing-proxy-rulesets"></a>
## services\.proxy-suite\.proxy\.routing\.proxy\.ruleSets

Rule sets from ` ruleSets ` sent through the proxy\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "antifilter" ]`

<a id="services-proxy-suite-proxy-routing-rulesetupdateinterval"></a>
## services\.proxy-suite\.proxy\.routing\.ruleSetUpdateInterval

How often rule sets are refreshed (systemd time span)\.

**Type:** string\
**Default:** `"1d"`\
**Example:** `"6h"`

<a id="services-proxy-suite-proxy-routing-rulesets"></a>
## services\.proxy-suite\.proxy\.routing\.ruleSets

Named sing-box rule sets, usable in any ` ruleSets ` list\. They are downloaded every
` ruleSetUpdateInterval ` or on ` proxy-ctl proxy rulesets update `, without a restart\. A rule
set matches nothing until its first download\. Not available with the “xray” backend\.

**Type:** attribute set of (submodule)\
**Default:** `{ }`\
**Example:** `{ antifilter = { url = "https://example.com/antifilter.srs"; }; }`

<a id="services-proxy-suite-proxy-routing-rulesets-name-detour"></a>
## services\.proxy-suite\.proxy\.routing\.ruleSets\.\<name>\.detour

Download through the proxy or directly\.

**Type:** one of “proxy”, “direct”\
**Default:** `"proxy"`

<a id="services-proxy-suite-proxy-routing-rulesets-name-format"></a>
## services\.proxy-suite\.proxy\.routing\.ruleSets\.\<name>\.format

“binary” (\.srs) or “source” (JSON)\. ` null `: guess from the URL\.

**Type:** null or one of “binary”, “source”\
**Default:** `null`

<a id="services-proxy-suite-proxy-routing-rulesets-name-url"></a>
## services\.proxy-suite\.proxy\.routing\.ruleSets\.\<name>\.url

URL of the sing-box rule set\.

**Type:** string matching the pattern https?://\.+\
**Example:** `"https://example.com/antifilter.srs"`

<a id="services-proxy-suite-proxy-routing-rules"></a>
## services\.proxy-suite\.proxy\.routing\.rules

Rules checked in order before the proxy, direct and block lists\. The first match wins\.

**Type:** list of (submodule)\
**Default:** `[ ]`\
**Example:**

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

Domains, with their subdomains, that this rule matches\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "youtube.com" ]`

<a id="services-proxy-suite-proxy-routing-rules-geoips"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.geoips

Geoip codes that this rule matches; countries by default (see ` geodata `)\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "us" ]`

<a id="services-proxy-suite-proxy-routing-rules-geosites"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.geosites

Geosite categories that this rule matches (see ` geodata `)\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "netflix" ]`

<a id="services-proxy-suite-proxy-routing-rules-ips"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.ips

IP ranges (CIDR) that this rule matches\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "1.1.1.0/24" ]`

<a id="services-proxy-suite-proxy-routing-rules-outbound"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.outbound

Outbound tag, or “proxy”, “direct” or “block”\.

**Type:** string\
**Example:** `"vps-de"`

<a id="services-proxy-suite-proxy-routing-rules-rulesets"></a>
## services\.proxy-suite\.proxy\.routing\.rules\.\*\.ruleSets

Rule sets from ` proxy.routing.ruleSets ` that this rule matches (sing-box and hybrid only)\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "antifilter" ]`

<a id="services-proxy-suite-proxy-selection"></a>
## services\.proxy-suite\.proxy\.selection

How to pick an outbound:

 - “first”: the pinned one, or else the first available\.
 - “selector”: pick by hand\.
 - “urltest”: the fastest, unless one is pinned\.

` proxy-ctl proxy pin ` works in every mode and survives restarts\. On sing-box, “selector”
and “urltest” switch without restarting the backend\.

**Type:** one of “first”, “selector”, “urltest”\
**Default:** `"first"`\
**Example:** `"urltest"`

<a id="services-proxy-suite-proxy-selectionexclude"></a>
## services\.proxy-suite\.proxy\.selectionExclude

Outbound tags that selection never picks on its own, such as chain hops (` detour `) or
exits meant only for routing rules\. Any tag works, including subscription entries,
` warp `, ` ssh-proxy ` and AmneziaWG\. You can still pin or select them by hand\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "ru-vps" "warp" ]`

<a id="services-proxy-suite-proxy-singbox-package"></a>
## services\.proxy-suite\.proxy\.singBox\.package

sing-box package, for the “sing-box” and “hybrid” backends\.

**Type:** package\
**Default:** ` sing-box ` from proxy-suite’s own ` nixpkgs ` input\
**Example:** `pkgs.sing-box`

<a id="services-proxy-suite-proxy-singbox-clashapiport"></a>
## services\.proxy-suite\.proxy\.singBox\.clashApiPort

Loopback port of the sing-box Clash API, used to switch and test outbounds\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `9090`

<a id="services-proxy-suite-proxy-subscriptionupdateinterval"></a>
## services\.proxy-suite\.proxy\.subscriptionUpdateInterval

How often subscriptions are refreshed (systemd time span)\.

**Type:** string\
**Default:** `"1d"`\
**Example:** `"6h"`

<a id="services-proxy-suite-proxy-subscriptions"></a>
## services\.proxy-suite\.proxy\.subscriptions

Subscription URLs that serve a list of proxy links (plain or base64)\. Fetched on first
start, cached, and refreshed on a timer\. ` proxy-ctl proxy subs add ` adds more at runtime\.

**Type:** list of (submodule)\
**Default:** `[ ]`\
**Example:** `[ { tag = "private"; urlFile = "/run/secrets/private-sub-url"; } ]`

<a id="services-proxy-suite-proxy-subscriptions-detour"></a>
## services\.proxy-suite\.proxy\.subscriptions\.\*\.detour

Tag of an outbound that every entry of this subscription connects through (a proxy chain)\. Any outbound works,
including subscription entries, ` warp `, ` ssh-proxy ` and AmneziaWG\. On hybrid, an XRay
outbound can only chain through another XRay one\. For ShadowTLS, put a ` shadowtls `
outbound in ` singBoxJson ` and point the shadowsocks outbound’s ` detour ` at it\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"ru-vps"`

<a id="services-proxy-suite-proxy-subscriptions-tag"></a>
## services\.proxy-suite\.proxy\.subscriptions\.\*\.tag

Unique name, used as a prefix for the tags of its outbounds\.

**Type:** string matching the pattern ^\[A-Za-z0-9]\[A-Za-z0-9\._-]\*$\
**Example:** `"community-list"`

<a id="services-proxy-suite-proxy-subscriptions-url"></a>
## services\.proxy-suite\.proxy\.subscriptions\.\*\.url

Subscription URL\. Ends up in the Nix store; prefer ` urlFile `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"https://example.com/sub/token123"`

<a id="services-proxy-suite-proxy-subscriptions-urlfile"></a>
## services\.proxy-suite\.proxy\.subscriptions\.\*\.urlFile

File with the subscription URL\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-subscription-url"`

<a id="services-proxy-suite-proxy-tproxy-enable"></a>
## services\.proxy-suite\.proxy\.tproxy\.enable

Whether to enable global TProxy mode\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-proxy-tproxy-fwmark"></a>
## services\.proxy-suite\.proxy\.tproxy\.fwmark

Firewall mark for intercepted packets\.

**Type:** signed integer\
**Default:** `1`

<a id="services-proxy-suite-proxy-tproxy-laninterfaces"></a>
## services\.proxy-suite\.proxy\.tproxy\.lanInterfaces

LAN interfaces whose devices use this host as their gateway\. Their TCP and UDP goes through the
proxy; everything else is forwarded as usual\. Turns on IP forwarding\. Needs the nftables
firewall on NixOS\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "br0" ]`

<a id="services-proxy-suite-proxy-tproxy-localsubnets"></a>
## services\.proxy-suite\.proxy\.tproxy\.localSubnets

Subnets that skip the proxy, such as your LAN and VM bridges (DNS still goes through it)\. IPv6 works too\.

**Type:** list of string\
**Default:** `[ "192.168.0.0/16" ]`\
**Example:** `[ "192.168.0.0/16" "10.0.0.0/8" "fd00::/8" ]`

<a id="services-proxy-suite-proxy-tproxy-port"></a>
## services\.proxy-suite\.proxy\.tproxy\.port

Local port that intercepted traffic is redirected to\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `1085`

<a id="services-proxy-suite-proxy-tproxy-proxymark"></a>
## services\.proxy-suite\.proxy\.tproxy\.proxyMark

Firewall mark for the proxy’s own traffic, so it is not intercepted again\.

**Type:** signed integer\
**Default:** `2`

<a id="services-proxy-suite-proxy-tproxy-routetable"></a>
## services\.proxy-suite\.proxy\.tproxy\.routeTable

Routing table for intercepted traffic\.

**Type:** signed integer\
**Default:** `100`

<a id="services-proxy-suite-proxy-tun-enable"></a>
## services\.proxy-suite\.proxy\.tun\.enable

Whether to enable global TUN mode\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-proxy-tun-address"></a>
## services\.proxy-suite\.proxy\.tun\.address

TUN interface address (CIDR)\.

**Type:** string\
**Default:** `"172.19.0.1/30"`

<a id="services-proxy-suite-proxy-tun-interface"></a>
## services\.proxy-suite\.proxy\.tun\.interface

TUN interface name\.

**Type:** string\
**Default:** `"singtun0"`

<a id="services-proxy-suite-proxy-tun-mtu"></a>
## services\.proxy-suite\.proxy\.tun\.mtu

TUN interface MTU\.

**Type:** signed integer\
**Default:** `1400`

<a id="services-proxy-suite-proxy-urltest-interval"></a>
## services\.proxy-suite\.proxy\.urlTest\.interval

How often outbounds are tested (Go duration)\.

**Type:** string\
**Default:** `"3m"`\
**Example:** `"1m"`

<a id="services-proxy-suite-proxy-urltest-tolerance"></a>
## services\.proxy-suite\.proxy\.urlTest\.tolerance

How many milliseconds faster an outbound must be to replace the current one (sing-box only)\.

**Type:** signed integer\
**Default:** `50`\
**Example:** `100`

<a id="services-proxy-suite-proxy-urltest-url"></a>
## services\.proxy-suite\.proxy\.urlTest\.url

URL used to test outbounds\. Pick one that is blocked in your region\.

**Type:** string\
**Default:** `"https://www.gstatic.com/generate_204"`\
**Example:** `"https://telegram.org"`

<a id="services-proxy-suite-proxy-xray-package"></a>
## services\.proxy-suite\.proxy\.xray\.package

XRay package, for the “xray” and “hybrid” backends\.

**Type:** package\
**Default:** proxy-suite’s ` xray ` (` pkgs/xray.nix `)\
**Example:** `pkgs.xray`
