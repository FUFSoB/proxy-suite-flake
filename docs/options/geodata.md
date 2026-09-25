# services.proxy-suite.geodata

Geosite and geoip databases used by routing.

Part of the [proxy-suite options reference](./index.md).

## Options

- geodata
  - singBox
    - [geoip](#services-proxy-suite-geodata-singbox-geoip)
    - [geosite](#services-proxy-suite-geodata-singbox-geosite)
  - xray
    - [assets](#services-proxy-suite-geodata-xray-assets)

<a id="services-proxy-suite-geodata-singbox-geoip"></a>
## services\.proxy-suite\.geodata\.singBox\.geoip

Package with share/sing-box/rule-set/geoip-NAME\.srs (countries by default)\.

**Type:** package\
**Default:** `pkgs.sing-geoip`

<a id="services-proxy-suite-geodata-singbox-geosite"></a>
## services\.proxy-suite\.geodata\.singBox\.geosite

Package with share/sing-box/rule-set/geosite-NAME\.srs\.

**Type:** package\
**Default:** `pkgs.sing-geosite`

<a id="services-proxy-suite-geodata-xray-assets"></a>
## services\.proxy-suite\.geodata\.xray\.assets

Package with share/v2ray/{geoip,geosite}\.dat for XRay\. ` null `: XRay’s built-in data,
which only has countries, so a tag like “geoip:telegram” breaks XRay\.

**Type:** null or package\
**Default:** `pkgs.v2ray-rules-dat`
