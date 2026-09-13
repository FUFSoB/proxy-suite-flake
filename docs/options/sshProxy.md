# services.proxy-suite.sshProxy

Part of the [proxy-suite options reference](./index.md).

## Options

- sshProxy
  - [enable](#services-proxy-suite-sshproxy-enable)
  - [asOutbound](#services-proxy-suite-sshproxy-asoutbound)
  - [domainStrategy](#services-proxy-suite-sshproxy-domainstrategy)
  - [extraArgs](#services-proxy-suite-sshproxy-extraargs)
  - [hostKey](#services-proxy-suite-sshproxy-hostkey)
  - [hostKeyFile](#services-proxy-suite-sshproxy-hostkeyfile)
  - [identityFile](#services-proxy-suite-sshproxy-identityfile)
  - [knownHostsFile](#services-proxy-suite-sshproxy-knownhostsfile)
  - listener
    - [address](#services-proxy-suite-sshproxy-listener-address)
    - [port](#services-proxy-suite-sshproxy-listener-port)
  - server
    - [host](#services-proxy-suite-sshproxy-server-host)
    - [port](#services-proxy-suite-sshproxy-server-port)
    - [user](#services-proxy-suite-sshproxy-server-user)
  - [serviceUser](#services-proxy-suite-sshproxy-serviceuser)
  - [strictHostKeyChecking](#services-proxy-suite-sshproxy-stricthostkeychecking)

<a id="services-proxy-suite-sshproxy-enable"></a>
## services\.proxy-suite\.sshProxy\.enable

Whether to enable an SSH dynamic SOCKS5 tunnel\.

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

<a id="services-proxy-suite-sshproxy-asoutbound"></a>
## services\.proxy-suite\.sshProxy\.asOutbound

Add the tunnel as an outbound tagged “ssh-proxy”\. sing-box dials SSH itself; XRay goes
through the OpenSSH unit’s SOCKS listener\.

*Type:*
boolean

*Default:*

```nix
false
```

<a id="services-proxy-suite-sshproxy-domainstrategy"></a>
## services\.proxy-suite\.sshProxy\.domainStrategy

Resolve destinations locally before the tunnel (XRay only)\. Can break geo-steered CDNs\.

*Type:*
null or one of “prefer_ipv4”, “prefer_ipv6”, “ipv4_only”, “ipv6_only”

*Default:*

```nix
null
```

*Example:*

```nix
"prefer_ipv4"
```

<a id="services-proxy-suite-sshproxy-extraargs"></a>
## services\.proxy-suite\.sshProxy\.extraArgs

Extra OpenSSH arguments\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "-J"
  "jump.example.com"
]
```

<a id="services-proxy-suite-sshproxy-hostkey"></a>
## services\.proxy-suite\.sshProxy\.hostKey

Accepted host keys (sing-box)\. List every key ` ssh-keyscan ` prints: the algorithm is
negotiated\. Empty accepts any key\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."
]
```

<a id="services-proxy-suite-sshproxy-hostkeyfile"></a>
## services\.proxy-suite\.sshProxy\.hostKeyFile

Known-hosts file to read hostKey from at runtime (sing-box)\. Wins over hostKey\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/root/.ssh/known_hosts"
```

<a id="services-proxy-suite-sshproxy-identityfile"></a>
## services\.proxy-suite\.sshProxy\.identityFile

Runtime path to the private key\. Null uses the agent or OpenSSH defaults\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-suite-ssh-key"
```

<a id="services-proxy-suite-sshproxy-knownhostsfile"></a>
## services\.proxy-suite\.sshProxy\.knownHostsFile

Known-hosts file for OpenSSH\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/proxy-suite-ssh-known-hosts"
```

<a id="services-proxy-suite-sshproxy-listener-address"></a>
## services\.proxy-suite\.sshProxy\.listener\.address

Address of the OpenSSH SOCKS5 listener\.

*Type:*
string matching the pattern \[^\[:space:]]+

*Default:*

```nix
"127.0.0.1"
```

<a id="services-proxy-suite-sshproxy-listener-port"></a>
## services\.proxy-suite\.sshProxy\.listener\.port

Port of the OpenSSH SOCKS5 listener\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
1091
```

<a id="services-proxy-suite-sshproxy-server-host"></a>
## services\.proxy-suite\.sshProxy\.server\.host

SSH server\.

*Type:*
null or string matching the pattern \[^\[:space:]]+

*Default:*

```nix
null
```

*Example:*

```nix
"ssh.example.com"
```

<a id="services-proxy-suite-sshproxy-server-port"></a>
## services\.proxy-suite\.sshProxy\.server\.port

SSH server port\.

*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)

*Default:*

```nix
22
```

<a id="services-proxy-suite-sshproxy-server-user"></a>
## services\.proxy-suite\.sshProxy\.server\.user

SSH login user\.

*Type:*
null or string matching the pattern \[^\[:space:]]+

*Default:*

```nix
null
```

*Example:*

```nix
"root"
```

<a id="services-proxy-suite-sshproxy-serviceuser"></a>
## services\.proxy-suite\.sshProxy\.serviceUser

Unix user running the OpenSSH unit\.

*Type:*
null or string matching the pattern \[^\[:space:]]+

*Default:*

```nix
null
```

*Example:*

```nix
"proxy"
```

<a id="services-proxy-suite-sshproxy-stricthostkeychecking"></a>
## services\.proxy-suite\.sshProxy\.strictHostKeyChecking

OpenSSH host key policy\.

*Type:*
one of “yes”, “accept-new”, “no”

*Default:*

```nix
"accept-new"
```

*Example:*

```nix
"yes"
```
