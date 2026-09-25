# services.proxy-suite.sshProxy

An SSH SOCKS5 tunnel, optionally as an outbound.

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

Whether to enable an SSH SOCKS5 tunnel\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-sshproxy-asoutbound"></a>
## services\.proxy-suite\.sshProxy\.asOutbound

Add the tunnel as an outbound tagged “ssh-proxy”\. On sing-box and hybrid, sing-box connects
over SSH itself and needs ` hostKey ` or ` hostKeyFile `\. Otherwise OpenSSH runs a SOCKS listener, set up
by ` listener `, ` knownHostsFile `, ` strictHostKeyChecking `, ` serviceUser ` and ` extraArgs `\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-sshproxy-domainstrategy"></a>
## services\.proxy-suite\.sshProxy\.domainStrategy

Resolve names locally instead of on the server (XRay only)\. Can make CDNs pick distant servers\.

**Type:** null or one of “prefer_ipv4”, “prefer_ipv6”, “ipv4_only”, “ipv6_only”\
**Default:** `null`\
**Example:** `"prefer_ipv4"`

<a id="services-proxy-suite-sshproxy-extraargs"></a>
## services\.proxy-suite\.sshProxy\.extraArgs

Extra OpenSSH arguments\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "-J" "jump.example.com" ]`

<a id="services-proxy-suite-sshproxy-hostkey"></a>
## services\.proxy-suite\.sshProxy\.hostKey

Accepted host keys, for sing-box\. List every key ` ssh-keyscan ` prints, since the key type
is negotiated\.

**Type:** list of string\
**Default:** `[ ]`\
**Example:** `[ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..." ]`

<a id="services-proxy-suite-sshproxy-hostkeyfile"></a>
## services\.proxy-suite\.sshProxy\.hostKeyFile

Known-hosts file to read host keys from (sing-box)\. Takes priority over ` hostKey `\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/root/.ssh/known_hosts"`

<a id="services-proxy-suite-sshproxy-identityfile"></a>
## services\.proxy-suite\.sshProxy\.identityFile

File with the SSH private key\. It can stay root-only\. ` null `: the agent or OpenSSH defaults\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-suite-ssh-key"`

<a id="services-proxy-suite-sshproxy-knownhostsfile"></a>
## services\.proxy-suite\.sshProxy\.knownHostsFile

Known-hosts file for OpenSSH\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/proxy-suite-ssh-known-hosts"`

<a id="services-proxy-suite-sshproxy-listener-address"></a>
## services\.proxy-suite\.sshProxy\.listener\.address

Address of the OpenSSH SOCKS5 listener\.

**Type:** string matching the pattern \[^\[:space:]]+\
**Default:** `"127.0.0.1"`

<a id="services-proxy-suite-sshproxy-listener-port"></a>
## services\.proxy-suite\.sshProxy\.listener\.port

Port of the OpenSSH SOCKS5 listener\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `1091`

<a id="services-proxy-suite-sshproxy-server-host"></a>
## services\.proxy-suite\.sshProxy\.server\.host

SSH server\.

**Type:** null or string matching the pattern \[^\[:space:]]+\
**Default:** `null`\
**Example:** `"ssh.example.com"`

<a id="services-proxy-suite-sshproxy-server-port"></a>
## services\.proxy-suite\.sshProxy\.server\.port

SSH server port\.

**Type:** 16 bit unsigned integer; between 0 and 65535 (both inclusive)\
**Default:** `22`

<a id="services-proxy-suite-sshproxy-server-user"></a>
## services\.proxy-suite\.sshProxy\.server\.user

SSH login user\.

**Type:** null or string matching the pattern \[^\[:space:]]+\
**Default:** `null`\
**Example:** `"root"`

<a id="services-proxy-suite-sshproxy-serviceuser"></a>
## services\.proxy-suite\.sshProxy\.serviceUser

User that runs OpenSSH\. The default is sandboxed; ` null ` runs it as root\.

**Type:** null or string matching the pattern \[^\[:space:]]+\
**Default:** `"proxy-suite-daemon"`\
**Example:** `"proxy"`

<a id="services-proxy-suite-sshproxy-stricthostkeychecking"></a>
## services\.proxy-suite\.sshProxy\.strictHostKeyChecking

OpenSSH host key policy\.

**Type:** one of “yes”, “accept-new”, “no”\
**Default:** `"accept-new"`\
**Example:** `"yes"`
