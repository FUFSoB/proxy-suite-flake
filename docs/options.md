# proxy-suite options

This file is generated from the `services.proxy-suite` option descriptions in [`modules/proxy-suite/options/default.nix`](/modules/proxy-suite/options/default.nix).
Update module option docs there instead of editing this file by hand.

## Table of contents

- Config samples
  - [Complete default config](#complete-default-config)
  - [Complete example config](#complete-example-config)
- services.proxy-suite
  - [enable](#services-proxy-suite-enable)
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
  - singBox
    - [enable](#services-proxy-suite-singbox-enable)
    - auth
      - [password](#services-proxy-suite-singbox-auth-password)
      - [passwordFile](#services-proxy-suite-singbox-auth-passwordfile)
      - [username](#services-proxy-suite-singbox-auth-username)
    - [clashApiPort](#services-proxy-suite-singbox-clashapiport)
    - dns
      - [local](#services-proxy-suite-singbox-dns-local)
        - [address](#services-proxy-suite-singbox-dns-local-address)
        - [port](#services-proxy-suite-singbox-dns-local-port)
        - [type](#services-proxy-suite-singbox-dns-local-type)
      - [remote](#services-proxy-suite-singbox-dns-remote)
        - [address](#services-proxy-suite-singbox-dns-remote-address)
        - [port](#services-proxy-suite-singbox-dns-remote-port)
        - [type](#services-proxy-suite-singbox-dns-remote-type)
    - [listenAddress](#services-proxy-suite-singbox-listenaddress)
    - [outbounds](#services-proxy-suite-singbox-outbounds)
      - item
        - [json](#services-proxy-suite-singbox-outbounds-json)
        - routing
          - [domains](#services-proxy-suite-singbox-outbounds-routing-domains)
          - [geoips](#services-proxy-suite-singbox-outbounds-routing-geoips)
          - [geosites](#services-proxy-suite-singbox-outbounds-routing-geosites)
          - [ips](#services-proxy-suite-singbox-outbounds-routing-ips)
        - [tag](#services-proxy-suite-singbox-outbounds-tag)
        - [url](#services-proxy-suite-singbox-outbounds-url)
        - [urlFile](#services-proxy-suite-singbox-outbounds-urlfile)
    - [port](#services-proxy-suite-singbox-port)
    - [proxyByDefault](#services-proxy-suite-singbox-proxybydefault)
    - routing
      - [enableRuDirect](#services-proxy-suite-singbox-routing-enablerudirect)
      - block
        - [domains](#services-proxy-suite-singbox-routing-block-domains)
        - [geoips](#services-proxy-suite-singbox-routing-block-geoips)
        - [geosites](#services-proxy-suite-singbox-routing-block-geosites)
        - [ips](#services-proxy-suite-singbox-routing-block-ips)
      - direct
        - [domains](#services-proxy-suite-singbox-routing-direct-domains)
        - [geoips](#services-proxy-suite-singbox-routing-direct-geoips)
        - [geosites](#services-proxy-suite-singbox-routing-direct-geosites)
        - [ips](#services-proxy-suite-singbox-routing-direct-ips)
      - proxy
        - [domains](#services-proxy-suite-singbox-routing-proxy-domains)
        - [geoips](#services-proxy-suite-singbox-routing-proxy-geoips)
        - [geosites](#services-proxy-suite-singbox-routing-proxy-geosites)
        - [ips](#services-proxy-suite-singbox-routing-proxy-ips)
      - [rules](#services-proxy-suite-singbox-routing-rules)
        - item
          - [domains](#services-proxy-suite-singbox-routing-rules-domains)
          - [geoips](#services-proxy-suite-singbox-routing-rules-geoips)
          - [geosites](#services-proxy-suite-singbox-routing-rules-geosites)
          - [ips](#services-proxy-suite-singbox-routing-rules-ips)
          - [outbound](#services-proxy-suite-singbox-routing-rules-outbound)
    - [selection](#services-proxy-suite-singbox-selection)
    - [subscriptionUpdateInterval](#services-proxy-suite-singbox-subscriptionupdateinterval)
    - [subscriptions](#services-proxy-suite-singbox-subscriptions)
      - item
        - [tag](#services-proxy-suite-singbox-subscriptions-tag)
        - [url](#services-proxy-suite-singbox-subscriptions-url)
        - [urlFile](#services-proxy-suite-singbox-subscriptions-urlfile)
    - tproxy
      - [enable](#services-proxy-suite-singbox-tproxy-enable)
      - [autostart](#services-proxy-suite-singbox-tproxy-autostart)
      - [fwmark](#services-proxy-suite-singbox-tproxy-fwmark)
      - [localSubnets](#services-proxy-suite-singbox-tproxy-localsubnets)
      - perApp
        - [enable](#services-proxy-suite-singbox-tproxy-perapp-enable)
        - [fwmark](#services-proxy-suite-singbox-tproxy-perapp-fwmark)
        - [localSubnets](#services-proxy-suite-singbox-tproxy-perapp-localsubnets)
        - [routeTable](#services-proxy-suite-singbox-tproxy-perapp-routetable)
      - [port](#services-proxy-suite-singbox-tproxy-port)
      - [proxyMark](#services-proxy-suite-singbox-tproxy-proxymark)
      - [routeTable](#services-proxy-suite-singbox-tproxy-routetable)
    - tun
      - [enable](#services-proxy-suite-singbox-tun-enable)
      - [address](#services-proxy-suite-singbox-tun-address)
      - [autostart](#services-proxy-suite-singbox-tun-autostart)
      - [interface](#services-proxy-suite-singbox-tun-interface)
      - [mtu](#services-proxy-suite-singbox-tun-mtu)
      - perApp
        - [enable](#services-proxy-suite-singbox-tun-perapp-enable)
        - [address](#services-proxy-suite-singbox-tun-perapp-address)
        - [fwmark](#services-proxy-suite-singbox-tun-perapp-fwmark)
        - [interface](#services-proxy-suite-singbox-tun-perapp-interface)
        - [localSubnets](#services-proxy-suite-singbox-tun-perapp-localsubnets)
        - [mtu](#services-proxy-suite-singbox-tun-perapp-mtu)
        - [routeTable](#services-proxy-suite-singbox-tun-perapp-routetable)
    - urlTest
      - [interval](#services-proxy-suite-singbox-urltest-interval)
      - [tolerance](#services-proxy-suite-singbox-urltest-tolerance)
      - [url](#services-proxy-suite-singbox-urltest-url)
  - tgWsProxy
    - [enable](#services-proxy-suite-tgwsproxy-enable)
    - [dcIps](#services-proxy-suite-tgwsproxy-dcips)
    - [host](#services-proxy-suite-tgwsproxy-host)
    - [port](#services-proxy-suite-tgwsproxy-port)
    - [secret](#services-proxy-suite-tgwsproxy-secret)
    - [secretFile](#services-proxy-suite-tgwsproxy-secretfile)
  - tray
    - [enable](#services-proxy-suite-tray-enable)
    - [autostart](#services-proxy-suite-tray-autostart)
    - [pollInterval](#services-proxy-suite-tray-pollinterval)
  - userControl
    - global
      - [enable](#services-proxy-suite-usercontrol-global-enable)
    - [group](#services-proxy-suite-usercontrol-group)
    - perApp
      - [enable](#services-proxy-suite-usercontrol-perapp-enable)
  - zapret
    - [enable](#services-proxy-suite-zapret-enable)
    - cidrExemption
      - [enable](#services-proxy-suite-zapret-cidrexemption-enable)
      - [cidrs](#services-proxy-suite-zapret-cidrexemption-cidrs)
    - [configName](#services-proxy-suite-zapret-configname)
    - [gameFilter](#services-proxy-suite-zapret-gamefilter)
    - [hostlistRules](#services-proxy-suite-zapret-hostlistrules)
      - item
        - [enableDirectSync](#services-proxy-suite-zapret-hostlistrules-enabledirectsync)
        - [domains](#services-proxy-suite-zapret-hostlistrules-domains)
        - [name](#services-proxy-suite-zapret-hostlistrules-name)
        - [nfqwsArgs](#services-proxy-suite-zapret-hostlistrules-nfqwsargs)
        - [preset](#services-proxy-suite-zapret-hostlistrules-preset)
    - [includeExtraUpstreamLists](#services-proxy-suite-zapret-includeextraupstreamlists)
    - [ipsetAll](#services-proxy-suite-zapret-ipsetall)
    - [ipsetExclude](#services-proxy-suite-zapret-ipsetexclude)
    - [listExclude](#services-proxy-suite-zapret-listexclude)
    - [listGeneral](#services-proxy-suite-zapret-listgeneral)
    - perApp
      - [enable](#services-proxy-suite-zapret-perapp-enable)
      - [filterMark](#services-proxy-suite-zapret-perapp-filtermark)
      - [qnum](#services-proxy-suite-zapret-perapp-qnum)
    - [syncDirectRouting](#services-proxy-suite-zapret-syncdirectrouting)
    - [syncDirectRoutingUpstreamIps](#services-proxy-suite-zapret-syncdirectroutingupstreamips)
    - [syncDirectRoutingUserIps](#services-proxy-suite-zapret-syncdirectroutinguserips)

<a id="complete-default-config"></a>
## Complete default config

```nix
services.proxy-suite = {
  enable = false;
  perAppRouting = {
    createDefaultProfiles = false;
    enable = false;
    profiles = [ ];
    proxychains = {
      enable = false;
      proxyDns = true;
      quiet = true;
    };
  };
  singBox = {
    auth = {
      password = null;
      passwordFile = null;
      username = null;
    };
    clashApiPort = 9090;
    dns = {
      local = {
        address = "1.1.1.1";
        port = 53;
        type = "udp";
      };
      remote = {
        address = "1.1.1.1";
        port = 53;
        type = "udp";
      };
    };
    enable = true;
    listenAddress = "127.0.0.1";
    outbounds = [ ];
    port = 1080;
    proxyByDefault = true;
    routing = {
      block = {
        domains = [ ];
        geoips = [ ];
        geosites = [ ];
        ips = [ ];
      };
      direct = {
        domains = [ ];
        geoips = [ ];
        geosites = [ ];
        ips = [ ];
      };
      enableRuDirect = true;
      proxy = {
        domains = [ ];
        geoips = [ ];
        geosites = [ ];
        ips = [ ];
      };
      rules = [ ];
    };
    selection = "first";
    subscriptionUpdateInterval = "1d";
    subscriptions = [ ];
    tproxy = {
      autostart = false;
      enable = false;
      fwmark = 1;
      localSubnets = [
        "192.168.0.0/16"
      ];
      perApp = {
        enable = false;
        fwmark = 17;
        localSubnets = [
          "192.168.0.0/16"
        ];
        routeTable = 102;
      };
      port = 1081;
      proxyMark = 2;
      routeTable = 100;
    };
    tun = {
      address = "172.19.0.1/30";
      autostart = false;
      enable = false;
      interface = "singtun0";
      mtu = 1400;
      perApp = {
        address = "172.20.0.1/30";
        enable = false;
        fwmark = 16;
        interface = "psperapptun0";
        localSubnets = [
          "192.168.0.0/16"
        ];
        mtu = 1400;
        routeTable = 101;
      };
    };
    urlTest = {
      interval = "3m";
      tolerance = 50;
      url = "https://www.gstatic.com/generate_204";
    };
  };
  tgWsProxy = {
    dcIps = { };
    enable = false;
    host = "127.0.0.1";
    port = 1443;
    secret = null;
    secretFile = null;
  };
  tray = {
    autostart = true;
    enable = false;
    pollInterval = 5;
  };
  userControl = {
    global = {
      enable = true;
    };
    group = "proxy-suite";
    perApp = {
      enable = true;
    };
  };
  zapret = {
    cidrExemption = {
      cidrs = [ ];
      enable = false;
    };
    configName = "general(ALT)";
    enable = false;
    gameFilter = "null";
    hostlistRules = [ ];
    includeExtraUpstreamLists = false;
    ipsetAll = [ ];
    ipsetExclude = [ ];
    listExclude = [ ];
    listGeneral = [ ];
    perApp = {
      enable = false;
      filterMark = 268435456;
      qnum = 201;
    };
    syncDirectRouting = true;
    syncDirectRoutingUpstreamIps = false;
    syncDirectRoutingUserIps = true;
  };
};
```

<a id="complete-example-config"></a>
## Complete example config

This is generated by filling in all the options with example values (or defaults if no example is provided). This is not meant to be a recommended config, just a comprehensive example of how to set all the options.

```nix
services.proxy-suite = {
  enable = true;
  perAppRouting = {
    createDefaultProfiles = true;
    enable = true;
    profiles = [
      {
        name = "steam-browser";
        route = "proxychains";
      }
      {
        name = "native-direct";
        route = "direct";
      }
    ];
    proxychains = {
      enable = true;
      proxyDns = true;
      quiet = true;
    };
  };
  singBox = {
    auth = {
      password = "change-me";
      passwordFile = "/run/secrets/proxy-suite-local-proxy-password";
      username = "proxy-user";
    };
    clashApiPort = 9090;
    dns = {
      local = {
        address = "9.9.9.9";
        port = 53;
        type = "tcp";
      };
      remote = {
        address = "1.1.1.1";
        port = 853;
        type = "tls";
      };
    };
    enable = true;
    listenAddress = "127.0.0.1";
    outbounds = [
      {
        tag = "de-vps";
        urlFile = "/run/secrets/proxy-de-url";
      }
      {
        tag = "nl-vps";
        url = "hy2://password@example.com:443?sni=example.com";
      }
    ];
    port = 1080;
    proxyByDefault = true;
    routing = {
      block = {
        domains = [
          "ads.example.com"
        ];
        geoips = [
          "cn"
        ];
        geosites = [
          "category-ads-all"
        ];
        ips = [
          "203.0.113.0/24"
        ];
      };
      direct = {
        domains = [
          "internal.example"
        ];
        geoips = [
          "ru"
        ];
        geosites = [
          "category-ru"
        ];
        ips = [
          "10.10.0.0/16"
        ];
      };
      enableRuDirect = true;
      proxy = {
        domains = [
          "youtube.com"
          "discord.com"
        ];
        geoips = [
          "us"
          "de"
        ];
        geosites = [
          "netflix"
          "google"
        ];
        ips = [
          "1.1.1.0/24"
        ];
      };
      rules = [
        {
          domains = [
            "netflix.com"
          ];
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
        {
          domains = [
            "ads.example.com"
          ];
          outbound = "block";
        }
      ];
    };
    selection = "urltest";
    subscriptionUpdateInterval = "6h";
    subscriptions = [
      {
        tag = "community";
        url = "https://example.com/sub/token";
      }
      {
        tag = "private";
        urlFile = "/run/secrets/private-sub-url";
      }
    ];
    tproxy = {
      autostart = true;
      enable = true;
      fwmark = 1;
      localSubnets = [
        "192.168.0.0/16"
        "10.0.0.0/8"
      ];
      perApp = {
        enable = true;
        fwmark = 17;
        localSubnets = [
          "192.168.0.0/16"
          "10.0.0.0/8"
        ];
        routeTable = 102;
      };
      port = 1081;
      proxyMark = 2;
      routeTable = 100;
    };
    tun = {
      address = "172.19.0.1/30";
      autostart = true;
      enable = true;
      interface = "singtun0";
      mtu = 1400;
      perApp = {
        address = "172.20.0.1/30";
        enable = true;
        fwmark = 16;
        interface = "psperapptun0";
        localSubnets = [
          "192.168.0.0/16"
          "10.0.0.0/8"
        ];
        mtu = 1400;
        routeTable = 101;
      };
    };
    urlTest = {
      interval = "1m";
      tolerance = 100;
      url = "https://telegram.org";
    };
  };
  tgWsProxy = {
    dcIps = {
      "2" = "149.154.167.220";
      "203" = "149.154.167.220";
      "4" = "149.154.167.220";
    };
    enable = true;
    host = "127.0.0.1";
    port = 1076;
    secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    secretFile = "/run/secrets/tg-ws-proxy-secret";
  };
  tray = {
    autostart = true;
    enable = true;
    pollInterval = 5;
  };
  userControl = {
    global = {
      enable = true;
    };
    group = "proxy-suite";
    perApp = {
      enable = true;
    };
  };
  zapret = {
    cidrExemption = {
      cidrs = [
        "192.168.123.0/24"
        "10.0.0.0/8"
      ];
      enable = true;
    };
    configName = "general(ALT)";
    enable = true;
    gameFilter = "null";
    hostlistRules = [
      {
        domains = [
          "googlevideo.com"
          "ggpht.com"
        ];
        name = "googlevideo";
        preset = "google";
      }
      {
        domains = [
          "example.com"
          "example.de"
        ];
        name = "example";
        nfqwsArgs = [
          "--filter-tcp=443 --dpi-desync=fake,multisplit"
        ];
        preset = "general";
      }
    ];
    includeExtraUpstreamLists = false;
    ipsetAll = [
      "203.0.113.0/24"
    ];
    ipsetExclude = [
      "203.0.113.10/32"
    ];
    listExclude = [
      "music.youtube.com"
    ];
    listGeneral = [
      "youtube.com"
    ];
    perApp = {
      enable = true;
      filterMark = 268435456;
      qnum = 201;
    };
    syncDirectRouting = true;
    syncDirectRoutingUpstreamIps = false;
    syncDirectRoutingUserIps = true;
  };
};
```

<a id="services-proxy-suite-enable"></a>
## services\.proxy-suite\.enable

Whether to enable proxy suite (sing-box + zapret + tg-ws-proxy)\.



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

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-perapprouting-enable"></a>
## services\.proxy-suite\.perAppRouting\.enable



Whether to enable per-app routing helpers via proxy-ctl wrap\.



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

*Declared by:*
 - [modules/proxy-suite/options/per-app-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/per-app-routing.nix)



<a id="services-proxy-suite-perapprouting-createdefaultprofiles"></a>
## services\.proxy-suite\.perAppRouting\.createDefaultProfiles



Whether to automatically add curated perAppRouting profiles\.

This is opt-in\. Generated defaults are appended only when no
user-defined profile with the same name already exists\.

Current curated defaults:

 - ` proxychains `: route = “proxychains”
 - ` tun `: route = “tun” when singBox\.tun\.perApp\.enable = true
 - ` tproxy `: route = “tproxy” when singBox\.tproxy\.perApp\.enable = true
 - ` zapret `: route = “zapret” when zapret\.perApp\.enable = true and
   zapret\.enable = true

This makes ` proxy-ctl wrap proxychains -- <command> ` available
without defining the profile manually, and similarly exposes
` proxy-ctl wrap tun -- <command> ` or
` proxy-ctl wrap tproxy -- <command> ` or
` proxy-ctl wrap zapret -- <command> ` when the corresponding backend
is enabled\.



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

*Declared by:*
 - [modules/proxy-suite/options/per-app-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/per-app-routing.nix)



<a id="services-proxy-suite-perapprouting-profiles"></a>
## services\.proxy-suite\.perAppRouting\.profiles



Named per-app route profiles consumed by ` proxy-ctl wrap `\.

This initial implementation supports:

 - “direct” for running a command unchanged
 - “proxychains” for TCP apps that can use an LD_PRELOAD wrapper
   instead of global TUN or TProxy interception
 - “tun” for per-app-scoped policy routing into the dedicated app TUN
   backend
 - “tproxy” for per-app-scoped transparent interception through the
   dedicated app TProxy backend
 - “zapret” for per-app-scoped zapret handling through a separate
   zapret instance without changing the app’s network path or exit IP

proxychains-based wrapping depends on singBox\.enable = true and the
local proxy-suite mixed proxy listener provided by sing-box\. The
“tun” route depends on singBox\.tun\.perApp\.enable = true\. The “tproxy”
route depends on singBox\.tproxy\.perApp\.enable = true\. The “zapret”
route depends on zapret\.perApp\.enable = true and zapret\.enable = true\.

When createDefaultProfiles = true, curated defaults are added on top
of this list unless a user-defined profile already uses the same
name\.



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
  {
    name = "native-direct";
    route = "direct";
  }
]
```

*Declared by:*
 - [modules/proxy-suite/options/per-app-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/per-app-routing.nix)



<a id="services-proxy-suite-perapprouting-profiles-name"></a>
## services\.proxy-suite\.perAppRouting\.profiles\.\*\.name



Profile name used by ` proxy-ctl wrap <name> -- <command> `\.
Must be unique within perAppRouting\.profiles\.



*Type:*
string matching the pattern ^\[a-z0-9]\[a-z0-9-]\*$



*Example:*

```nix
"steam-browser"
```

*Declared by:*
 - [modules/proxy-suite/options/per-app-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/per-app-routing.nix)



<a id="services-proxy-suite-perapprouting-profiles-route"></a>
## services\.proxy-suite\.perAppRouting\.profiles\.\*\.route



Per-app route backend used by proxy-ctl wrap\.

 - “direct”: run the command unchanged\.
 - “proxychains”: run the command through proxychains-ng using the
   local proxy-suite mixed SOCKS endpoint\.
 - “tun”: launch the command in the dedicated per-app-routing TUN slice so
   only that app’s traffic is policy-routed into the app TUN backend\.
 - “tproxy”: launch the command in the dedicated per-app-routing TProxy
   slice so only that app’s traffic is transparently intercepted by
   the local sing-box TProxy inbound\.
 - “zapret”: launch the command in the dedicated per-app-routing zapret
   slice so only that app’s traffic is handled by the separate
   per-app-scoped zapret instance\.

Additional route backends may be added in the future\.



*Type:*
one of “direct”, “proxychains”, “tun”, “tproxy”, “zapret”



*Default:*

```nix
"proxychains"
```



*Example:*

```nix
"proxychains"
```

*Declared by:*
 - [modules/proxy-suite/options/per-app-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/per-app-routing.nix)



<a id="services-proxy-suite-perapprouting-proxychains-enable"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.enable



Whether to enable proxychains-backed perAppRouting profiles\.



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

*Declared by:*
 - [modules/proxy-suite/options/per-app-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/per-app-routing.nix)



<a id="services-proxy-suite-perapprouting-proxychains-proxydns"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.proxyDns



Whether generated proxychains wrappers should resolve DNS through
the proxy instead of the local resolver\. This maps to proxychains-ng
proxy_dns\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/per-app-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/per-app-routing.nix)



<a id="services-proxy-suite-perapprouting-proxychains-quiet"></a>
## services\.proxy-suite\.perAppRouting\.proxychains\.quiet



Whether generated proxychains wrappers should suppress their normal
startup chatter\. This maps to proxychains-ng quiet_mode\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/per-app-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/per-app-routing.nix)



<a id="services-proxy-suite-singbox-enable"></a>
## services\.proxy-suite\.singBox\.enable



Whether to configure and run sing-box services for proxy-suite\.
When disabled, sing-box services and generated sing-box configs are
skipped even if proxy-suite itself is enabled\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box.nix)



<a id="services-proxy-suite-singbox-auth-password"></a>
## services\.proxy-suite\.singBox\.auth\.password



Optional inline password for the local SOCKS5/HTTP mixed inbound\.
Convenient for testing, but the password ends up in the Nix store\.

Prefer auth\.passwordFile for real deployments\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box.nix)



<a id="services-proxy-suite-singbox-auth-passwordfile"></a>
## services\.proxy-suite\.singBox\.auth\.passwordFile



Runtime path to a file containing the local proxy password\.
Intended for use with secret managers so the password stays out of
the Nix store\. The file is read when proxy-suite-socks starts\.

If perAppRouting\.proxychains\.enable is also used, keep this password
as a single non-whitespace token so it can be written to the
proxychains-ng config format\. The generated proxychains config is
readable by members of userControl\.group\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box.nix)



<a id="services-proxy-suite-singbox-auth-username"></a>
## services\.proxy-suite\.singBox\.auth\.username



Optional username for the local SOCKS5/HTTP mixed inbound\.

Set this together with exactly one of auth\.password or
auth\.passwordFile to require clients to authenticate before using the
local proxy\. Leave unset to keep the local proxy unauthenticated\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box.nix)



<a id="services-proxy-suite-singbox-clashapiport"></a>
## services\.proxy-suite\.singBox\.clashApiPort



Port for the Clash-compatible REST API exposed by sing-box\.
Only used when selection is “selector” or “urltest”\. Ignored in
“first” mode because there is no selector-style outbound to control\.



*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
9090
```



*Example:*

```nix
9090
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-dns-local"></a>
## services\.proxy-suite\.singBox\.dns\.local



DNS upstream used for the built-in “local” resolver role\.
This resolver is also used as sing-box route\.default_domain_resolver\.

The module keeps detour policy automatic: in mixed/TProxy mode and
per-app-routing TUN mode, “local” stays on the direct path (without an
explicit detour); in global TUN mode, it is forced through the proxy to avoid
auto_redirect conflicts\.



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
  port = 53;
  type = "tcp";
}
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-dns\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-dns.nix)



<a id="services-proxy-suite-singbox-dns-local-address"></a>
## services\.proxy-suite\.singBox\.dns\.local\.address



Resolver address or hostname used for this DNS upstream\.



*Type:*
string matching the pattern \.+



*Example:*

```nix
"1.1.1.1"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-dns\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-dns.nix)



<a id="services-proxy-suite-singbox-dns-local-port"></a>
## services\.proxy-suite\.singBox\.dns\.local\.port



Destination port for this DNS upstream\.



*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
53
```



*Example:*

```nix
853
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-dns\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-dns.nix)



<a id="services-proxy-suite-singbox-dns-local-type"></a>
## services\.proxy-suite\.singBox\.dns\.local\.type



sing-box DNS transport type for this upstream resolver\.



*Type:*
one of “udp”, “tcp”, “tls”



*Default:*

```nix
"udp"
```



*Example:*

```nix
"tls"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-dns\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-dns.nix)



<a id="services-proxy-suite-singbox-dns-remote"></a>
## services\.proxy-suite\.singBox\.dns\.remote



DNS upstream used for the built-in “remote” resolver role\.

This resolver always detours through the proxy and becomes the
generated dns\.final target when singBox\.proxyByDefault = true\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-dns\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-dns.nix)



<a id="services-proxy-suite-singbox-dns-remote-address"></a>
## services\.proxy-suite\.singBox\.dns\.remote\.address



Resolver address or hostname used for this DNS upstream\.



*Type:*
string matching the pattern \.+



*Example:*

```nix
"1.1.1.1"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-dns\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-dns.nix)



<a id="services-proxy-suite-singbox-dns-remote-port"></a>
## services\.proxy-suite\.singBox\.dns\.remote\.port



Destination port for this DNS upstream\.



*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
53
```



*Example:*

```nix
853
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-dns\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-dns.nix)



<a id="services-proxy-suite-singbox-dns-remote-type"></a>
## services\.proxy-suite\.singBox\.dns\.remote\.type



sing-box DNS transport type for this upstream resolver\.



*Type:*
one of “udp”, “tcp”, “tls”



*Default:*

```nix
"udp"
```



*Example:*

```nix
"tls"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-dns\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-dns.nix)



<a id="services-proxy-suite-singbox-listenaddress"></a>
## services\.proxy-suite\.singBox\.listenAddress



Address for the SOCKS5/HTTP mixed inbound to bind to\.
This affects the always-on proxy-suite-socks service\.

Use “0\.0\.0\.0” only if you intentionally want to expose the proxy to
other machines on your network\.



*Type:*
string



*Default:*

```nix
"127.0.0.1"
```



*Example:*

```nix
"127.0.0.1"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box.nix)



<a id="services-proxy-suite-singbox-outbounds"></a>
## services\.proxy-suite\.singBox\.outbounds



List of static proxy outbounds\.
Set exactly one of urlFile, url, or json per entry\.

At least one outbound or one subscription is required when
singBox\.enable = true\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-outbounds-json"></a>
## services\.proxy-suite\.singBox\.outbounds\.\*\.json



Raw sing-box outbound configuration as a Nix attribute set\.
Embedded directly into the config at build time\. The tag field
is overridden by the outbound’s tag option\.

Set exactly one of urlFile, url, or json for each outbound\.
Use this when the proxy definition is easier to generate as native Nix
than as a single URL string\.



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
  uuid = "...";
}
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-outbounds-routing-domains"></a>
## services\.proxy-suite\.singBox\.outbounds\.\*\.routing\.domains



Domain suffixes to match in this routing rule\.
Leave empty to skip domain-based matching for this rule entry\.



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
  "discord.com"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-outbounds-routing-geoips"></a>
## services\.proxy-suite\.singBox\.outbounds\.\*\.routing\.geoips



sing-geoip rule-set names to match in this routing rule\.
Each name becomes a sing-box geoip rule-set reference\.



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
  "de"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-outbounds-routing-geosites"></a>
## services\.proxy-suite\.singBox\.outbounds\.\*\.routing\.geosites



sing-geosite rule-set names to match in this routing rule\.
Each name becomes a sing-box geosite rule-set reference\.



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
  "google"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-outbounds-routing-ips"></a>
## services\.proxy-suite\.singBox\.outbounds\.\*\.routing\.ips



IP CIDRs to match in this routing rule\.
Leave empty to skip IP-based matching for this rule entry\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-outbounds-tag"></a>
## services\.proxy-suite\.singBox\.outbounds\.\*\.tag



Outbound tag used in routing rules and multi-outbound selection\.

With selection = “selector” or “urltest”, each outbound keeps its own
tag and can be selected directly\. With selection = “first”, sing-box
routes through a single active outbound tagged “proxy”, so individual
proxy tags are mainly useful for documentation and config structure\.



*Type:*
string



*Example:*

```nix
"vps-de"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-outbounds-url"></a>
## services\.proxy-suite\.singBox\.outbounds\.\*\.url



Literal proxy URL\. Convenient for non-secret configs, but the URL
will end up in the Nix store\.

Set exactly one of urlFile, url, or json for each outbound\.
Prefer urlFile for real credentials\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-outbounds-urlfile"></a>
## services\.proxy-suite\.singBox\.outbounds\.\*\.urlFile



Runtime path to a file containing the proxy URL\.
Intended for use with secret managers (sops-nix, agenix, etc\.)\.
The file is read at service start time and never lands in the Nix store\.

Set exactly one of urlFile, url, or json for each outbound\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-port"></a>
## services\.proxy-suite\.singBox\.port



Listen port for the always-on SOCKS5/HTTP mixed inbound provided by
proxy-suite-socks\.



*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
1080
```



*Example:*

```nix
1080
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box.nix)



<a id="services-proxy-suite-singbox-proxybydefault"></a>
## services\.proxy-suite\.singBox\.proxyByDefault



Whether traffic that does not match any explicit routing rule should
go through the proxy or go direct\.

This affects sing-box route\.final and dns\.final in the generated
config\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box.nix)



<a id="services-proxy-suite-singbox-routing-enablerudirect"></a>
## services\.proxy-suite\.singBox\.routing\.enableRuDirect



Automatically append “category-ru” to routing\.direct\.geosites and
“ru” to routing\.direct\.geoips\.

This is additive: user-defined routing\.direct\.\* entries still apply\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-block-domains"></a>
## services\.proxy-suite\.singBox\.routing\.block\.domains



Domain suffixes to block entirely\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-block-geoips"></a>
## services\.proxy-suite\.singBox\.routing\.block\.geoips



sing-geoip names to block\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-block-geosites"></a>
## services\.proxy-suite\.singBox\.routing\.block\.geosites



sing-geosite names to block\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-block-ips"></a>
## services\.proxy-suite\.singBox\.routing\.block\.ips



IP CIDRs to block\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-direct-domains"></a>
## services\.proxy-suite\.singBox\.routing\.direct\.domains



Domain suffixes to send direct (bypass proxy)\.
Merged with zapret-synced direct domains when zapret direct sync
options are enabled\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-direct-geoips"></a>
## services\.proxy-suite\.singBox\.routing\.direct\.geoips



sing-geoip names to send direct\.
“ru” is added automatically when enableRuDirect = true\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-direct-geosites"></a>
## services\.proxy-suite\.singBox\.routing\.direct\.geosites



sing-geosite names to send direct\.
“category-ru” is added automatically when enableRuDirect = true\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-direct-ips"></a>
## services\.proxy-suite\.singBox\.routing\.direct\.ips



IP CIDRs to send direct\.
Merged with zapret-synced direct IPs when the corresponding zapret
sync options are enabled\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-proxy-domains"></a>
## services\.proxy-suite\.singBox\.routing\.proxy\.domains



Domain suffixes to match in this routing rule\.
Leave empty to skip domain-based matching for this rule entry\.



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
  "discord.com"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-proxy-geoips"></a>
## services\.proxy-suite\.singBox\.routing\.proxy\.geoips



sing-geoip rule-set names to match in this routing rule\.
Each name becomes a sing-box geoip rule-set reference\.



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
  "de"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-proxy-geosites"></a>
## services\.proxy-suite\.singBox\.routing\.proxy\.geosites



sing-geosite rule-set names to match in this routing rule\.
Each name becomes a sing-box geosite rule-set reference\.



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
  "google"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-proxy-ips"></a>
## services\.proxy-suite\.singBox\.routing\.proxy\.ips



IP CIDRs to match in this routing rule\.
Leave empty to skip IP-based matching for this rule entry\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-rules"></a>
## services\.proxy-suite\.singBox\.routing\.rules



Explicit routing rules evaluated before global proxy/direct/block lists\.
Each rule routes matching traffic to a specific outbound tag\.

The outbound can be a configured outbound tag (useful with selector/urltest),
or one of: “proxy” (active proxy), “direct”, “block”\.

Order is preserved\. The first matching rule wins in sing-box\.
With selection = “first”, non-built-in outbound tags are effectively
routed to the single active “proxy” outbound\.



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
    domains = [
      "netflix.com"
    ];
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
  {
    domains = [
      "ads.example.com"
    ];
    outbound = "block";
  }
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-rules-domains"></a>
## services\.proxy-suite\.singBox\.routing\.rules\.\*\.domains



Domain suffixes to match in this routing rule\.
Leave empty to skip domain-based matching for this rule entry\.



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
  "discord.com"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-rules-geoips"></a>
## services\.proxy-suite\.singBox\.routing\.rules\.\*\.geoips



sing-geoip rule-set names to match in this routing rule\.
Each name becomes a sing-box geoip rule-set reference\.



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
  "de"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-rules-geosites"></a>
## services\.proxy-suite\.singBox\.routing\.rules\.\*\.geosites



sing-geosite rule-set names to match in this routing rule\.
Each name becomes a sing-box geosite rule-set reference\.



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
  "google"
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-rules-ips"></a>
## services\.proxy-suite\.singBox\.routing\.rules\.\*\.ips



IP CIDRs to match in this routing rule\.
Leave empty to skip IP-based matching for this rule entry\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-routing-rules-outbound"></a>
## services\.proxy-suite\.singBox\.routing\.rules\.\*\.outbound



Target outbound tag\. Can be a specific server tag (only useful with
selection = “selector” or “urltest”), or one of the built-in tags:
“proxy” (the active proxy outbound), “direct”, “block”\.

With selection = “first”, named proxy outbounds are collapsed into the
single active “proxy” outbound at runtime, so per-tag routing no longer
distinguishes between individual proxy servers\.



*Type:*
string



*Example:*

```nix
"vps-de"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-routing\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-routing.nix)



<a id="services-proxy-suite-singbox-selection"></a>
## services\.proxy-suite\.singBox\.selection



How to pick between multiple proxy outbounds:

 - “first”: route through a single active outbound tagged “proxy”\.
   The first static outbound is used, or the first subscription
   outbound if only subscriptions are configured\.
 - “selector”: create a Clash-compatible selector outbound tagged
   “proxy” and keep all configured outbounds available for manual
   switching via the Clash API\.
 - “urltest”: create an automatic latency-testing outbound tagged
   “proxy” and keep all configured outbounds available so sing-box
   can periodically probe and switch to a faster one\.

clashApiPort is only used with “selector” or “urltest”\.
urlTest\.\* options are only used with “urltest”\.
Per-outbound tags are only individually meaningful with “selector”
or “urltest”\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-subscriptionupdateinterval"></a>
## services\.proxy-suite\.singBox\.subscriptionUpdateInterval



How often the proxy-suite-subscription-update timer fires and refreshes
all subscription caches\. Accepts any systemd time span string
(e\.g\. “1h”, “6h”, “1d”, “12h”)\.

Only used when singBox\.subscriptions is non-empty\. The timer also runs
once shortly after boot\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-subscriptions"></a>
## services\.proxy-suite\.singBox\.subscriptions



Subscription URLs that provide dynamic lists of proxy outbounds\.
Each URL must return a base64-encoded newline-separated list of proxy URIs
(standard v2rayN / Clash subscription format) or plain text of the same\.

On first service start, each subscription is fetched live and cached
under /var/lib/proxy-suite/subscriptions/\<tag>\.json\. Later restarts
reuse the cache, so ordinary service restarts do not need network access\.

A systemd timer (proxy-suite-subscription-update) refreshes all caches on
the interval set by subscriptionUpdateInterval and restarts the running
sing-box services after a successful refresh\.



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
    tag = "community";
    url = "https://example.com/sub/token";
  }
  {
    tag = "private";
    urlFile = "/run/secrets/private-sub-url";
  }
]
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-subscriptions-tag"></a>
## services\.proxy-suite\.singBox\.subscriptions\.\*\.tag



Unique identifier for this subscription\.
Used as a prefix for all outbound tags generated from its proxy list,
e\.g\. “my-sub” -> tags like “my-sub-Server-DE”\.

This value is also used as the subscription cache filename stem under
/var/lib/proxy-suite/subscriptions/, so it must be a safe identifier\.



*Type:*
string matching the pattern ^\[A-Za-z0-9]\[A-Za-z0-9\._-]\*$



*Example:*

```nix
"community-list"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-subscriptions-url"></a>
## services\.proxy-suite\.singBox\.subscriptions\.\*\.url



Literal subscription URL\. The response must be a base64-encoded
newline-separated list of proxy URIs (standard v2rayN format) or
a plain-text list of the same\.

This value is embedded in the Nix store\. Prefer urlFile for private
subscription links or tokens\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-subscriptions-urlfile"></a>
## services\.proxy-suite\.singBox\.subscriptions\.\*\.urlFile



Runtime path to a file containing the subscription URL\.
Intended for use with secret managers (sops-nix, agenix, etc\.)\.
The file is read at service start time and never lands in the Nix store\.

Set exactly one of urlFile or url for each subscription entry\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-tproxy-enable"></a>
## services\.proxy-suite\.singBox\.tproxy\.enable



Whether to enable global sing-box TProxy mode service\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-autostart"></a>
## services\.proxy-suite\.singBox\.tproxy\.autostart



Whether to start proxy-suite-tproxy automatically during boot by
attaching it to multi-user\.target\.
Cannot be enabled together with singBox\.tun\.autostart\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-fwmark"></a>
## services\.proxy-suite\.singBox\.tproxy\.fwmark



Mark applied to intercepted packets in global TProxy mode\.
A matching ` ip rule ` routes this mark to
singBox\.tproxy\.routeTable, which points traffic to
loopback for local proxy processing\.



*Type:*
signed integer



*Default:*

```nix
1
```



*Example:*

```nix
1
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-localsubnets"></a>
## services\.proxy-suite\.singBox\.tproxy\.localSubnets



Subnets whose traffic bypasses global TProxy interception, except
DNS (port 53)\.

Typically this should include your LAN subnet(s)\. VM bridge networks
should usually go here too, or use zapret\.cidrExemption for
subnet-specific NFQUEUE exemption on the zapret side\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-perapp-enable"></a>
## services\.proxy-suite\.singBox\.tproxy\.perApp\.enable



Whether to enable per-app-scoped sing-box TProxy backend for perAppRouting profiles\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-perapp-fwmark"></a>
## services\.proxy-suite\.singBox\.tproxy\.perApp\.fwmark



Packet mark used to steer wrapped app traffic into the per-app-scoped
TProxy policy-routing table\.



*Type:*
signed integer



*Default:*

```nix
17
```



*Example:*

```nix
17
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-perapp-localsubnets"></a>
## services\.proxy-suite\.singBox\.tproxy\.perApp\.localSubnets



Subnets whose traffic bypasses per-app-scoped TProxy interception,
except DNS (port 53)\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-perapp-routetable"></a>
## services\.proxy-suite\.singBox\.tproxy\.perApp\.routeTable



Policy-routing table used by the per-app-scoped TProxy backend\.



*Type:*
signed integer



*Default:*

```nix
102
```



*Example:*

```nix
102
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-port"></a>
## services\.proxy-suite\.singBox\.tproxy\.port



Local listen port for sing-box’s TProxy inbound\.
nftables redirection created by proxy-suite-tproxy sends intercepted
TCP/UDP traffic to this port\.



*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
1081
```



*Example:*

```nix
1081
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-proxymark"></a>
## services\.proxy-suite\.singBox\.tproxy\.proxyMark



Mark applied to sing-box egress packets in global TProxy mode so
they bypass re-interception and do not loop back into the
transparent proxy path\.



*Type:*
signed integer



*Default:*

```nix
2
```



*Example:*

```nix
2
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tproxy-routetable"></a>
## services\.proxy-suite\.singBox\.tproxy\.routeTable



Policy-routing table number used for global TProxy interception flow\.
The module installs a local default route in this table and binds it
to singBox\.tproxy\.fwmark\.



*Type:*
signed integer



*Default:*

```nix
100
```



*Example:*

```nix
100
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tproxy\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tproxy.nix)



<a id="services-proxy-suite-singbox-tun-enable"></a>
## services\.proxy-suite\.singBox\.tun\.enable



Whether to enable global sing-box TUN mode service\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-address"></a>
## services\.proxy-suite\.singBox\.tun\.address



Address assigned to the global TUN interface in CIDR notation\.



*Type:*
string



*Default:*

```nix
"172.19.0.1/30"
```



*Example:*

```nix
"172.19.0.1/30"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-autostart"></a>
## services\.proxy-suite\.singBox\.tun\.autostart



Whether to start proxy-suite-tun automatically during boot by
attaching it to multi-user\.target\.
Cannot be enabled together with singBox\.tproxy\.autostart\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-interface"></a>
## services\.proxy-suite\.singBox\.tun\.interface



Name of the TUN interface created by proxy-suite-tun\.



*Type:*
string



*Default:*

```nix
"singtun0"
```



*Example:*

```nix
"singtun0"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-mtu"></a>
## services\.proxy-suite\.singBox\.tun\.mtu



MTU for the global TUN interface created by proxy-suite-tun\.



*Type:*
signed integer



*Default:*

```nix
1400
```



*Example:*

```nix
1400
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-perapp-enable"></a>
## services\.proxy-suite\.singBox\.tun\.perApp\.enable



Whether to enable per-app-scoped sing-box TUN backend for perAppRouting profiles\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-perapp-address"></a>
## services\.proxy-suite\.singBox\.tun\.perApp\.address



Address assigned to the dedicated per-app-routing TUN interface in CIDR
notation\.



*Type:*
string



*Default:*

```nix
"172.20.0.1/30"
```



*Example:*

```nix
"172.20.0.1/30"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-perapp-fwmark"></a>
## services\.proxy-suite\.singBox\.tun\.perApp\.fwmark



Packet mark used to steer wrapped app traffic into the per-app-scoped
TUN policy-routing table\.



*Type:*
signed integer



*Default:*

```nix
16
```



*Example:*

```nix
16
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-perapp-interface"></a>
## services\.proxy-suite\.singBox\.tun\.perApp\.interface



Name of the dedicated per-app-routing TUN interface used by
proxy-suite-per-app-tun\.



*Type:*
string



*Default:*

```nix
"psperapptun0"
```



*Example:*

```nix
"psperapptun0"
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-perapp-localsubnets"></a>
## services\.proxy-suite\.singBox\.tun\.perApp\.localSubnets



Destination subnets that should bypass the per-app-scoped TUN mark,
so wrapped apps can still reach local LAN resources directly\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-perapp-mtu"></a>
## services\.proxy-suite\.singBox\.tun\.perApp\.mtu



MTU for the dedicated per-app-routing TUN interface\.



*Type:*
signed integer



*Default:*

```nix
1400
```



*Example:*

```nix
1400
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-tun-perapp-routetable"></a>
## services\.proxy-suite\.singBox\.tun\.perApp\.routeTable



Policy-routing table used by the per-app-scoped TUN backend\.



*Type:*
signed integer



*Default:*

```nix
101
```



*Example:*

```nix
101
```

*Declared by:*
 - [modules/proxy-suite/options/sing-box-tun\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-tun.nix)



<a id="services-proxy-suite-singbox-urltest-interval"></a>
## services\.proxy-suite\.singBox\.urlTest\.interval



How often sing-box re-tests all outbounds\. Accepts a Go duration
string (e\.g\. “1m”, “3m”, “10m”)\.
Only used when selection = “urltest”\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-urltest-tolerance"></a>
## services\.proxy-suite\.singBox\.urlTest\.tolerance



Latency tolerance in milliseconds\. The current proxy is only replaced
when a competing one is faster by more than this value\.

Only used when selection = “urltest”\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-singbox-urltest-url"></a>
## services\.proxy-suite\.singBox\.urlTest\.url



URL that sing-box fetches through each proxy to measure latency\.
Only used when selection = “urltest”\.

Set this to a URL that is actually blocked in your region (e\.g\.
“https://telegram\.org”) so that only proxies that bypass the
blocking get selected\. If left at the default, any responding proxy
wins – including ones that might not unblock your target site\.



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

*Declared by:*
 - [modules/proxy-suite/options/sing-box-outbounds\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/sing-box-outbounds.nix)



<a id="services-proxy-suite-tgwsproxy-enable"></a>
## services\.proxy-suite\.tgWsProxy\.enable



Whether to enable Telegram MTProto WebSocket proxy\.



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

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-tgwsproxy-dcips"></a>
## services\.proxy-suite\.tgWsProxy\.dcIps



Mapping of Telegram DC IDs to relay IPs\.
Keys are DC IDs as strings and values are IPv4/IPv6 addresses used by
tg-ws-proxy for MTProto relay selection\.



*Type:*
attribute set of string



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "2" = "149.154.167.220";
  "203" = "149.154.167.220";
  "4" = "149.154.167.220";
}
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-tgwsproxy-host"></a>
## services\.proxy-suite\.tgWsProxy\.host



Bind address for tg-ws-proxy\.
Keep ` 127.0.0.1 ` for local-only usage; bind to ` 0.0.0.0 ` only when you
intentionally expose the proxy to other hosts\.



*Type:*
string



*Default:*

```nix
"127.0.0.1"
```



*Example:*

```nix
"127.0.0.1"
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-tgwsproxy-port"></a>
## services\.proxy-suite\.tgWsProxy\.port



TCP listen port for tg-ws-proxy\.
Telegram clients connect to this endpoint when using the local MTProto
WebSocket proxy\.



*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
1443
```



*Example:*

```nix
1076
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-tgwsproxy-secret"></a>
## services\.proxy-suite\.tgWsProxy\.secret



MTProto proxy secret (hex string)\. Legacy inline form; this value ends up
in the Nix store\. Prefer secretFile for real deployments\.

Set exactly one of secret or secretFile when tgWsProxy\.enable = true\.
Generate one with: openssl rand -hex 16



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-tgwsproxy-secretfile"></a>
## services\.proxy-suite\.tgWsProxy\.secretFile



Runtime path to a file containing the MTProto proxy secret\.
Intended for use with secret managers so the secret stays out of the Nix store\.

Set exactly one of secretFile or secret when tgWsProxy\.enable = true\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"/run/secrets/tg-ws-proxy-secret"
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-tray-enable"></a>
## services\.proxy-suite\.tray\.enable



Whether to enable system tray indicator for proxy-suite\.



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

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-tray-autostart"></a>
## services\.proxy-suite\.tray\.autostart



Whether to install an XDG autostart entry for the tray application
for graphical users\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-tray-pollinterval"></a>
## services\.proxy-suite\.tray\.pollInterval



Tray status refresh interval in seconds\.
Lower values make UI state changes appear faster, while higher values
reduce background polling overhead\.



*Type:*
signed integer



*Default:*

```nix
5
```



*Example:*

```nix
5
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-usercontrol-global-enable"></a>
## services\.proxy-suite\.userControl\.global\.enable



Whether members of userControl\.group may manage global
proxy-suite units without password prompts via commands like
` proxy-ctl tun on|off `, ` proxy-ctl tproxy on|off `,
` proxy-ctl restart `, or ` proxy-ctl subscription update `\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-usercontrol-group"></a>
## services\.proxy-suite\.userControl\.group



Local group allowed to use passwordless polkit-backed ` proxy-ctl `
commands when userControl\.global\.enable or userControl\.perApp\.enable
is turned on\.



*Type:*
string matching the pattern ^\[a-z_]\[a-z0-9_-]\*$



*Default:*

```nix
"proxy-suite"
```



*Example:*

```nix
"proxy-suite"
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-usercontrol-perapp-enable"></a>
## services\.proxy-suite\.userControl\.perApp\.enable



Whether members of userControl\.group may start and stop the
app-scoped backend units used by ` proxy-ctl wrap ... ` for
route = “tun”, route = “tproxy”, or route = “zapret” profiles
without password prompts\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/other\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/other.nix)



<a id="services-proxy-suite-zapret-enable"></a>
## services\.proxy-suite\.zapret\.enable

Whether to enable zapret DPI bypass\.



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

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-cidrexemption-enable"></a>
## services\.proxy-suite\.zapret\.cidrExemption\.enable



Whether to enable CIDR exemption from zapret NFQUEUE\.



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

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-cidrexemption-cidrs"></a>
## services\.proxy-suite\.zapret\.cidrExemption\.cidrs



Subnets to exempt from zapret’s NFQUEUE mangle rules\.
Useful when a VM (libvirt, etc\.) is behind NAT and zapret
would corrupt its traffic through the host’s nftables\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "192.168.123.0/24"
  "10.0.0.0/8"
]
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-configname"></a>
## services\.proxy-suite\.zapret\.configName



zapret strategy preset name passed through to the generated zapret configuration\.



*Type:*
string



*Default:*

```nix
"general(ALT)"
```



*Example:*

```nix
"general(ALT)"
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-gamefilter"></a>
## services\.proxy-suite\.zapret\.gameFilter



zapret game traffic filter mode: “all”, “tcp”, “udp”, or “null” to disable\.



*Type:*
string



*Default:*

```nix
"null"
```



*Example:*

```nix
"null"
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-hostlistrules"></a>
## services\.proxy-suite\.zapret\.hostlistRules



Additional named zapret hostlists with per-list DPI mitigation rules\.
Each entry generates hostlists/list-\<name>\.txt and can clone a built-in
zapret family, add custom NFQWS rule fragments, or both\.

Each entry must define at least one domain and at least one of preset
or nfqwsArgs\.



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
    domains = [
      "googlevideo.com"
      "ggpht.com"
    ];
    name = "googlevideo";
    preset = "google";
  }
  {
    domains = [
      "example.com"
      "example.de"
    ];
    name = "example";
    nfqwsArgs = [
      "--filter-tcp=443 --dpi-desync=fake,multisplit"
    ];
    preset = "general";
  }
]
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-hostlistrules-enabledirectsync"></a>
## services\.proxy-suite\.zapret\.hostlistRules\.\*\.enableDirectSync



Whether this custom hostlist should also be mirrored into sing-box
direct domain routing when zapret\.syncDirectRouting = true\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-hostlistrules-domains"></a>
## services\.proxy-suite\.zapret\.hostlistRules\.\*\.domains



Domains written into the generated custom zapret hostlist file\.
Must be non-empty for every hostlistRules entry\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "example.com"
  "example.de"
]
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-hostlistrules-name"></a>
## services\.proxy-suite\.zapret\.hostlistRules\.\*\.name



Custom hostlist name\. Used to generate hostlists/list-\<name>\.txt
inside the derived zapret config directory\.



*Type:*
string matching the pattern ^\[a-z0-9]\[a-z0-9-]\*$



*Example:*

```nix
"cloudflare"
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-hostlistrules-nfqwsargs"></a>
## services\.proxy-suite\.zapret\.hostlistRules\.\*\.nfqwsArgs



Additional NFQWS argument fragments for this hostlist\.
The module injects --hostlist=… and trailing --new automatically\.

Each hostlistRules entry must define preset, nfqwsArgs, or both\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "--filter-tcp=443 --dpi-desync=fake,multisplit"
]
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-hostlistrules-preset"></a>
## services\.proxy-suite\.zapret\.hostlistRules\.\*\.preset



Clone the active zapret config’s built-in NFQWS rule family for this
hostlist\. Can be combined with nfqwsArgs for additional custom rules\.



*Type:*
null or one of “general”, “google”, “instagram”, “soundcloud”, “twitter”



*Default:*

```nix
null
```



*Example:*

```nix
"google"
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-includeextraupstreamlists"></a>
## services\.proxy-suite\.zapret\.includeExtraUpstreamLists



Automatically activate upstream list-instagram\.txt, list-soundcloud\.txt,
and list-twitter\.txt in the generated zapret config when the selected
upstream preset does not already reference them\.

When syncDirectRouting = true, domains from these extra lists are also
mirrored into sing-box direct routing\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
false
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-ipsetall"></a>
## services\.proxy-suite\.zapret\.ipsetAll



Extra IPs/CIDRs to add to zapret’s ipset\.
Mirrored into sing-box direct IP routing when
syncDirectRoutingUserIps = true\.



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

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-ipsetexclude"></a>
## services\.proxy-suite\.zapret\.ipsetExclude



IPs/CIDRs to exclude from zapret’s ipset\.
Also excluded from zapret-derived sing-box direct IP routing when
syncDirectRoutingUserIps = true\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "203.0.113.10/32"
]
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-listexclude"></a>
## services\.proxy-suite\.zapret\.listExclude



Domains to exclude from zapret interception\.
When syncDirectRouting = true, these exclusions also remove matching
domains from the zapret-derived sing-box direct-routing set\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "music.youtube.com"
]
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-listgeneral"></a>
## services\.proxy-suite\.zapret\.listGeneral



Extra domains to include in zapret’s interception list\.
When syncDirectRouting = true, these domains are also mirrored into
sing-box direct routing\.



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

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-perapp-enable"></a>
## services\.proxy-suite\.zapret\.perApp\.enable



Whether to enable per-app-scoped zapret backend for perAppRouting profiles\.



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

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-perapp-filtermark"></a>
## services\.proxy-suite\.zapret\.perApp\.filterMark



Packet mark bit used to mark wrapped app traffic for the
dedicated per-app-scoped zapret instance\.



*Type:*
signed integer



*Default:*

```nix
268435456
```



*Example:*

```nix
268435456
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-perapp-qnum"></a>
## services\.proxy-suite\.zapret\.perApp\.qnum



NFQUEUE number used by the dedicated per-app-scoped zapret instance\.
This backend runs as a second zapret daemon and should use a
queue distinct from the global zapret instance\.



*Type:*
signed integer



*Default:*

```nix
201
```



*Example:*

```nix
201
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-syncdirectrouting"></a>
## services\.proxy-suite\.zapret\.syncDirectRouting



When zapret\.enable = true, mirror zapret’s upstream domain hostlists
into sing-box direct domain routing\.

This includes the default zapret domain lists and any custom
hostlistRules entries with enableDirectSync = true\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-syncdirectroutingupstreamips"></a>
## services\.proxy-suite\.zapret\.syncDirectRoutingUpstreamIps



When zapret\.enable = true, mirror zapret’s upstream ipset ranges
(such as ipset-all\.txt minus exclusions) into sing-box direct IP routing\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
false
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)



<a id="services-proxy-suite-zapret-syncdirectroutinguserips"></a>
## services\.proxy-suite\.zapret\.syncDirectRoutingUserIps



When zapret\.enable = true, mirror user-defined zapret\.ipsetAll and
zapret\.ipsetExclude entries into sing-box direct IP routing\.



*Type:*
boolean



*Default:*

```nix
true
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/proxy-suite/options/zapret\.nix](https://github.com/FUFSoB/proxy-suite-flake/blob/main/modules/proxy-suite/options/zapret.nix)


