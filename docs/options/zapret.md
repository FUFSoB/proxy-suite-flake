# services.proxy-suite.zapret

Part of the [proxy-suite options reference](./index.md).

## Options

- zapret
  - [enable](#services-proxy-suite-zapret-enable)
  - cidrExemption
    - [enable](#services-proxy-suite-zapret-cidrexemption-enable)
    - [cidrs](#services-proxy-suite-zapret-cidrexemption-cidrs)
  - directSync
    - [enable](#services-proxy-suite-zapret-directsync-enable)
    - [upstreamIps](#services-proxy-suite-zapret-directsync-upstreamips)
    - [userIps](#services-proxy-suite-zapret-directsync-userips)
  - [engine](#services-proxy-suite-zapret-engine)
  - zapret-discord-youtube
    - [configName](#services-proxy-suite-zapret-zapret-discord-youtube-configname)
    - [domains](#services-proxy-suite-zapret-zapret-discord-youtube-domains)
    - [excludeDomains](#services-proxy-suite-zapret-zapret-discord-youtube-excludedomains)
    - [excludeIps](#services-proxy-suite-zapret-zapret-discord-youtube-excludeips)
    - [gameFilter](#services-proxy-suite-zapret-zapret-discord-youtube-gamefilter)
    - [hostlistRules](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules)
      - item
        - [enableDirectSync](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-enabledirectsync)
        - [configName](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-configname)
        - [defaultDomains](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-defaultdomains)
        - [defaultIps](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-defaultips)
        - [domains](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-domains)
        - [ips](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-ips)
        - [name](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-name)
        - [nfqwsArgs](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-nfqwsargs)
        - [preset](#services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-preset)
    - [includeExtraUpstreamLists](#services-proxy-suite-zapret-zapret-discord-youtube-includeextraupstreamlists)
    - [ips](#services-proxy-suite-zapret-zapret-discord-youtube-ips)
  - zapret2
    - autoHostlist
      - [enable](#services-proxy-suite-zapret-zapret2-autohostlist-enable)
      - [debugLog](#services-proxy-suite-zapret-zapret2-autohostlist-debuglog)
      - [failThreshold](#services-proxy-suite-zapret-zapret2-autohostlist-failthreshold)
      - [failTime](#services-proxy-suite-zapret-zapret2-autohostlist-failtime)
      - [incomingMaxseq](#services-proxy-suite-zapret-zapret2-autohostlist-incomingmaxseq)
      - [retransMaxseq](#services-proxy-suite-zapret-zapret2-autohostlist-retransmaxseq)
      - [retransReset](#services-proxy-suite-zapret-zapret2-autohostlist-retransreset)
      - [retransThreshold](#services-proxy-suite-zapret-zapret2-autohostlist-retransthreshold)
      - [udpIn](#services-proxy-suite-zapret-zapret2-autohostlist-udpin)
      - [udpOut](#services-proxy-suite-zapret-zapret2-autohostlist-udpout)
    - [blobs](#services-proxy-suite-zapret-zapret2-blobs)
    - cutoff
      - [enable](#services-proxy-suite-zapret-zapret2-cutoff-enable)
      - [proxyFallback](#services-proxy-suite-zapret-zapret2-cutoff-proxyfallback)
    - [domains](#services-proxy-suite-zapret-zapret2-domains)
    - [excludeDomains](#services-proxy-suite-zapret-zapret2-excludedomains)
    - [ipv6](#services-proxy-suite-zapret-zapret2-ipv6)
    - ports
      - [tcp](#services-proxy-suite-zapret-zapret2-ports-tcp)
      - [udp](#services-proxy-suite-zapret-zapret2-ports-udp)
    - [profiles](#services-proxy-suite-zapret-zapret2-profiles)
    - [strategySource](#services-proxy-suite-zapret-zapret2-strategysource)

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

<a id="services-proxy-suite-zapret-cidrexemption-enable"></a>
## services\.proxy-suite\.zapret\.cidrExemption\.enable

Whether to enable exempting subnets from zapret, e\.g\. NATed VMs whose traffic it would break\.

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

<a id="services-proxy-suite-zapret-cidrexemption-cidrs"></a>
## services\.proxy-suite\.zapret\.cidrExemption\.cidrs

Exempted subnets\.

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
]
```

<a id="services-proxy-suite-zapret-directsync-enable"></a>
## services\.proxy-suite\.zapret\.directSync\.enable

Add zapret’s domain hostlists to proxy\.routing\.direct\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-zapret-directsync-upstreamips"></a>
## services\.proxy-suite\.zapret\.directSync\.upstreamIps

Add zapret’s upstream ipsets to proxy\.routing\.direct\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-zapret-directsync-userips"></a>
## services\.proxy-suite\.zapret\.directSync\.userIps

Add zapret-discord-youtube\.ips, minus zapret-discord-youtube\.excludeIps, to proxy\.routing\.direct\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-zapret-engine"></a>
## services\.proxy-suite\.zapret\.engine

“zapret-discord-youtube”: nfqws with curated presets and static hostlists (zapret\.zapret-discord-youtube)\.
“zapret2”: nfqws2, which learns blocked hosts at runtime (zapret\.zapret2)\.

*Type:*
one of “zapret-discord-youtube”, “zapret2”

*Default:*

```nix
"zapret-discord-youtube"
```

*Example:*

```nix
"zapret2"
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-configname"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.configName

Upstream strategy preset\. Names that differ only in whitespace match\.

*Type:*
string

*Default:*

```nix
"general(ALT)"
```

*Example:*

```nix
"general (ALT9)"
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-domains"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.domains

Extra domains to bypass\.

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

<a id="services-proxy-suite-zapret-zapret-discord-youtube-excludedomains"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.excludeDomains

Domains never bypassed\.

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

<a id="services-proxy-suite-zapret-zapret-discord-youtube-excludeips"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.excludeIps

IPs/CIDRs never bypassed\.

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

<a id="services-proxy-suite-zapret-zapret-discord-youtube-gamefilter"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.gameFilter

Game traffic filter, or “null” for off\.

*Type:*
one of “all”, “tcp”, “udp”, “null”

*Default:*

```nix
"null"
```

*Example:*

```nix
"all"
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules

Extra named hostlists, each with its own strategy: cloned from a preset or configName,
or given as nfqwsArgs\.

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
    configName = "general(ALT9)";
    defaultDomains = [
      "youtube"
    ];
    name = "youtube-alt9";
  }
  {
    domains = [
      "example.com"
    ];
    name = "custom-sites";
    preset = "general";
  }
]
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-enabledirectsync"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.enableDirectSync

Include these domains in zapret\.directSync\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-configname"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.configName

Config to clone strategies from\. Exclusive with nfqwsArgs\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"general(ALT9)"
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-defaultdomains"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.defaultDomains

Upstream lists to include (“discord” = “general”, “youtube” = “google”)\. Without preset,
use one per rule so the strategy family can be inferred\.

*Type:*
list of (one of “general”, “google”, “discord”, “youtube”, “instagram”, “soundcloud”, “twitter”)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "google"
]
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-defaultips"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.defaultIps

Upstream ipsets to include (“all” is ipset-all\.txt)\.

*Type:*
list of value “all” (singular enum)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "all"
]
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-domains"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.domains

Domains in this hostlist\.

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
]
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-ips"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.ips

IPs/CIDRs in this rule’s ipset\.

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

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-name"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.name

Hostlist name (hostlists/list-\<name>\.txt)\.

*Type:*
string matching the pattern ^\[a-z0-9]\[a-z0-9-]\*$

*Example:*

```nix
"cloudflare"
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-nfqwsargs"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.nfqwsArgs

Raw NFQWS arguments; --hostlist and --new are added\. Exclusive with configName\.

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

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-preset"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.preset

Strategy family to clone, from configName or the active config\.

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

<a id="services-proxy-suite-zapret-zapret-discord-youtube-includeextraupstreamlists"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.includeExtraUpstreamLists

Also use the upstream instagram, soundcloud and twitter lists\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-zapret-zapret-discord-youtube-ips"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.ips

Extra IPs/CIDRs to bypass\.

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

<a id="services-proxy-suite-zapret-zapret2-autohostlist-enable"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.enable

Learn blocked hosts: after failThreshold failures (retransmissions, early RST, DPI
redirect, one-sided UDP) a host joins /var/lib/proxy-suite/zapret2/zapret-hosts-auto\.txt\.
Off, only zapret2\.domains and ` proxy-ctl zapret auto add ` are acted on\.
The thresholds below also fill whichever of them a profile’s strategy rotation
(circular) leaves unset; its own fails and time are kept\.

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

<a id="services-proxy-suite-zapret-zapret2-autohostlist-debuglog"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.debugLog

Log why hosts are or are not learned to zapret-hosts-auto-debug\.log\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-zapret-zapret2-autohostlist-failthreshold"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.failThreshold

Failures before a host is learned\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
3
```

<a id="services-proxy-suite-zapret-zapret2-autohostlist-failtime"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.failTime

Seconds allowed between two failures before the count resets\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
300
```

<a id="services-proxy-suite-zapret-zapret2-autohostlist-incomingmaxseq"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.incomingMaxseq

Incoming sequence number past which an RST or redirect is not a failure\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
4096
```

<a id="services-proxy-suite-zapret-zapret2-autohostlist-retransmaxseq"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.retransMaxseq

Outgoing sequence number past which failure detection stops\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
32768
```

<a id="services-proxy-suite-zapret-zapret2-autohostlist-retransreset"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.retransReset

RST a stalled client once retransThreshold is hit, so failures are counted fast\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-zapret-zapret2-autohostlist-retransthreshold"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.retransThreshold

Retransmissions of the first request that count as one failure\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
3
```

<a id="services-proxy-suite-zapret-zapret2-autohostlist-udpin"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.udpIn

Incoming UDP packets at or below which an exchange is one-sided\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
1
```

<a id="services-proxy-suite-zapret-zapret2-autohostlist-udpout"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.udpOut

Outgoing UDP packets before a one-sided exchange counts as a failure\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
4
```

<a id="services-proxy-suite-zapret-zapret2-blobs"></a>
## services\.proxy-suite\.zapret\.zapret2\.blobs

Fake payloads by name (blob=\<name>) on top of those of strategySource: a file in zapret2’s files/fake, or an absolute path\.

*Type:*
attribute set of string

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  tls_clienthello = "/etc/proxy-suite/my_clienthello.bin";
}
```

<a id="services-proxy-suite-zapret-zapret2-cutoff-enable"></a>
## services\.proxy-suite\.zapret\.zapret2\.cutoff\.enable

Some lines let TLS to certain hosting networks handshake and then cut it at 12-34 KB,
which no strategy fixes\. z2k’s probe checks this line against ~110 known targets when
its network changes and once a day, and for each cut-off network searches a whitelisted
name that nfqws2 then puts into a fake ClientHello: thousands of short TLS connections to
foreign hosting IPs per full run, sent directly and never touched by zapret2\. State and
maps live in /var/lib/proxy-suite/zapret2/cutoff; ` proxy-ctl zapret cutoff ` shows them\.

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

<a id="services-proxy-suite-zapret-zapret2-cutoff-proxyfallback"></a>
## services\.proxy-suite\.zapret\.zapret2\.cutoff\.proxyFallback

Route the cut-off networks no name fixes through the proxy outbound\. Needs the sing-box
backend with an outbound and a route mode other than all-bypass, and only applies to
traffic the backend sees by address (TUN, TProxy, per-app routing, clients that dial IPs);
explicit direct rules still win\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-zapret-zapret2-domains"></a>
## services\.proxy-suite\.zapret\.zapret2\.domains

Domains always treated as blocked\. At runtime: ` proxy-ctl zapret auto add `\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "rutracker.org"
]
```

<a id="services-proxy-suite-zapret-zapret2-excludedomains"></a>
## services\.proxy-suite\.zapret\.zapret2\.excludeDomains

Domains never touched or learned\. At runtime: ` proxy-ctl zapret auto exclude `\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "bank.example.com"
]
```

<a id="services-proxy-suite-zapret-zapret2-ipv6"></a>
## services\.proxy-suite\.zapret\.zapret2\.ipv6

Intercept IPv6 as well as IPv4\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-zapret-zapret2-ports-tcp"></a>
## services\.proxy-suite\.zapret\.zapret2\.ports\.tcp

TCP ports sent to NFQUEUE\. Must cover every port a profile filters on\. null uses the ports of strategySource\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"80,443"
```

<a id="services-proxy-suite-zapret-zapret2-ports-udp"></a>
## services\.proxy-suite\.zapret\.zapret2\.ports\.udp

UDP ports sent to NFQUEUE\. Must cover every port a profile filters on\. null uses the ports of strategySource\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"443"
```

<a id="services-proxy-suite-zapret-zapret2-profiles"></a>
## services\.proxy-suite\.zapret\.zapret2\.profiles

nfqws2 profiles replacing those of strategySource, joined with --new; first match wins\.
\<HOSTLIST> expands to the hostlist arguments, \<HOSTLIST_NOAUTO> to the same without
learning\. --qnum, --fwmark and --lua-init are added automatically\. null uses the profiles of strategySource\.

*Type:*
null or (list of string)

*Default:*

```nix
null
```

*Example:*

```nix
[
  "--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld"
]
```

<a id="services-proxy-suite-zapret-zapret2-strategysource"></a>
## services\.proxy-suite\.zapret\.zapret2\.strategySource

Where profiles, blobs and ports come from; both are pinned flake inputs\.
“nfqws2-keenetic”: its nfqws2\.conf strategies with its user and exclude lists\.
“z2k”: z2k’s own config generator, run at build time: per-category rotation pools
(general, YouTube, googlevideo, QUIC, Discord), its failure detectors and fake-TTL
hook, its blobs, whitelist and hostlists, including the ~125k-domain RKN list
(about 15 MB more RSS per nfqws2 process)\.
Either way each host’s working strategy is remembered across restarts in
/var/lib/proxy-suite/zapret2/circular/state\.tsv\.

*Type:*
one of “nfqws2-keenetic”, “z2k”

*Default:*

```nix
"nfqws2-keenetic"
```

*Example:*

```nix
"z2k"
```
