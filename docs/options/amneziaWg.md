# services.proxy-suite.amneziaWg

AmneziaWG client profiles, as a global VPN or as outbounds.

Part of the [proxy-suite options reference](./index.md).

## Options

- amneziaWg
  - [enable](#services-proxy-suite-amneziawg-enable)
  - [kernelModulePackage](#services-proxy-suite-amneziawg-kernelmodulepackage)
  - [profiles](#services-proxy-suite-amneziawg-profiles)
    - `<name>`
      - [allowConfigHooks](#services-proxy-suite-amneziawg-profiles-name-allowconfighooks)
      - [asOutbound](#services-proxy-suite-amneziawg-profiles-name-asoutbound)
      - [autostart](#services-proxy-suite-amneziawg-profiles-name-autostart)
      - [configFile](#services-proxy-suite-amneziawg-profiles-name-configfile)
      - [endpoint](#services-proxy-suite-amneziawg-profiles-name-endpoint)
      - [interfaceName](#services-proxy-suite-amneziawg-profiles-name-interfacename)
      - [settings](#services-proxy-suite-amneziawg-profiles-name-settings)
        - [addresses](#services-proxy-suite-amneziawg-profiles-name-settings-addresses)
        - [dns](#services-proxy-suite-amneziawg-profiles-name-settings-dns)
        - [listenPort](#services-proxy-suite-amneziawg-profiles-name-settings-listenport)
        - [mtu](#services-proxy-suite-amneziawg-profiles-name-settings-mtu)
        - [obfuscation](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation)
          - [contentPaddingAddition](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-contentpaddingaddition)
          - [disableCookies](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-disablecookies)
          - [h1](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h1)
          - [h2](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h2)
          - [h3](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h3)
          - [h4](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h4)
          - [headerProtectionKey](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-headerprotectionkey)
          - [headerProtectionKeyFile](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-headerprotectionkeyfile)
          - [i1](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i1)
          - [i2](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i2)
          - [i3](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i3)
          - [i4](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i4)
          - [i5](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i5)
          - [jc](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jc)
          - [jmax](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jmax)
          - [jmin](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jmin)
          - [keepaliveTimeout](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-keepalivetimeout)
          - [maxHandshakeAttempts](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-maxhandshakeattempts)
          - [randomTrailers](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-randomtrailers)
          - [rejectAfterTime](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rejectaftertime)
          - [rekeyAfterTime](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rekeyaftertime)
          - [rekeyTimeout](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rekeytimeout)
          - [s1](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s1)
          - [s2](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s2)
          - [s3](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s3)
          - [s4](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s4)
        - [obfuscationFile](#services-proxy-suite-amneziawg-profiles-name-settings-obfuscationfile)
        - [peers](#services-proxy-suite-amneziawg-profiles-name-settings-peers)
          - item
            - [advancedSecurity](#services-proxy-suite-amneziawg-profiles-name-settings-peers-advancedsecurity)
            - [allowedIPs](#services-proxy-suite-amneziawg-profiles-name-settings-peers-allowedips)
            - [endpoint](#services-proxy-suite-amneziawg-profiles-name-settings-peers-endpoint)
            - [persistentKeepalive](#services-proxy-suite-amneziawg-profiles-name-settings-peers-persistentkeepalive)
            - [presharedKey](#services-proxy-suite-amneziawg-profiles-name-settings-peers-presharedkey)
            - [presharedKeyFile](#services-proxy-suite-amneziawg-profiles-name-settings-peers-presharedkeyfile)
            - [publicKey](#services-proxy-suite-amneziawg-profiles-name-settings-peers-publickey)
        - [privateKey](#services-proxy-suite-amneziawg-profiles-name-settings-privatekey)
        - [privateKeyFile](#services-proxy-suite-amneziawg-profiles-name-settings-privatekeyfile)
        - [table](#services-proxy-suite-amneziawg-profiles-name-settings-table)
      - [vpn](#services-proxy-suite-amneziawg-profiles-name-vpn)
      - [vpnContainer](#services-proxy-suite-amneziawg-profiles-name-vpncontainer)
      - [vpnFile](#services-proxy-suite-amneziawg-profiles-name-vpnfile)
  - [toolsPackage](#services-proxy-suite-amneziawg-toolspackage)
  - [userspacePackage](#services-proxy-suite-amneziawg-userspacepackage)
  - [wireproxyPackage](#services-proxy-suite-amneziawg-wireproxypackage)

<a id="services-proxy-suite-amneziawg-enable"></a>
## services\.proxy-suite\.amneziaWg\.enable

Whether to enable AmneziaWG client profiles\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-amneziawg-kernelmodulepackage"></a>
## services\.proxy-suite\.amneziaWg\.kernelModulePackage

AWG 3\.1 kernel module package\. ` null `: userspace only\.

**Type:** null or package\
**Default:** ` amneziawg ` from ` boot.kernelPackages ` on NixOS, ` null ` elsewhere

<a id="services-proxy-suite-amneziawg-profiles"></a>
## services\.proxy-suite\.amneziaWg\.profiles

AmneziaWG client profiles, by name\. Each sets exactly one of ` configFile `, ` vpnFile `, ` vpn `
or ` settings `\. Only one global profile can run at a time\.

When handshakes go unanswered, a profile switches to a new source port on its own\.
Setting ` settings.listenPort ` pins the port and turns this off\.

**Type:** attribute set of (submodule)\
**Default:** `{ }`

<a id="services-proxy-suite-amneziawg-profiles-name-allowconfighooks"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.allowConfigHooks

Let imported configs run wg-quick hooks (PostUp etc\.) or use SaveConfig\. Only for trusted configs\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-amneziawg-profiles-name-asoutbound"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.asOutbound

Use the profile as a proxy outbound, tagged with its name, instead of a global VPN\. It
then always runs and leaves the host’s routes and DNS alone\. Needs ` proxy.enable `\.

 - “singBox”: plain WireGuard in sing-box\. AmneziaWG obfuscation is dropped, with a warning\.
 - “userspace”: wireproxy with AmneziaWG obfuscation\. Needs no root, so it is the only
   mode on home-manager and Nix-on-Droid\. Its endpoint is resolved by the system
   resolver, so use an IP if that resolver cannot reach the name\.
 - “interface”: a real AmneziaWG interface without routes, which the outbound binds to\.
   On sing-box, its DNS also goes through the tunnel\.

**Type:** null or one of “singBox”, “userspace”, “interface”\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-autostart"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.autostart

Start this profile at boot\. Only one profile can autostart\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-amneziawg-profiles-name-configfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.configFile

File with an AmneziaWG \.conf\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-endpoint"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.endpoint

host:port (IPv6 in brackets) that replaces the first peer’s endpoint\.

**Type:** null or string matching the pattern (\\\[\[0-9A-Fa-f:\.]+]|\[^]:\[]+):\[0-9]+\
**Default:** `null`\
**Example:** `"162.159.192.1:500"`

<a id="services-proxy-suite-amneziawg-profiles-name-interfacename"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.interfaceName

Interface name, at most 15 characters\.

**Type:** string matching the pattern ^\[A-Za-z0-9_\.-]{1,15}$\
**Default:** `"awg-<name>"`

<a id="services-proxy-suite-amneziawg-profiles-name-settings"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings

The client config written in Nix, instead of a file\.

**Type:** null or (submodule)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-addresses"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.addresses

Interface addresses\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "10.8.0.2/32" ]`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-dns"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.dns

DNS servers used while this profile is active\.

**Type:** list of string\
**Default:** `[ ]`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-listenport"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.listenPort

Local UDP port\.

**Type:** null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-mtu"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.mtu

Interface MTU\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation

AmneziaWG 1\.x through 3\.x obfuscation parameters\.

**Type:** submodule\
**Default:** `{ }`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-contentpaddingaddition"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.contentPaddingAddition

AWG 3 content-padding addition or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-disablecookies"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.disableCookies

AWG 3 cookie suppression (DisableCookies)\.

**Type:** null or boolean\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h1"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.h1

Handshake-init header or range (H1)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h2"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.h2

Handshake-response header or range (H2)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h3"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.h3

Cookie-reply header or range (H3)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-h4"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.h4

Transport-message header or range (H4)\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-headerprotectionkey"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.headerProtectionKey

AWG 3 header-protection key\. Ends up in the Nix store; prefer ` headerProtectionKeyFile `\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-headerprotectionkeyfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.headerProtectionKeyFile

File with the AWG 3 header-protection key\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i1"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i1

First custom signature packet (I1)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i2"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i2

Second custom signature packet (I2)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i3"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i3

Third custom signature packet (I3)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i4"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i4

Fourth custom signature packet (I4)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-i5"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.i5

Fifth custom signature packet (I5)\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jc"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.jc

Junk packet count (Jc)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jmax"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.jmax

Maximum junk packet size (Jmax)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-jmin"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.jmin

Minimum junk packet size (Jmin)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-keepalivetimeout"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.keepaliveTimeout

AWG 3 keepalive timeout or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-maxhandshakeattempts"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.maxHandshakeAttempts

AWG 3 maximum handshake attempts or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-randomtrailers"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.randomTrailers

AWG 3 random transport trailers (RandomTrailers)\.

**Type:** null or boolean\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rejectaftertime"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.rejectAfterTime

AWG 3 reject-after interval or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rekeyaftertime"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.rekeyAfterTime

AWG 3 rekey interval or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-rekeytimeout"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.rekeyTimeout

AWG 3 rekey timeout or range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s1"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.s1

Handshake-init padding (S1)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s2"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.s2

Handshake-response padding (S2)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s3"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.s3

Cookie-reply padding (S3)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscation-s4"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscation\.s4

Transport-message padding (S4)\.

**Type:** null or (unsigned integer, meaning >=0)\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-obfuscationfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.obfuscationFile

File with secret obfuscation settings as JSON, using the same fields as ` obfuscation `
(except ` headerProtectionKeyFile `)\. It is merged with ` obfuscation ` at startup and never
enters the Nix store\. A field set in both places is an error\. Restart the profile after
changing the file\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/awg-obfuscation.json"`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers

AmneziaWG peers\.

**Type:** list of (submodule)\
**Default:** `[ ]`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-advancedsecurity"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.advancedSecurity

AWG AdvancedSecurity setting\.

**Type:** null or boolean\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-allowedips"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.allowedIPs

IP ranges routed to and accepted from this peer\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "0.0.0.0/0" "::/0" ]`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-endpoint"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.endpoint

Peer address, as host:port\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"vpn.example.com:51820"`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-persistentkeepalive"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.persistentKeepalive

Keepalive interval in seconds, or an AWG 3 range\.

**Type:** null or unsigned integer, meaning >=0, or string matching the pattern ^(\[0-9]+|\[0-9]±\[0-9]+|\\(off\\))$\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-presharedkey"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.presharedKey

Peer preshared key\. Ends up in the Nix store; prefer ` presharedKeyFile `\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-presharedkeyfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.presharedKeyFile

File with the peer preshared key\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-peers-publickey"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.peers\.\*\.publicKey

Peer public key\.

**Type:** string matching the pattern \[^\[:space:]]+

<a id="services-proxy-suite-amneziawg-profiles-name-settings-privatekey"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.privateKey

Client private key\. Ends up in the Nix store; prefer ` privateKeyFile `\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-privatekeyfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.privateKeyFile

File with the client private key\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-settings-table"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.settings\.table

Routing table: a name or number, “auto” or “off”\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-vpn"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.vpn

A vpn:// export\. Ends up in the Nix store; prefer ` vpnFile `\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-vpncontainer"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.vpnContainer

Which container to take from a vpn:// export that holds several\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-profiles-name-vpnfile"></a>
## services\.proxy-suite\.amneziaWg\.profiles\.\<name>\.vpnFile

File with a vpn:// export\.

**Type:** null or string\
**Default:** `null`

<a id="services-proxy-suite-amneziawg-toolspackage"></a>
## services\.proxy-suite\.amneziaWg\.toolsPackage

AWG 3\.1 package with ` awg ` and ` awg-quick `\.

**Type:** package\
**Default:** proxy-suite’s patched ` amneziawg-tools ` (` pkgs/amneziawg.nix `)

<a id="services-proxy-suite-amneziawg-userspacepackage"></a>
## services\.proxy-suite\.amneziaWg\.userspacePackage

AWG 3\.1 userspace implementation, used when the kernel module is unavailable\.

**Type:** package\
**Default:** proxy-suite’s patched ` amneziawg-go ` (` pkgs/amneziawg.nix `)

<a id="services-proxy-suite-amneziawg-wireproxypackage"></a>
## services\.proxy-suite\.amneziaWg\.wireproxyPackage

wireproxy build with AWG 3\.1, used by profiles with ` asOutbound = "userspace" `\.

**Type:** package\
**Default:** proxy-suite’s ` wireproxy-awg ` (` pkgs/wireproxy-awg.nix `)
