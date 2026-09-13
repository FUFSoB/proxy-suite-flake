# services.proxy-suite.tgWsProxy

Part of the [proxy-suite options reference](./index.md).

## Options

- tgWsProxy
  - [enable](#services-proxy-suite-tgwsproxy-enable)
  - [bufferKiB](#services-proxy-suite-tgwsproxy-bufferkib)
  - [bypassTransparentProxy](#services-proxy-suite-tgwsproxy-bypasstransparentproxy)
  - cloudflare
    - [domains](#services-proxy-suite-tgwsproxy-cloudflare-domains)
    - [fallback](#services-proxy-suite-tgwsproxy-cloudflare-fallback)
    - [workerDomains](#services-proxy-suite-tgwsproxy-cloudflare-workerdomains)
  - [dcIps](#services-proxy-suite-tgwsproxy-dcips)
  - [fakeTlsDomain](#services-proxy-suite-tgwsproxy-faketlsdomain)
  - [fwmark](#services-proxy-suite-tgwsproxy-fwmark)
  - listener
    - [address](#services-proxy-suite-tgwsproxy-listener-address)
    - [port](#services-proxy-suite-tgwsproxy-listener-port)
  - log
    - [file](#services-proxy-suite-tgwsproxy-log-file)
    - [keep](#services-proxy-suite-tgwsproxy-log-keep)
    - [maxSizeMiB](#services-proxy-suite-tgwsproxy-log-maxsizemib)
    - [verbose](#services-proxy-suite-tgwsproxy-log-verbose)
  - [poolSize](#services-proxy-suite-tgwsproxy-poolsize)
  - [proxyProtocol](#services-proxy-suite-tgwsproxy-proxyprotocol)
  - [secret](#services-proxy-suite-tgwsproxy-secret)
  - [secretFile](#services-proxy-suite-tgwsproxy-secretfile)

<a id="services-proxy-suite-tgwsproxy-enable"></a>
## services\.proxy-suite\.tgWsProxy\.enable

Whether to enable the Telegram MTProto WebSocket proxy\.

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

<a id="services-proxy-suite-tgwsproxy-bufferkib"></a>
## services\.proxy-suite\.tgWsProxy\.bufferKiB

Socket buffer size, in KiB\.

*Type:*
integer between 4 and 2147483647 (both inclusive)

*Default:*

```nix
256
```

<a id="services-proxy-suite-tgwsproxy-bypasstransparentproxy"></a>
## services\.proxy-suite\.tgWsProxy\.bypassTransparentProxy

Keep the relay’s own connections out of TUN/TProxy, which would otherwise loop them\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-tgwsproxy-cloudflare-domains"></a>
## services\.proxy-suite\.tgWsProxy\.cloudflare\.domains

Cloudflare-proxied domains for WebSocket fallback\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "cdn.example.com"
]
```

<a id="services-proxy-suite-tgwsproxy-cloudflare-fallback"></a>
## services\.proxy-suite\.tgWsProxy\.cloudflare\.fallback

Fall back to Cloudflare when direct WebSocket fails\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-tgwsproxy-cloudflare-workerdomains"></a>
## services\.proxy-suite\.tgWsProxy\.cloudflare\.workerDomains

Cloudflare Worker domains, tried first\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "worker.example.com"
]
```

<a id="services-proxy-suite-tgwsproxy-dcips"></a>
## services\.proxy-suite\.tgWsProxy\.dcIps

Relay IP per Telegram DC ID\.

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
}
```

<a id="services-proxy-suite-tgwsproxy-faketlsdomain"></a>
## services\.proxy-suite\.tgWsProxy\.fakeTlsDomain

SNI for Fake TLS masking (ee-secret links)\.

*Type:*
null or string matching the pattern \.+

*Default:*

```nix
null
```

*Example:*

```nix
"www.example.com"
```

<a id="services-proxy-suite-tgwsproxy-fwmark"></a>
## services\.proxy-suite\.tgWsProxy\.fwmark

Packet mark bypassTransparentProxy uses\.

*Type:*
signed integer

*Default:*

```nix
4
```

<a id="services-proxy-suite-tgwsproxy-listener-address"></a>
## services\.proxy-suite\.tgWsProxy\.listener\.address

Bind address\.

*Type:*
string

*Default:*

```nix
"127.0.0.1"
```

<a id="services-proxy-suite-tgwsproxy-listener-port"></a>
## services\.proxy-suite\.tgWsProxy\.listener\.port

Listen port\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
1443
```

<a id="services-proxy-suite-tgwsproxy-log-file"></a>
## services\.proxy-suite\.tgWsProxy\.log\.file

Rotating log file\. Null logs to stderr\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/var/log/tg-ws-proxy.log"
```

<a id="services-proxy-suite-tgwsproxy-log-keep"></a>
## services\.proxy-suite\.tgWsProxy\.log\.keep

Rotated logs kept\.

*Type:*
positive integer, meaning >0

*Default:*

```nix
1
```

<a id="services-proxy-suite-tgwsproxy-log-maxsizemib"></a>
## services\.proxy-suite\.tgWsProxy\.log\.maxSizeMiB

Log size before rotation, in MiB\.

*Type:*
positive integer or floating point number, meaning >0

*Default:*

```nix
5.0
```

<a id="services-proxy-suite-tgwsproxy-log-verbose"></a>
## services\.proxy-suite\.tgWsProxy\.log\.verbose

Debug logging\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-tgwsproxy-poolsize"></a>
## services\.proxy-suite\.tgWsProxy\.poolSize

WebSocket pool size per DC; 0 disables pooling\.

*Type:*
unsigned integer, meaning >=0

*Default:*

```nix
4
```

<a id="services-proxy-suite-tgwsproxy-proxyprotocol"></a>
## services\.proxy-suite\.tgWsProxy\.proxyProtocol

Accept a PROXY protocol v1 header from a fronting reverse proxy\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-tgwsproxy-secret"></a>
## services\.proxy-suite\.tgWsProxy\.secret

Inline MTProto secret (` openssl rand -hex 16 `)\. Ends up in the Nix store; prefer secretFile\.

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

<a id="services-proxy-suite-tgwsproxy-secretfile"></a>
## services\.proxy-suite\.tgWsProxy\.secretFile

Runtime path to the MTProto secret\.

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
