# services.proxy-suite.zapret

DPI bypass without a proxy: zapret-discord-youtube or zapret2.

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

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-zapret-cidrexemption-enable"></a>
## services\.proxy-suite\.zapret\.cidrExemption\.enable

Whether to enable skipping zapret for some subnets, such as NATed VMs it would break\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-zapret-cidrexemption-cidrs"></a>
## services\.proxy-suite\.zapret\.cidrExemption\.cidrs

Subnets zapret skips\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "192.168.123.0/24" ]`

<a id="services-proxy-suite-zapret-directsync-enable"></a>
## services\.proxy-suite\.zapret\.directSync\.enable

Send zapret’s domains direct in the proxy routing, so zapret handles them\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-zapret-directsync-upstreamips"></a>
## services\.proxy-suite\.zapret\.directSync\.upstreamIps

Also send zapret’s upstream IP lists direct\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-zapret-directsync-userips"></a>
## services\.proxy-suite\.zapret\.directSync\.userIps

Also send ` zapret-discord-youtube.ips ` (minus ` excludeIps `) direct\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-zapret-engine"></a>
## services\.proxy-suite\.zapret\.engine

Which zapret to run:

 - “zapret-discord-youtube”: ready-made presets and fixed site lists\.
 - “zapret2”: learns blocked sites at runtime\.

**Type:** one of “zapret-discord-youtube”, “zapret2”\
**Default:** `"zapret-discord-youtube"`\
**Example:** `"zapret2"`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-configname"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.configName

Strategy preset name (spaces are ignored)\.

**Type:** string\
**Default:** `"general(ALT)"`\
**Example:** `"general (ALT9)"`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-domains"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.domains

Extra domains to unblock\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "youtube.com" ]`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-excludedomains"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.excludeDomains

Domains zapret never touches\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "music.youtube.com" ]`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-excludeips"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.excludeIps

IPs or CIDRs zapret never touches\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "203.0.113.10/32" ]`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-gamefilter"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.gameFilter

Which game traffic to handle, or “null” for none\.

**Type:** one of “all”, “tcp”, “udp”, “null”\
**Default:** `"null"`\
**Example:** `"all"`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules

Extra site lists, each with its own strategy: copied from a ` preset ` or ` configName `,
or given as raw ` nfqwsArgs `\.

**Type:** list of (submodule)\
**Default:** `[ ]`\
**Example:**

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

Include these domains in ` zapret.directSync `\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-configname"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.configName

Config to copy the strategy from\. Cannot be used with ` nfqwsArgs `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"general(ALT9)"`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-defaultdomains"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.defaultDomains

Upstream lists to include (“discord” is “general”, “youtube” is “google”)\. Without
` preset `, use only one, so the strategy can be inferred from it\.

**Type:** list of (one of “general”, “google”, “discord”, “youtube”, “instagram”, “soundcloud”, “twitter”)\
**Default:** `[ ]`\
**Example:** `[ "google" ]`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-defaultips"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.defaultIps

Upstream IP lists to include\.

**Type:** list of value “all” (singular enum)\
**Default:** `[ ]`\
**Example:** `[ "all" ]`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-domains"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.domains

Domains in this list\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "example.com" ]`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-ips"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.ips

IPs or CIDRs in this list\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "203.0.113.0/24" ]`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-name"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.name

List name\.

**Type:** string matching the pattern ^\[a-z0-9]\[a-z0-9-]\*$\
**Example:** `"cloudflare"`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-nfqwsargs"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.nfqwsArgs

Raw nfqws arguments; ` --hostlist ` and ` --new ` are added\. Cannot be used with ` configName `\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "--filter-tcp=443 --dpi-desync=fake,multisplit" ]`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-hostlistrules-preset"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.hostlistRules\.\*\.preset

Strategy to copy, from ` configName ` or the active config\.

**Type:** null or one of “general”, “google”, “instagram”, “soundcloud”, “twitter”\
**Default:** `null`\
**Example:** `"google"`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-includeextraupstreamlists"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.includeExtraUpstreamLists

Also use the upstream instagram, soundcloud and twitter lists\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-zapret-zapret-discord-youtube-ips"></a>
## services\.proxy-suite\.zapret\.zapret-discord-youtube\.ips

