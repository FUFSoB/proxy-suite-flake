# services.proxy-suite.mitm

mitmproxy, to read the HTTP requests inside TLS.

Part of the [proxy-suite options reference](./index.md).

## Options

- mitm
  - [enable](#services-proxy-suite-mitm-enable)
  - [package](#services-proxy-suite-mitm-package)
  - addons
    - [userControl](#services-proxy-suite-mitm-addons-usercontrol)
  - attach
    - [enable](#services-proxy-suite-mitm-attach-enable)
    - [timeout](#services-proxy-suite-mitm-attach-timeout)
  - ca
    - [certFile](#services-proxy-suite-mitm-ca-certfile)
    - [keyFile](#services-proxy-suite-mitm-ca-keyfile)
  - [extraOptions](#services-proxy-suite-mitm-extraoptions)
  - [hosts](#services-proxy-suite-mitm-hosts)
  - [ignoreHosts](#services-proxy-suite-mitm-ignorehosts)
  - [interfaces](#services-proxy-suite-mitm-interfaces)
  - [interfacesPort](#services-proxy-suite-mitm-interfacesport)
  - listener
    - [enable](#services-proxy-suite-mitm-listener-enable)
    - [address](#services-proxy-suite-mitm-listener-address)
    - auth
      - [passwordFile](#services-proxy-suite-mitm-listener-auth-passwordfile)
      - [username](#services-proxy-suite-mitm-listener-auth-username)
    - [openFirewall](#services-proxy-suite-mitm-listener-openfirewall)
    - [port](#services-proxy-suite-mitm-listener-port)
  - [port](#services-proxy-suite-mitm-port)
  - [pythonPackages](#services-proxy-suite-mitm-pythonpackages)
  - requestLog
    - [enable](#services-proxy-suite-mitm-requestlog-enable)
    - [bodies](#services-proxy-suite-mitm-requestlog-bodies)
    - [headers](#services-proxy-suite-mitm-requestlog-headers)
    - [maxSizeMiB](#services-proxy-suite-mitm-requestlog-maxsizemib)
    - [persist](#services-proxy-suite-mitm-requestlog-persist)
  - [returnPort](#services-proxy-suite-mitm-returnport)
  - [saveFlows](#services-proxy-suite-mitm-saveflows)
  - udp
    - [enable](#services-proxy-suite-mitm-udp-enable)
    - [port](#services-proxy-suite-mitm-udp-port)
    - [relayPort](#services-proxy-suite-mitm-udp-relayport)
    - [returnPort](#services-proxy-suite-mitm-udp-returnport)
  - [upstream](#services-proxy-suite-mitm-upstream)
  - web
    - [enable](#services-proxy-suite-mitm-web-enable)
    - [passwordFile](#services-proxy-suite-mitm-web-passwordfile)
    - [port](#services-proxy-suite-mitm-web-port)

<a id="services-proxy-suite-mitm-enable"></a>
## services\.proxy-suite\.mitm\.enable

Run mitmproxy, to read the HTTP requests inside TLS\. It decrypts only what is sent
to it, and a program must trust its CA (` proxy-ctl mitm ca `) for that to work\. With
` proxy.enable ` it is also an outbound tagged “mitm”, which selection and autoProxy
never pick: send traffic to it with ` hosts `, ` interfaces `, ` listener `,
` proxy.routing.rules ` or ` proxy-ctl mitm run `\. Needs the sing-box or hybrid backend\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-package"></a>
## services\.proxy-suite\.mitm\.package

mitmproxy package\.

**Type:** package\
**Default:** `pkgs.mitmproxy`

<a id="services-proxy-suite-mitm-addons-usercontrol"></a>
## services\.proxy-suite\.mitm\.addons\.userControl

Let the groups whose ` userControl ` scopes hold ` mitm ` load addons into mitmproxy
itself (` proxy-ctl mitm addon load `), not only root\. An addon there runs as
mitmproxy’s user, which reads the CA’s key: whoever loads one can sign certificates
with it\. Prefer ` proxy-ctl mitm attach `, which runs your addons as you\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-attach-enable"></a>
## services\.proxy-suite\.mitm\.attach\.enable

Let programs attach to mitmproxy, to read the flows live and change them:
` proxy-ctl mitm attach -- mitmdump -s addon.py ` runs a mitmdump, mitmproxy or
mitmweb of your own, with your addons and your Python packages, that sees each
request, answer and WebSocket, TCP or UDP message as it comes\. With ` --modify `
what its addons change is what is sent on\. Whoever reads the request log and opens
mitmweb may attach: the groups whose ` userControl ` scopes hold ` mitm `, and root\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-mitm-attach-timeout"></a>
## services\.proxy-suite\.mitm\.attach\.timeout

Seconds an attached program that changes traffic has to answer each hook, unless it
asks for more (` --set attach_timeout=… `)\. A late one is detached, and the flow goes on
unchanged\.

**Type:** positive integer or floating point number, meaning >0\
**Default:** `5`

<a id="services-proxy-suite-mitm-ca-certfile"></a>
## services\.proxy-suite\.mitm\.ca\.certFile

Certificate of the CA mitmproxy signs with, in PEM\. ` null `: a CA is generated at
first start and kept in the state directory, readable by mitmproxy alone\. Set it,
with ` keyFile `, for a CA the system already trusts, such as one listed in
` security.pki.certificateFiles `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-suite-mitm-ca.crt"`

<a id="services-proxy-suite-mitm-ca-keyfile"></a>
## services\.proxy-suite\.mitm\.ca\.keyFile

Private key of that CA, in PEM and without a passphrase\. Needs ` certFile `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-suite-mitm-ca.key"`

<a id="services-proxy-suite-mitm-extraoptions"></a>
## services\.proxy-suite\.mitm\.extraOptions

More of mitmproxy’s options, as in its ` config.yaml `\. They are set after
proxy-suite’s own and override them, but for ` scripts `, which are added to its own\.

**Type:** attribute set of (boolean or signed integer or string or list of string)\
**Default:** `{ }`\
**Example:** `{ anticache = true; flow_detail = 2; }`

<a id="services-proxy-suite-mitm-hosts"></a>
## services\.proxy-suite\.mitm\.hosts

Domains, with their subdomains, sent to mitmproxy wherever they come from\. Needs
` proxy.enable `\. ` proxy-ctl mitm hosts add ` adds more without a rebuild\.

**Type:** list of string matching the pattern \[A-Za-z0-9\._-]+\
**Default:** `[ ]`\
**Example:** `[ "example.com" ]`

<a id="services-proxy-suite-mitm-ignorehosts"></a>
## services\.proxy-suite\.mitm\.ignoreHosts

Domains, with their subdomains, that mitmproxy passes on undecrypted: for programs that
pin their certificates\.

**Type:** list of string matching the pattern \[A-Za-z0-9\._-]+\
**Default:** `[ ]`\
**Example:** `[ "example.com" ]`

<a id="services-proxy-suite-mitm-interfaces"></a>
## services\.proxy-suite\.mitm\.interfaces

Interfaces of containers, virtual machines or LAN devices that use this host as their
gateway: all TCP they send is intercepted, with nothing to set up in them but the CA\.
UDP to port 443 is refused, so they fall back from QUIC; the rest of their UDP is
forwarded as usual, or with ` udp.enable ` read too\. Turns on IP forwarding\. Needs
` proxy.enable `, root and, on NixOS, the nftables firewall\.

**Type:** list of network interface name\
**Default:** `[ ]`\
**Example:** `[ "waydroid0" ]`

<a id="services-proxy-suite-mitm-interfacesport"></a>
## services\.proxy-suite\.mitm\.interfacesPort

Loopback port of the backend that ` interfaces ` are diverted to\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18529`

<a id="services-proxy-suite-mitm-listener-enable"></a>
## services\.proxy-suite\.mitm\.listener\.enable

Listen for programs and devices pointed straight at mitmproxy: everything that
connects here is intercepted\. An HTTP proxy, and SOCKS5 too with ` proxy.enable `,
its UDP read with ` udp.enable `\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-mitm-listener-address"></a>
## services\.proxy-suite\.mitm\.listener\.address

Address of that listener\. Use “0\.0\.0\.0” or a LAN address to intercept another
device, which then opens http://mitm\.it for the CA; set ` auth ` with it\.

**Type:** IP address or host name\
**Default:** `"127.0.0.1"`\
**Example:** `"0.0.0.0"`

<a id="services-proxy-suite-mitm-listener-auth-passwordfile"></a>
## services\.proxy-suite\.mitm\.listener\.auth\.passwordFile

File with the password for that listener, a single word\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-suite-mitm-password"`

<a id="services-proxy-suite-mitm-listener-auth-username"></a>
## services\.proxy-suite\.mitm\.listener\.auth\.username

Username for that listener\. Needs ` passwordFile `\.

**Type:** null or string matching the pattern \[^\[:space:]:]+\
**Default:** `null`\
**Example:** `"mitm-user"`

<a id="services-proxy-suite-mitm-listener-openfirewall"></a>
## services\.proxy-suite\.mitm\.listener\.openFirewall

Open the firewall for that listener\. Needs an ` address ` off loopback\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-listener-port"></a>
## services\.proxy-suite\.mitm\.listener\.port

Port of that listener\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `1088`

<a id="services-proxy-suite-mitm-port"></a>
## services\.proxy-suite\.mitm\.port

Loopback port mitmproxy takes the backend’s connections on, with ` proxy.enable `\. It
takes no login, so on a host with root only proxy-suite’s daemons and root may
connect to it; everything else comes in through ` listener `\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18531`

<a id="services-proxy-suite-mitm-pythonpackages"></a>
## services\.proxy-suite\.mitm\.pythonPackages

Python packages for the addons mitmproxy itself runs: ` extraOptions.scripts ` and those
` proxy-ctl mitm addon load ` loads\. From ` pkgs.python3.pkgs `, the Python mitmproxy is
built with\. Not needed for ` attach `, whose addons run in your own mitmdump\.

**Type:** function that evaluates to a(n) list of package\
**Default:** `ps: [ ]`\
**Example:** `ps: [ ps.msgpack ps.pycryptodome ]`

<a id="services-proxy-suite-mitm-requestlog-enable"></a>
## services\.proxy-suite\.mitm\.requestLog\.enable

Append a line of JSON for each request to ` requests.jsonl `, for jq and the like: the
time, client, method, URL, status or error, duration, sizes and content type\. A
WebSocket, TCP or UDP flow gets one as it ends, with the messages and bytes each way\.
` proxy-ctl mitm requests on|off ` switches it without a rebuild, and
` proxy-ctl mitm requests follow ` streams it (` > session.jsonl ` to keep one)\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-requestlog-bodies"></a>
## services\.proxy-suite\.mitm\.requestLog\.bodies

Also write each request whole, bodies included, as mitmproxy’s flows to
` requests.mitm ` beside that log: for an addon of your own, run by you with what it
needs, ` proxy-ctl mitm requests follow --bodies | mitmdump -nr - -s addon.py `\.
` proxy-ctl mitm requests bodies on|off ` switches it without a rebuild\. Rotated
and readable as the log is, whether or not that is on\. A WebSocket, TCP or UDP flow
is written in parts as it goes, at each MiB or ten seconds, each with the messages
since the last and the flow’s id\. For the flows live as they come, attach instead\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-requestlog-headers"></a>
## services\.proxy-suite\.mitm\.requestLog\.headers

Put the requests’ and answers’ headers in that log too, as ` [name, value] ` pairs:
cookies and logins among them\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-requestlog-maxsizemib"></a>
## services\.proxy-suite\.mitm\.requestLog\.maxSizeMiB

Rotate that log at this size, in MiB, to ` requests.jsonl.1 `, replacing the one there\.

**Type:** positive integer or floating point number, meaning >0\
**Default:** `64`

<a id="services-proxy-suite-mitm-requestlog-persist"></a>
## services\.proxy-suite\.mitm\.requestLog\.persist

Keep that log across restarts and reboots, in ` mitm-requests ` beside the state
directory\. Without, it is in memory under the runtime directory and gone when
mitmproxy stops\. Either way the groups whose ` userControl ` scopes hold ` mitm ` read
it, as they open mitmweb; nobody else but root and mitmproxy’s user\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-returnport"></a>
## services\.proxy-suite\.mitm\.returnPort

Loopback port of the backend that mitmproxy sends what it has read on to, with
` proxy.enable `\. From there it leaves through ` upstream `\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18532`

<a id="services-proxy-suite-mitm-saveflows"></a>
## services\.proxy-suite\.mitm\.saveFlows

Keep every request and answer, bodies included, in the state directory
(` flows.mitm `, for ` mitmproxy -r `)\. It grows until deleted\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-udp-enable"></a>
## services\.proxy-suite\.mitm\.udp\.enable

Send mitmproxy the UDP that goes to “mitm” as well: what ` hosts `, ` listener `
(SOCKS5), ` interfaces ` and the routing rules send there\. The backend hands it over
through a WireGuard tunnel on loopback, and what mitmproxy sends on comes back to the
backend to leave by ` upstream `, as TCP does\. mitmproxy reads each datagram as a
message of a UDP flow: in mitmweb, the request log and attached programs\. QUIC (UDP
to port 443) is still refused, so browsers take TCP\. Needs ` proxy.enable `, root
and, on NixOS, the nftables firewall\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-udp-port"></a>
## services\.proxy-suite\.mitm\.udp\.port

Loopback UDP port of mitmproxy’s WireGuard listener, which the backend dials\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18527`

<a id="services-proxy-suite-mitm-udp-relayport"></a>
## services\.proxy-suite\.mitm\.udp\.relayPort

Loopback port of the backend’s SOCKS5 listener that the TUN backends (global TUN,
per-app TUN and its pinned apps) hand their UDP for mitmproxy to: the tunnel into it
has one end, in that backend\. It takes the hop login\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18526`

<a id="services-proxy-suite-mitm-udp-returnport"></a>
## services\.proxy-suite\.mitm\.udp\.returnPort

Loopback port of the backend that the UDP mitmproxy sends on is diverted to, to leave
by ` upstream `\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18528`

<a id="services-proxy-suite-mitm-upstream"></a>
## services\.proxy-suite\.mitm\.upstream

Where intercepted traffic leaves\.

 - “direct”: straight from the uplink\. The only choice without ` proxy.enable `\.
 - “proxy”: through the outbound in use, as everything else does\.
 - an outbound or group tag: through that one, to read a site that is blocked here\.

` proxy-ctl mitm upstream ` changes it without a rebuild\.

**Type:** string\
**Default:** ` "proxy" ` with ` proxy.enable `, ` "direct" ` without\
**Example:** `"nl-vps"`

<a id="services-proxy-suite-mitm-web-enable"></a>
## services\.proxy-suite\.mitm\.web\.enable

Run mitmweb, which shows the requests in a browser, instead of mitmdump, which
logs a line for each\. ` proxy-ctl mitm web ` prints its address and password\. It
shows passwords and cookies as they are sent\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-mitm-web-passwordfile"></a>
## services\.proxy-suite\.mitm\.web\.passwordFile

File with mitmweb’s password\. ` null `: one is generated at first start and kept in
the state directory\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-suite-mitmweb-password"`

<a id="services-proxy-suite-mitm-web-port"></a>
## services\.proxy-suite\.mitm\.web\.port

Loopback port of mitmweb\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `18536`
