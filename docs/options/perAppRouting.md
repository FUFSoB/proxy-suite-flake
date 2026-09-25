# services.proxy-suite.perAppRouting

Route single apps through proxychains, a per-app TUN or TProxy, or zapret.

Part of the [proxy-suite options reference](./index.md).

## Options

- perAppRouting
  - [enable](#services-proxy-suite-perapprouting-enable)
  - [createDefaultProfiles](#services-proxy-suite-perapprouting-createdefaultprofiles)
  - [profiles](#services-proxy-suite-perapprouting-profiles)
    - item
      - [name](#services-proxy-suite-perapprouting-profiles-name)
      - [route](#services-proxy-suite-perapprouting-profiles-route)
  - proxychains
    - [enable](#services-proxy-suite-perapprouting-proxychains-enable)
    - [proxyDns](#services-proxy-suite-perapprouting-proxychains-proxydns)
    - [quiet](#services-proxy-suite-perapprouting-proxychains-quiet)
  - tproxy
    - [enable](#services-proxy-suite-perapprouting-tproxy-enable)
    - [fwmark](#services-proxy-suite-perapprouting-tproxy-fwmark)
    - [localSubnets](#services-proxy-suite-perapprouting-tproxy-localsubnets)
    - [routeTable](#services-proxy-suite-perapprouting-tproxy-routetable)
  - tun
    - [enable](#services-proxy-suite-perapprouting-tun-enable)
    - [address](#services-proxy-suite-perapprouting-tun-address)
    - [fwmark](#services-proxy-suite-perapprouting-tun-fwmark)
    - [interface](#services-proxy-suite-perapprouting-tun-interface)
    - [localSubnets](#services-proxy-suite-perapprouting-tun-localsubnets)
    - [mtu](#services-proxy-suite-perapprouting-tun-mtu)
    - [routeTable](#services-proxy-suite-perapprouting-tun-routetable)
  - zapret
    - [enable](#services-proxy-suite-perapprouting-zapret-enable)
    - [filterMark](#services-proxy-suite-perapprouting-zapret-filtermark)
    - [qnum](#services-proxy-suite-perapprouting-zapret-qnum)

<a id="services-proxy-suite-perapprouting-enable"></a>
## services\.proxy-suite\.perAppRouting\.enable

Whether to enable per-app routing (` proxy-ctl apps run `)\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-perapprouting-createdefaultprofiles"></a>
## services\.proxy-suite\.perAppRouting\.createDefaultProfiles

Add a profile for each enabled method (proxychains, tun, tproxy, zapret), named after it,
unless one already exists\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-perapprouting-profiles"></a>
## services\.proxy-suite\.perAppRouting\.profiles

Profiles for ` proxy-ctl apps run <name> -- <command> `\.

**Type:** list of (submodule)\
**Default:** `[ ]`\
**Example:** `[ { name = "steam-browser"; route = "proxychains"; } ]`

<a id="services-proxy-suite-perapprouting-profiles-name"></a>
## services\.proxy-suite\.perAppRouting\.profiles\.\*\.name

Unique profile name\.

**Type:** string matching the pattern ^\[a-z0-9]\[a-z0-9-]\*$\
**Example:** `"steam-browser"`

<a id="services-proxy-suite-perapprouting-profiles-route"></a>
## services\.proxy-suite\.perAppRouting\.profiles\.\*\.route

How the app is routed: “direct” (untouched), “proxychains”, or the per-app “tun”,
“tproxy” or “zapret”\.

**Type:** one of “direct”, “proxychains”, “tun”, “tproxy”, “zapret”\
**Default:** `"proxychains"`

<a id="services-proxy-suite-perapprouting-proxychains-enable"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.enable

Whether to enable proxychains (TCP only, does not work with static binaries)\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-perapprouting-proxychains-proxydns"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.proxyDns

Resolve DNS through the proxy\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-perapprouting-proxychains-quiet"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.quiet

Hide proxychains output\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-perapprouting-tproxy-enable"></a>
## services\.proxy-suite\.perAppRouting\.tproxy\.enable

Whether to enable per-app TProxy\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-perapprouting-tproxy-fwmark"></a>
## services\.proxy-suite\.perAppRouting\.tproxy\.fwmark

Firewall mark for wrapped apps’ traffic\.

**Type:** signed integer\
**Default:** `17`

<a id="services-proxy-suite-perapprouting-tproxy-localsubnets"></a>
## services\.proxy-suite\.perAppRouting\.tproxy\.localSubnets

Subnets that skip the proxy (DNS still goes through it)\.

**Type:** list of string\
**Default:** `[ "192.168.0.0/16" ]`\
**Example:** `[ "192.168.0.0/16" "10.0.0.0/8" ]`

<a id="services-proxy-suite-perapprouting-tproxy-routetable"></a>
## services\.proxy-suite\.perAppRouting\.tproxy\.routeTable

Routing table for the per-app TProxy\.

**Type:** signed integer\
**Default:** `102`

<a id="services-proxy-suite-perapprouting-tun-enable"></a>
## services\.proxy-suite\.perAppRouting\.tun\.enable

Whether to enable per-app TUN\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-perapprouting-tun-address"></a>
## services\.proxy-suite\.perAppRouting\.tun\.address

Interface address (CIDR)\.

**Type:** string\
**Default:** `"172.20.0.1/30"`

<a id="services-proxy-suite-perapprouting-tun-fwmark"></a>
## services\.proxy-suite\.perAppRouting\.tun\.fwmark

Firewall mark for wrapped apps’ traffic\.

**Type:** signed integer\
**Default:** `16`

<a id="services-proxy-suite-perapprouting-tun-interface"></a>
## services\.proxy-suite\.perAppRouting\.tun\.interface

Interface name\.

**Type:** string\
**Default:** `"psperapptun0"`

<a id="services-proxy-suite-perapprouting-tun-localsubnets"></a>
## services\.proxy-suite\.perAppRouting\.tun\.localSubnets

Subnets that skip the proxy (DNS still goes through it)\.

**Type:** list of string\
**Default:** `[ "192.168.0.0/16" ]`\
**Example:** `[ "192.168.0.0/16" "10.0.0.0/8" ]`

<a id="services-proxy-suite-perapprouting-tun-mtu"></a>
## services\.proxy-suite\.perAppRouting\.tun\.mtu

Interface MTU\.

**Type:** signed integer\
**Default:** `1400`

<a id="services-proxy-suite-perapprouting-tun-routetable"></a>
## services\.proxy-suite\.perAppRouting\.tun\.routeTable

Routing table for the per-app TUN\.

**Type:** signed integer\
**Default:** `101`

<a id="services-proxy-suite-perapprouting-zapret-enable"></a>
## services\.proxy-suite\.perAppRouting\.zapret\.enable

Whether to enable per-app zapret, a separate zapret for wrapped apps only\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-perapprouting-zapret-filtermark"></a>
## services\.proxy-suite\.perAppRouting\.zapret\.filterMark

Firewall mark bit for wrapped apps’ traffic\.

**Type:** signed integer\
**Default:** `268435456`

<a id="services-proxy-suite-perapprouting-zapret-qnum"></a>
## services\.proxy-suite\.perAppRouting\.zapret\.qnum

NFQUEUE number\. Must differ from the global zapret’s\.

**Type:** signed integer\
**Default:** `201`
