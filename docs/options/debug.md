# services.proxy-suite.debug

Troubleshooting: backend log levels, a connection recorder, DNS and zapret2 logs.

Part of the [proxy-suite options reference](./index.md).

## Options

- debug
  - connectionLog
    - [enable](#services-proxy-suite-debug-connectionlog-enable)
    - [hosts](#services-proxy-suite-debug-connectionlog-hosts)
    - [inbounds](#services-proxy-suite-debug-connectionlog-inbounds)
    - [interval](#services-proxy-suite-debug-connectionlog-interval)
    - [stallAfter](#services-proxy-suite-debug-connectionlog-stallafter)
  - [logLevel](#services-proxy-suite-debug-loglevel)
  - [perAppDns](#services-proxy-suite-debug-perappdns)
  - [tgWsProxy](#services-proxy-suite-debug-tgwsproxy)
  - zapret2
    - [autoHostlist](#services-proxy-suite-debug-zapret2-autohostlist)
    - [packets](#services-proxy-suite-debug-zapret2-packets)

<a id="services-proxy-suite-debug-connectionlog-enable"></a>
## services\.proxy-suite\.debug\.connectionLog\.enable

Record the backends’ connections to the journal: each one as it opens, with its
listener, site, rule and exit, and as it closes, with the bytes each way and how long
it lasted\. For failures that come and go: look back at the time one happened\. A unit
per backend, up while it is: proxy-suite-connection-log for the local proxy and
global or per-app TProxy, proxy-suite-connection-log-tun for the global TUN and
proxy-suite-connection-log-per-app-tun for per-app TUN, whose Clash APIs this turns
on\. The same view live: ` proxy-ctl debug conns `\. Polls the Clash API, so it needs the
sing-box or hybrid backend; a connection shorter than ` interval ` can be missed\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-debug-connectionlog-hosts"></a>
## services\.proxy-suite\.debug\.connectionLog\.hosts

Record only connections to these domains and their subdomains, or these addresses\.
Empty: every connection\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "twimg.com" "x.com" ]`

<a id="services-proxy-suite-debug-connectionlog-inbounds"></a>
## services\.proxy-suite\.debug\.connectionLog\.inbounds

Record only connections that came in on listeners whose tag starts with one of
these: “tproxy” for global and per-app TProxy, “tun-in” for the global and per-app
TUN, “per-app-pin” for apps run ` --via ` an outbound through TProxy, “mixed-in” for
the local proxy\. Empty: every listener\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "tproxy" ]`

<a id="services-proxy-suite-debug-connectionlog-interval"></a>
## services\.proxy-suite\.debug\.connectionLog\.interval

Seconds between looks at the connections\.

**Type:** positive integer or floating point number, meaning >0\
**Default:** `0.5`

<a id="services-proxy-suite-debug-connectionlog-stallafter"></a>
## services\.proxy-suite\.debug\.connectionLog\.stallAfter

Seconds a connection may wait on an answer: one that has sent since it last
received, and received nothing for this long, is logged as stalled, and again
when it resumes\. Several requests share a connection (HTTP/2), so a stall shows
only when all of them wait\. 0: never\.

**Type:** unsigned integer, meaning >=0\
**Default:** `10`

<a id="services-proxy-suite-debug-loglevel"></a>
## services\.proxy-suite\.debug\.logLevel

How much the proxy backends log to the journal (` proxy-ctl logs proxy-suite-socks `):
sing-box, and XRay where it runs (XRay has no “trace”: it logs at “debug” then)\.
“info” logs every connection with its destination and the rule that routed it\.
` /run/proxy-suite/xray-loglevel ` still overrides XRay’s level at the next start\.

**Type:** one of “warn”, “info”, “debug”, “trace”\
**Default:** `"warn"`\
**Example:** `"info"`

<a id="services-proxy-suite-debug-perappdns"></a>
## services\.proxy-suite\.debug\.perAppDns

Log every lookup the per-app DNS forwarders send on (per-app TUN and TProxy, and apps
run through an AmneziaWG interface): the name, its type, the answer’s code and how long
it took, and the lookups that got no answer\. In the journals of
proxy-suite-per-app-tun-dns, proxy-suite-per-app-tproxy-dns and
proxy-suite-per-app-via@\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-debug-tgwsproxy"></a>
## services\.proxy-suite\.debug\.tgWsProxy

Log the Telegram proxy’s debug messages\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-debug-zapret2-autohostlist"></a>
## services\.proxy-suite\.debug\.zapret2\.autoHostlist

Log why sites are or are not learned (nfqws2’s own learner)\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-debug-zapret2-packets"></a>
## services\.proxy-suite\.debug\.zapret2\.packets

Log everything nfqws2 does to the journal, every packet included\. Very verbose\.

**Type:** boolean\
**Default:** `false`
