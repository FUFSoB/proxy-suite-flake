# services.proxy-suite.whitelistBypass

Tunnels through video-call servers, past mobile internet whitelists.

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

Tunnel through video-call servers, which mobile internet whitelists let through
([whitelist-bypass](https://github\.com/kulikov0/whitelist-bypass))\. A creator on a free
host serves one joiner on a censored one\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-whitelistbypass-package"></a>
## services\.proxy-suite\.whitelistBypass\.package

whitelist-bypass package\.

**Type:** package\
**Default:** proxy-suite’s ` whitelist-bypass ` (` pkgs/whitelist-bypass.nix `)

<a id="services-proxy-suite-whitelistbypass-creators"></a>
## services\.proxy-suite\.whitelistBypass\.creators

Creators, one per joiner device\. Each logs the call link its joiner needs (also ` proxy-ctl wl link `)\.

**Type:** attribute set of (submodule)\
**Default:** `{ }`\
**Example:**

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

File with the platform’s cookies, as exported by the upstream desktop Creator\. Read on
first start only, since the login refreshes itself afterwards\. ` proxy-ctl wl auth <name> ` replaces it at runtime (or asks for email and password on DION and Bitrix)\.
` null `: the creator waits for that\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/whitelist-bypass-cookies-wbstream.json"`

<a id="services-proxy-suite-whitelistbypass-creators-name-linkfile"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.linkFile

File with a call link to rejoin\. ` null `: create a call once and keep reusing it, so
the joiner needs the link only once\. ` proxy-ctl wl new <name> ` starts a new call if the
platform closed the old one\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/whitelist-bypass-link"`

<a id="services-proxy-suite-whitelistbypass-creators-name-platform"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.platform

Call platform\. Each needs an account\. “vk” only serves the upstream Android joiner app\.

**Type:** one of “wbstream”, “telemost”, “dion”, “bitrix”, “vk”\
**Example:** `"wbstream"`

<a id="services-proxy-suite-whitelistbypass-creators-name-resources"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.resources

Memory budget: 64, 128 or 256 MB\.

**Type:** one of “moderate”, “default”, “unlimited”\
**Default:** `"moderate"`

<a id="services-proxy-suite-whitelistbypass-creators-name-upstream"></a>
## services\.proxy-suite\.whitelistBypass\.creators\.\<name>\.upstream

Where the traffic from this creator’s joiner exits\.

 - “direct”: straight from this host, bypassing TUN and TProxy\.
 - “proxy”: through the local proxy and its routing\.

**Type:** one of “direct”, “proxy”\
**Default:** `"direct"`

<a id="services-proxy-suite-whitelistbypass-joiners"></a>
## services\.proxy-suite\.whitelistBypass\.joiners

Joiners, each an outbound tagged with its name that tunnels through the call\. Needs
` proxy.enable `\.

**Type:** attribute set of (submodule)\
**Default:** `{ }`\
**Example:**

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

File with the call link from the creator’s log\. ` proxy-ctl wl join <name> <link> ` sets
one at runtime and takes priority\. ` null `: the joiner waits for that\.

**Type:** null or string\
**Default:** `null`\
**Example:** `"/run/secrets/whitelist-bypass-link"`

<a id="services-proxy-suite-whitelistbypass-joiners-name-platform"></a>
## services\.proxy-suite\.whitelistBypass\.joiners\.\<name>\.platform

Call platform the creator uses\. VK has no joiner here\.

**Type:** one of “wbstream”, “telemost”, “dion”, “bitrix”\
**Example:** `"wbstream"`
