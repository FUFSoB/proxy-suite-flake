# services.proxy-suite.tools

Heavy helpers `proxy-ctl` can do without: lnav and curl-impersonate.

Part of the [proxy-suite options reference](./index.md).

## Options

- tools
  - curlImpersonate
    - [enable](#services-proxy-suite-tools-curlimpersonate-enable)
  - lnav
    - [enable](#services-proxy-suite-tools-lnav-enable)

<a id="services-proxy-suite-tools-curlimpersonate-enable"></a>
## services\.proxy-suite\.tools\.curlImpersonate\.enable

Probe with curl-impersonate (` proxy-ctl proxy auto probe `, and autoProxy), which
presents a browser’s TLS fingerprint\. Without it probes use plain curl, which some
bot protection refuses, so a working exit can be judged blocked\.

**Type:** boolean\
**Default:** ` true `, ` false ` on nix-on-droid

<a id="services-proxy-suite-tools-lnav-enable"></a>
## services\.proxy-suite\.tools\.lnav\.enable

Follow ` proxy-ctl logs ` in lnav\. Without it they follow in less\.

**Type:** boolean\
**Default:** ` true `, ` false ` on nix-on-droid