Extra IPs or CIDRs to unblock\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "203.0.113.0/24" ]`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-enable"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.enable

Learn blocked sites: after ` failThreshold ` failed connections, a site is treated as
blocked\. When off, only ` zapret2.domains ` and ` proxy-ctl zapret auto add ` are used\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-debuglog"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.debugLog

Log why sites are or are not learned\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-failthreshold"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.failThreshold

Failures before a site is learned\.

**Type:** positive integer, meaning >0\
**Default:** `3`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-failtime"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.failTime

Seconds without a failure before the count resets\.

**Type:** positive integer, meaning >0\
**Default:** `300`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-incomingmaxseq"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.incomingMaxseq

After this many bytes received, a reset or redirect is not a failure\.

**Type:** positive integer, meaning >0\
**Default:** `4096`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-retransmaxseq"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.retransMaxseq

Stop watching a connection for failures after this many bytes sent\.

**Type:** positive integer, meaning >0\
**Default:** `32768`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-retransreset"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.retransReset

Reset a stalled connection at ` retransThreshold `, so failures are counted faster\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-retransthreshold"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.retransThreshold

Retransmissions of the first request that count as a failure\.

**Type:** positive integer, meaning >0\
**Default:** `3`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-udpin"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.udpIn

Most UDP replies that still count as no answer (see ` udpOut `)\.

**Type:** positive integer, meaning >0\
**Default:** `1`

<a id="services-proxy-suite-zapret-zapret2-autohostlist-udpout"></a>
## services\.proxy-suite\.zapret\.zapret2\.autoHostlist\.udpOut

UDP packets sent, with at most ` udpIn ` replies, that count as a failure\.

**Type:** positive integer, meaning >0\
**Default:** `4`

<a id="services-proxy-suite-zapret-zapret2-blobs"></a>
## services\.proxy-suite\.zapret\.zapret2\.blobs

Extra fake payloads by name (blob=\<name>): a file in zapret2’s files/fake, or an absolute path\.

**Type:** attribute set of string\
**Default:** `{ }`\
**Example:** `{ tls_clienthello = "/etc/proxy-suite/my_clienthello.bin"; }`

<a id="services-proxy-suite-zapret-zapret2-cutoff-enable"></a>
## services\.proxy-suite\.zapret\.zapret2\.cutoff\.enable

Work around ISPs that cut TLS to some hosting networks after about 16 KB, which no
strategy fixes\. A daily probe finds the affected networks and a whitelisted name that
gets through for each\. Only with ` strategySource = "z2k" `\. Each run makes thousands of
short direct connections\. ` proxy-ctl zapret cutoff ` shows the results\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-zapret-zapret2-cutoff-proxyfallback"></a>
## services\.proxy-suite\.zapret\.zapret2\.cutoff\.proxyFallback

Send cut-off networks that no name fixes through the proxy\. Needs the sing-box backend,
an outbound, and a route mode other than all-bypass\. Only works for traffic the proxy
sees by IP (TUN, TProxy, per-app routing)\. Explicit direct rules still win\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-zapret-zapret2-domains"></a>
## services\.proxy-suite\.zapret\.zapret2\.domains

Domains always treated as blocked\. At runtime: ` proxy-ctl zapret auto add `\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "rutracker.org" ]`

<a id="services-proxy-suite-zapret-zapret2-excludedomains"></a>
## services\.proxy-suite\.zapret\.zapret2\.excludeDomains

Domains never touched or learned\. At runtime: ` proxy-ctl zapret auto exclude `\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "bank.example.com" ]`

<a id="services-proxy-suite-zapret-zapret2-ipv6"></a>
## services\.proxy-suite\.zapret\.zapret2\.ipv6

Handle IPv6 too\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-zapret-zapret2-ports-tcp"></a>
## services\.proxy-suite\.zapret\.zapret2\.ports\.tcp

TCP ports zapret2 handles\. Must include every port a profile uses\. ` null `: use the ports from ` strategySource `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"80,443"`

<a id="services-proxy-suite-zapret-zapret2-ports-udp"></a>
## services\.proxy-suite\.zapret\.zapret2\.ports\.udp

UDP ports zapret2 handles\. Must include every port a profile uses\. ` null `: use the ports from ` strategySource `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"443"`

<a id="services-proxy-suite-zapret-zapret2-profiles"></a>
## services\.proxy-suite\.zapret\.zapret2\.profiles

Your own nfqws2 profiles, instead of those from ` strategySource `\. The first match wins\.
` <HOSTLIST> ` expands to the site list arguments, ` <HOSTLIST_NOAUTO> ` to the same without
learning\. ` --qnum `, ` --fwmark ` and ` --lua-init ` are added for you\. ` null `: use the profiles from ` strategySource `\.

**Type:** null or (list of string)\
**Default:** `null`\
**Example:**

```nix
[
  "--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld"
]
```

<a id="services-proxy-suite-zapret-zapret2-strategysource"></a>
## services\.proxy-suite\.zapret\.zapret2\.strategySource

Where the strategies, blobs and ports come from\.

 - “nfqws2-keenetic”: its strategies and site lists\.
 - “z2k”: z2k’s strategies, which rotate per category (YouTube, Discord, QUIC, …), with
   its site lists, including the full RKN list (more memory)\.
   Either way, each site’s working strategy is remembered across restarts\.

**Type:** one of “nfqws2-keenetic”, “z2k”\
**Default:** `"nfqws2-keenetic"`\
**Example:** `"z2k"`
