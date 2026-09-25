# services.proxy-suite.userControl

Let a group use `proxy-ctl` without root.

Part of the [proxy-suite options reference](./index.md).

## Options

- userControl
  - [enable](#services-proxy-suite-usercontrol-enable)
  - [group](#services-proxy-suite-usercontrol-group)
  - [scopes](#services-proxy-suite-usercontrol-scopes)

<a id="services-proxy-suite-usercontrol-enable"></a>
## services\.proxy-suite\.userControl\.enable

Whether to enable ` proxy-ctl ` without root for members of ` userControl.group `\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-usercontrol-group"></a>
## services\.proxy-suite\.userControl\.group

Group whose members can run privileged ` proxy-ctl ` commands\.

**Type:** string matching the pattern ^\[a-z_]\[a-z0-9_-]\*$\
**Default:** `"proxy-suite"`

<a id="services-proxy-suite-usercontrol-scopes"></a>
## services\.proxy-suite\.userControl\.scopes

What the group may do\. Empty allows everything\.

 - “services”: start, stop and restart services, and ` tor newnym `\.
 - “perApp”: ` proxy-ctl apps run `\.
 - “routing”: ` proxy pin `, ` proxy unpin ` and ` proxy mode `\.
 - “outbounds”: add, remove, enable and disable outbounds and subscriptions\.
 - “secrets”: read share links, subscription URLs and running configs\.
 - “autoProxy”: see and change what autoProxy learned\.
 - “zapret”: change zapret2’s learned sites, and ` zapret cutoff probe `\.
 - “stats”: ` inbounds stats `\.
 - “whitelistBypass”: everything under ` proxy-ctl wl `\.

**Type:** list of (one of “services”, “perApp”, “routing”, “outbounds”, “secrets”, “autoProxy”, “zapret”, “stats”, “whitelistBypass”)\
**Default:** `[ ]`\
**Example:** `[ "services" "routing" ]`
