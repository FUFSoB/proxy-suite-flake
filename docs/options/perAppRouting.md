# services.proxy-suite.perAppRouting

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

<a id="services-proxy-suite-perapprouting-createdefaultprofiles"></a>
## services\.proxy-suite\.perAppRouting\.createDefaultProfiles

Add a profile named after each enabled backend (proxychains, tun, tproxy, zapret) unless
one with that name already exists\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-perapprouting-profiles"></a>
## services\.proxy-suite\.perAppRouting\.profiles

Profiles for ` proxy-ctl apps run <name> -- <command> `\.

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
    name = "steam-browser";
    route = "proxychains";
  }
]
```

<a id="services-proxy-suite-perapprouting-profiles-name"></a>
## services\.proxy-suite\.perAppRouting\.profiles\.\*\.name

Profile name, unique\.

*Type:*
string matching the pattern ^\[a-z0-9]\[a-z0-9-]\*$

*Example:*

```nix
"steam-browser"
```

<a id="services-proxy-suite-perapprouting-profiles-route"></a>
## services\.proxy-suite\.perAppRouting\.profiles\.\*\.route

Backend: “direct” (unchanged), “proxychains”, or the per-app “tun”, “tproxy” or “zapret”
backend of perAppRouting\.

*Type:*
one of “direct”, “proxychains”, “tun”, “tproxy”, “zapret”

*Default:*

```nix
"proxychains"
```

<a id="services-proxy-suite-perapprouting-proxychains-enable"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.enable

Whether to enable the proxychains backend (TCP apps, through LD_PRELOAD)\.

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

<a id="services-proxy-suite-perapprouting-proxychains-proxydns"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.proxyDns

Resolve DNS through the proxy (proxy_dns)\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-perapprouting-proxychains-quiet"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.quiet

Silence proxychains (quiet_mode)\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-perapprouting-tproxy-enable"></a>
## services\.proxy-suite\.perAppRouting\.tproxy\.enable

Whether to enable the per-app TProxy backend\.

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

<a id="services-proxy-suite-perapprouting-tproxy-fwmark"></a>
## services\.proxy-suite\.perAppRouting\.tproxy\.fwmark

Mark that steers wrapped apps into routeTable\.

*Type:*
signed integer

*Default:*

```nix
17
```

<a id="services-proxy-suite-perapprouting-tproxy-localsubnets"></a>
## services\.proxy-suite\.perAppRouting\.tproxy\.localSubnets

Subnets that bypass interception (DNS excepted)\.

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

<a id="services-proxy-suite-perapprouting-tproxy-routetable"></a>
## services\.proxy-suite\.perAppRouting\.tproxy\.routeTable

Policy-routing table of the per-app TProxy\.

*Type:*
signed integer

*Default:*

```nix
102
```

<a id="services-proxy-suite-perapprouting-tun-enable"></a>
## services\.proxy-suite\.perAppRouting\.tun\.enable

Whether to enable the per-app TUN backend\.

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

<a id="services-proxy-suite-perapprouting-tun-address"></a>
## services\.proxy-suite\.perAppRouting\.tun\.address

Per-app TUN interface address (CIDR)\.

*Type:*
string

*Default:*

```nix
"172.20.0.1/30"
```

<a id="services-proxy-suite-perapprouting-tun-fwmark"></a>
## services\.proxy-suite\.perAppRouting\.tun\.fwmark

Mark that steers wrapped apps into routeTable\.

*Type:*
signed integer

*Default:*

```nix
16
```

<a id="services-proxy-suite-perapprouting-tun-interface"></a>
## services\.proxy-suite\.perAppRouting\.tun\.interface

Per-app TUN interface name\.

*Type:*
string

*Default:*

```nix
"psperapptun0"
```

<a id="services-proxy-suite-perapprouting-tun-localsubnets"></a>
## services\.proxy-suite\.perAppRouting\.tun\.localSubnets

Subnets wrapped apps reach directly (DNS excepted)\.

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

<a id="services-proxy-suite-perapprouting-tun-mtu"></a>
## services\.proxy-suite\.perAppRouting\.tun\.mtu

Per-app TUN interface MTU\.

*Type:*
signed integer

*Default:*

```nix
1400
```

<a id="services-proxy-suite-perapprouting-tun-routetable"></a>
## services\.proxy-suite\.perAppRouting\.tun\.routeTable

Policy-routing table of the per-app TUN\.

*Type:*
signed integer

*Default:*

```nix
101
```

<a id="services-proxy-suite-perapprouting-zapret-enable"></a>
## services\.proxy-suite\.perAppRouting\.zapret\.enable

Whether to enable the per-app zapret backend: a second zapret instance for wrapped apps only\.

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

<a id="services-proxy-suite-perapprouting-zapret-filtermark"></a>
## services\.proxy-suite\.perAppRouting\.zapret\.filterMark

Mark bit that selects wrapped app traffic\.

*Type:*
signed integer

*Default:*

```nix
268435456
```

<a id="services-proxy-suite-perapprouting-zapret-qnum"></a>
## services\.proxy-suite\.perAppRouting\.zapret\.qnum

NFQUEUE number\. Must differ from the global instance’s\.

*Type:*
signed integer

*Default:*

```nix
201
```
