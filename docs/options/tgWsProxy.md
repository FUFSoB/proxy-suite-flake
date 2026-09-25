# services.proxy-suite.tgWsProxy

A Telegram MTProto proxy over WebSocket.

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

Whether to enable the Telegram WebSocket proxy (MTProto)\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-tgwsproxy-bufferkib"></a>
## services\.proxy-suite\.tgWsProxy\.bufferKiB

Socket buffer size, in KiB\.

**Type:** integer between 4 and 2147483647 (both inclusive)\
**Default:** `256`

<a id="services-proxy-suite-tgwsproxy-bypasstransparentproxy"></a>
## services\.proxy-suite\.tgWsProxy\.bypassTransparentProxy

Keep the relay’s own connections out of TUN and TProxy, so they do not loop\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-tgwsproxy-cloudflare-domains"></a>
## services\.proxy-suite\.tgWsProxy\.cloudflare\.domains

Domains behind Cloudflare to fall back to\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "cdn.example.com" ]`

<a id="services-proxy-suite-tgwsproxy-cloudflare-fallback"></a>
## services\.proxy-suite\.tgWsProxy\.cloudflare\.fallback

Fall back to Cloudflare when a direct WebSocket fails\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-tgwsproxy-cloudflare-workerdomains"></a>
## services\.proxy-suite\.tgWsProxy\.cloudflare\.workerDomains

Cloudflare Worker domains, tried first\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "worker.example.com" ]`

<a id="services-proxy-suite-tgwsproxy-dcips"></a>
## services\.proxy-suite\.tgWsProxy\.dcIps

Relay IP for each Telegram DC ID\.

**Type:** attribute set of string\
**Default:** `{ }`\
**Example:** `{ "2" = "149.154.167.220"; }`

<a id="services-proxy-suite-tgwsproxy-faketlsdomain"></a>
## services\.proxy-suite\.tgWsProxy\.fakeTlsDomain

Domain to disguise traffic as, with Fake TLS (ee-secret links)\.

**Type:** null or string matching the pattern \.+\
**Default:** `null`\
**Example:** `"www.example.com"`

<a id="services-proxy-suite-tgwsproxy-fwmark"></a>
## services\.proxy-suite\.tgWsProxy\.fwmark

Firewall mark for ` bypassTransparentProxy `\.

**Type:** signed integer\
**Default:** `4`

<a id="services-proxy-suite-tgwsproxy-listener-address"></a>
## services\.proxy-suite\.tgWsProxy\.listener\.address

Listening address\.

**Type:** string\
**Default:** `"127.0.0.1"`

<a id="services-proxy-suite-tgwsproxy-listener-port"></a>
## services\.proxy-suite\.tgWsProxy\.listener\.port

Listening port\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `1443`

<a id="services-proxy-suite-tgwsproxy-log-file"></a>
## services\.proxy-suite\.tgWsProxy\.log\.file

Log file, rotated\. ` null `: log to the journal\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/var/log/proxy-suite-tg-ws-proxy/tg-ws-proxy.log"`

<a id="services-proxy-suite-tgwsproxy-log-keep"></a>
## services\.proxy-suite\.tgWsProxy\.log\.keep

Number of rotated logs to keep\.

**Type:** positive integer, meaning >0\
**Default:** `1`

<a id="services-proxy-suite-tgwsproxy-log-maxsizemib"></a>
## services\.proxy-suite\.tgWsProxy\.log\.maxSizeMiB

Rotate the log at this size, in MiB\.

**Type:** positive integer or floating point number, meaning >0\
**Default:** `5.0`

<a id="services-proxy-suite-tgwsproxy-log-verbose"></a>
## services\.proxy-suite\.tgWsProxy\.log\.verbose

Log debug messages\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-tgwsproxy-poolsize"></a>
## services\.proxy-suite\.tgWsProxy\.poolSize

Idle WebSockets kept open per DC\. 0 disables\.

**Type:** unsigned integer, meaning >=0\
**Default:** `4`

<a id="services-proxy-suite-tgwsproxy-proxyprotocol"></a>
## services\.proxy-suite\.tgWsProxy\.proxyProtocol

Accept a PROXY protocol v1 header from a reverse proxy in front\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-tgwsproxy-secret"></a>
## services\.proxy-suite\.tgWsProxy\.secret

MTProto secret (` openssl rand -hex 16 `)\. Ends up in the Nix store; prefer ` secretFile `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`

<a id="services-proxy-suite-tgwsproxy-secretfile"></a>
## services\.proxy-suite\.tgWsProxy\.secretFile

File with the MTProto secret\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/tg-ws-proxy-secret"`
