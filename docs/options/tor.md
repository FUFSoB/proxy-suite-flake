# services.proxy-suite.tor

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

Whether to enable the Tor daemon (proxy-suite-tor)\.

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

<a id="services-proxy-suite-tor-package"></a>
## services\.proxy-suite\.tor\.package

Tor package\.

*Type:*
package

*Default:*

```nix
pkgs.tor
```

<a id="services-proxy-suite-tor-asoutbound"></a>
## services\.proxy-suite\.tor\.asOutbound

Add Tor as an outbound tagged “tor”: a SOCKS hop to proxy-suite-tor on 127\.0\.0\.1:socksPort,
which receives names unresolved\. proxy\.selection and autoProxy leave it alone unless it is the
only outbound; route to it with proxy\.routing\.rules or name it as a detour\. Requires proxy\.enable\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-tor-bridges-file"></a>
## services\.proxy-suite\.tor\.bridges\.file

Runtime path to more bridge lines, one per line; blank lines and \# comments are skipped\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/tor-bridges"
```

<a id="services-proxy-suite-tor-bridges-lines"></a>
## services\.proxy-suite\.tor\.bridges\.lines

Bridge lines, as https://bridges\.torproject\.org hands them out, without the leading
“Bridge”\. Any given turns on UseBridges; obfs4, webtunnel, meek_lite and snowflake
transports are run as needed\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=... iat-mode=0"
]
```

<a id="services-proxy-suite-tor-clientonly"></a>
## services\.proxy-suite\.tor\.clientOnly

Keep Tor a client (ClientOnly 1): never a relay, exit, bridge or directory server, even when
extraConfig sets an ORPort\. The onion service works either way\. Turn off only to run a relay
through extraConfig\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-tor-extraconfig"></a>
## services\.proxy-suite\.tor\.extraConfig

Lines appended to the generated torrc\.

*Type:*
strings concatenated with “\\n”

*Default:*

```nix
""
```

*Example:*

```nix
''
  ExitNodes {de},{nl}
  StrictNodes 1
''
```

<a id="services-proxy-suite-tor-lyrebirdpackage"></a>
## services\.proxy-suite\.tor\.lyrebirdPackage

Pluggable transport for obfs4, webtunnel and meek_lite bridges\.

*Type:*
package

*Default:*

```nix
pkgs.lyrebird
```

<a id="services-proxy-suite-tor-onionservice-enable"></a>
## services\.proxy-suite\.tor\.onionService\.enable

Whether to enable an onion service in front of inbounds\.listeners\.

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

<a id="services-proxy-suite-tor-onionservice-listeners"></a>
## services\.proxy-suite\.tor\.onionService\.listeners

inbounds\.listeners served at the onion address, each on its share port\. Null takes every
listener a TCP-only onion can carry: not amneziawg, h3-only xhttp or raw JSON\.

Share links for them (` proxy-ctl inbounds link TAG --onion `, and subscriptions) dial the
\.onion address and keep the listener’s TLS and REALITY names\. Clients reach XRay from
127\.0\.0\.1, so ` proxy-ctl inbounds online ` does not list them\.

*Type:*
null or (list of string)

*Default:*

```nix
null
```

*Example:*

```nix
[
  "vless-reality"
]
```

<a id="services-proxy-suite-tor-onionservice-secretkeyfile"></a>
## services\.proxy-suite\.tor\.onionService\.secretKeyFile

Runtime path to an hs_ed25519_secret_key, to keep an onion address\. Null lets Tor create
one in /var/lib/proxy-suite/tor/onion\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/tor-hs_ed25519_secret_key"
```

<a id="services-proxy-suite-tor-routeonion"></a>
## services\.proxy-suite\.tor\.routeOnion

Send \.onion names to the “tor” outbound in every route mode, and keep them away from DNS:
in TUN and TProxy modes sing-box answers them with a fake address it maps back to the name,
and XRay drops the lookup\. Inbound clients’ \.onion names go the same way, through the local
proxy, whatever their listener’s via (except “block”)\. Applies with asOutbound\.

*Type:*
boolean

*Default:*

```nix
true
```

<a id="services-proxy-suite-tor-snowflakepackage"></a>
## services\.proxy-suite\.tor\.snowflakePackage

Pluggable transport for snowflake bridges\.

*Type:*
package

*Default:*

```nix
pkgs.snowflake
```

<a id="services-proxy-suite-tor-socksport"></a>
## services\.proxy-suite\.tor\.socksPort

Loopback SOCKS port of proxy-suite-tor, which the tor outbound dials\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
18530
```

<a id="services-proxy-suite-tor-upstream"></a>
## services\.proxy-suite\.tor\.upstream

How Tor reaches its relays or bridges\.

 - “direct”: from the uplink, past TUN and TProxy (it runs as proxy-suite-daemon)\.
 - “proxy”: through the local proxy listener (proxy\.listener, with its auth), for a network
   that blocks Tor\. obfs4, webtunnel and meek_lite bridges follow it; snowflake cannot\.

*Type:*
one of “direct”, “proxy”

*Default:*

```nix
"direct"
```
