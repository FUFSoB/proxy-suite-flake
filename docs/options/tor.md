# services.proxy-suite.tor

Tor as an outbound, with bridges, and an onion service for the inbounds.

Part of the [proxy-suite options reference](./index.md).

## Options

- tor
  - [enable](#services-proxy-suite-tor-enable)
  - [package](#services-proxy-suite-tor-package)
  - [asOutbound](#services-proxy-suite-tor-asoutbound)
  - bridges
    - [file](#services-proxy-suite-tor-bridges-file)
    - [lines](#services-proxy-suite-tor-bridges-lines)
  - [clientOnly](#services-proxy-suite-tor-clientonly)
  - [extraConfig](#services-proxy-suite-tor-extraconfig)
  - [lyrebirdPackage](#services-proxy-suite-tor-lyrebirdpackage)
  - onionService
    - [enable](#services-proxy-suite-tor-onionservice-enable)
    - [listeners](#services-proxy-suite-tor-onionservice-listeners)
    - [secretKeyFile](#services-proxy-suite-tor-onionservice-secretkeyfile)
  - [routeOnion](#services-proxy-suite-tor-routeonion)
  - [snowflakePackage](#services-proxy-suite-tor-snowflakepackage)
  - [socksPort](#services-proxy-suite-tor-socksport)
  - [upstream](#services-proxy-suite-tor-upstream)

<a id="services-proxy-suite-tor-enable"></a>
## services\.proxy-suite\.tor\.enable

Run Tor\. Also turn on ` asOutbound `, ` onionService.enable `, or both\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-tor-package"></a>
## services\.proxy-suite\.tor\.package

Tor package\.

**Type:** package\
**Default:** `pkgs.tor`

<a id="services-proxy-suite-tor-asoutbound"></a>
## services\.proxy-suite\.tor\.asOutbound

Add Tor as an outbound tagged “tor”\. Selection and autoProxy skip it unless it is the only
outbound; send traffic to it with ` proxy.routing.rules ` or use it as a ` detour `\.
Needs ` proxy.enable `\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-tor-bridges-file"></a>
## services\.proxy-suite\.tor\.bridges\.file

File with more bridge lines, one per line\. Blank lines and \# comments are skipped\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/tor-bridges"`

<a id="services-proxy-suite-tor-bridges-lines"></a>
## services\.proxy-suite\.tor\.bridges\.lines

Bridge lines from https://bridges\.torproject\.org, without the leading “Bridge”\. Setting
any turns bridges on\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:**

```nix
[
  "obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=... iat-mode=0"
]
```

<a id="services-proxy-suite-tor-clientonly"></a>
## services\.proxy-suite\.tor\.clientOnly

Keep Tor a client, never a relay, even if ` extraConfig ` sets an ORPort\. The onion service
works either way\. Turn off only to run a relay through ` extraConfig `\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-tor-extraconfig"></a>
## services\.proxy-suite\.tor\.extraConfig

Extra torrc lines\.

**Type:** strings concatenated with “\\n”\
**Default:** `""`\
**Example:**

```nix
''
  ExitNodes {de},{nl}
  StrictNodes 1
''
```

<a id="services-proxy-suite-tor-lyrebirdpackage"></a>
## services\.proxy-suite\.tor\.lyrebirdPackage

Bridge transport for obfs4, webtunnel and meek_lite\.

**Type:** package\
**Default:** `pkgs.lyrebird`

<a id="services-proxy-suite-tor-onionservice-enable"></a>
## services\.proxy-suite\.tor\.onionService\.enable

Whether to enable an onion service for the server inbounds\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-tor-onionservice-listeners"></a>
## services\.proxy-suite\.tor\.onionService\.listeners

Listeners reachable through the onion address\. ` null `: every TCP listener (not
amneziawg, h3-only xhttp or raw JSON)\.

Get their links with ` proxy-ctl inbounds link TAG --onion `; subscriptions include them\.
Onion clients do not show up in ` proxy-ctl inbounds online `\.

**Type:** null or (list of string)\
**Default:** `null`\
**Example:** `[ "vless-reality" ]`

<a id="services-proxy-suite-tor-onionservice-secretkeyfile"></a>
## services\.proxy-suite\.tor\.onionService\.secretKeyFile

File with an hs_ed25519_secret_key, to keep a fixed onion address\. ` null `: Tor creates one\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/tor-hs_ed25519_secret_key"`

<a id="services-proxy-suite-tor-routeonion"></a>
## services\.proxy-suite\.tor\.routeOnion

Send \.onion names to the “tor” outbound in every route mode, and never resolve them with
DNS\. Inbound clients’ \.onion names go there too\. Needs ` asOutbound `\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-tor-snowflakepackage"></a>
## services\.proxy-suite\.tor\.snowflakePackage

Bridge transport for snowflake\.

**Type:** package\
**Default:** `pkgs.snowflake`

<a id="services-proxy-suite-tor-socksport"></a>
## services\.proxy-suite\.tor\.socksPort

Loopback SOCKS port of Tor\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18530`

<a id="services-proxy-suite-tor-upstream"></a>
## services\.proxy-suite\.tor\.upstream

How Tor reaches the network\.

 - “direct”: straight from the uplink, bypassing TUN and TProxy\.
 - “proxy”: through the local proxy, for networks that block Tor\. Works with obfs4,
   webtunnel and meek_lite bridges, but not snowflake\.

**Type:** one of “direct”, “proxy”\
**Default:** `"direct"`
