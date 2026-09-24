# services.proxy-suite.whitelistBypass

Part of the [proxy-suite options reference](./index.md).

## Options

- whitelistBypass
  - [enable](#services-proxy-suite-whitelistbypass-enable)
  - [package](#services-proxy-suite-whitelistbypass-package)
  - [creators](#services-proxy-suite-whitelistbypass-creators)
    - `<name>`
      - [cookiesFile](#services-proxy-suite-whitelistbypass-creators-name-cookiesfile)
      - [linkFile](#services-proxy-suite-whitelistbypass-creators-name-linkfile)
      - [platform](#services-proxy-suite-whitelistbypass-creators-name-platform)
      - [resources](#services-proxy-suite-whitelistbypass-creators-name-resources)
      - [upstream](#services-proxy-suite-whitelistbypass-creators-name-upstream)
  - [joiners](#services-proxy-suite-whitelistbypass-joiners)
    - `<name>`
      - [linkFile](#services-proxy-suite-whitelistbypass-joiners-name-linkfile)
      - [platform](#services-proxy-suite-whitelistbypass-joiners-name-platform)

<a id="services-proxy-suite-whitelistbypass-enable"></a>
## services\.proxy-suite\.whitelistBypass\.enable

Whether to enable tunnels through the media servers of video calls, which mobile internet whitelists let
through ([whitelist-bypass](https://github\.com/kulikov0/whitelist-bypass))\. A creator on a
free host serves exactly one joiner on a censored one\.

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

<a id="services-proxy-suite-whitelistbypass-package"></a>
## services\.proxy-suite\.whitelistBypass\.package

whitelist-bypass package with the headless creators and joiners\.

*Type:*
package

*Default:*
proxy-suite’s ` whitelist-bypass ` (` pkgs/whitelist-bypass.nix `)

<a id="services-proxy-suite-whitelistbypass-creators"></a>
## services\.proxy-suite\.whitelistBypass\.creators

Creators, one per joiner device\. The link each uses is in its log\.

*Type:*
attribute set of (submodule)

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  phone = {
    cookiesFile = "/run/secrets/whitelist-bypass-cookies-wbstream.json";
    platform = "wbstream";
    upstream = "proxy";
  };
}
```

<a id="services-proxy-suite-whitelistbypass-creators-name-cookiesfile"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.cookiesFile

Runtime path to the platform’s cookies, as the upstream desktop Creator exports them\.
Copied into the state directory on first start only: DION and Bitrix rotate their
refresh token into that copy, and a stale one would kill the session\. Delete
` <stateDir>/whitelist-bypass/<name>.cookies.json ` to take a new export\.

*Type:*
string

*Example:*

```nix
"/run/secrets/whitelist-bypass-cookies-wbstream.json"
```

<a id="services-proxy-suite-whitelistbypass-creators-name-linkfile"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.linkFile

Runtime path to the call to rejoin\. Null rejoins the last call written to
` <stateDir>/whitelist-bypass/<name>.link `, and creates one on first start: the link
stays the same across restarts, so the joiner needs it only once\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"/run/secrets/whitelist-bypass-link"
```

<a id="services-proxy-suite-whitelistbypass-creators-name-platform"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.platform

Call platform\. Every one needs an account: “vk” only serves the upstream Android app,
the rest a joiner of this module too\.

*Type:*
one of “wbstream”, “telemost”, “dion”, “bitrix”, “vk”

*Example:*

```nix
"wbstream"
```

<a id="services-proxy-suite-whitelistbypass-creators-name-resources"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.resources

Buffer sizes and Go memory limit: 64, 128 or 256 MB\.

*Type:*
one of “moderate”, “default”, “unlimited”

*Default:*

```nix
"moderate"
```

<a id="services-proxy-suite-whitelistbypass-creators-name-upstream"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.upstream

Where the joiner’s traffic leaves\.

 - “direct”: from this host, past TUN and TProxy (it runs as proxy-suite-daemon)\.
 - “proxy”: through the local proxy listener (proxy\.listener, with its auth), and so
   its outbounds and routing\.

*Type:*
one of “direct”, “proxy”

*Default:*

```nix
"direct"
```

<a id="services-proxy-suite-whitelistbypass-joiners"></a>
## services\.proxy-suite\.whitelistBypass\.joiners

Joiners, each an outbound tagged with its name: a loopback SOCKS5 listener that tunnels
through the call\. Needs proxy\.enable\.

*Type:*
attribute set of (submodule)

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  wl = {
    linkFile = "/run/secrets/whitelist-bypass-link";
    platform = "wbstream";
  };
}
```

<a id="services-proxy-suite-whitelistbypass-joiners-name-linkfile"></a>
## services\.proxy-suite\.whitelistBypass\.joiners\.\<name>\.linkFile

Runtime path to the call link the creator printed (or wrote to its state directory):
a WB Stream room id, a Telemost link, a DION event slug or a Bitrix conference link\.

*Type:*
string

*Example:*

```nix
"/run/secrets/whitelist-bypass-link"
```

<a id="services-proxy-suite-whitelistbypass-joiners-name-platform"></a>
## services\.proxy-suite\.whitelistBypass\.joiners\.\<name>\.platform

Call platform the creator on the other end uses\. VK has no Linux joiner\.

*Type:*
one of “wbstream”, “telemost”, “dion”, “bitrix”

*Example:*

```nix
"wbstream"
```
