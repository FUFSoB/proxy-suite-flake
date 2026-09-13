# services.proxy-suite.geodata

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

Package with share/sing-box/rule-set/geoip-NAME\.srs (country codes by default)\.

*Type:*
package

*Default:*

```nix
pkgs.sing-geoip
```

<a id="services-proxy-suite-geodata-singbox-geosite"></a>
## services\.proxy-suite\.geodata\.singBox\.geosite

Package with share/sing-box/rule-set/geosite-NAME\.srs\.

*Type:*
package

*Default:*

```nix
pkgs.sing-geosite
```

<a id="services-proxy-suite-geodata-xray-assets"></a>
## services\.proxy-suite\.geodata\.xray\.assets

Package with share/v2ray/{geoip,geosite}\.dat for every XRay process\. Null uses XRay’s own
country-only data, where a tag like “geoip:telegram” stops XRay from starting\.

*Type:*
null or package

*Default:*

```nix
pkgs.v2ray-rules-dat
```
