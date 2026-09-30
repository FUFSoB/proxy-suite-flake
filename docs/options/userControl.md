# services.proxy-suite.userControl

Let a group use `proxy-ctl` without root.

Part of the [proxy-suite options reference](./index.md).

## Options

- userControl
  - [enable](#services-proxy-suite-usercontrol-enable)
  - [group](#services-proxy-suite-usercontrol-group)
  - [groups](#services-proxy-suite-usercontrol-groups)
    - `<name>`
      - [scopes](#services-proxy-suite-usercontrol-groups-name-scopes)
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

<a id="services-proxy-suite-usercontrol-groups"></a>
## services\.proxy-suite\.userControl\.groups

More groups, each with scopes of its own, alongside ` userControl.group `\. A member gets
what all of their groups allow\. ` group ` stays the one that owns proxy-suite’s files;
these are given access to them through POSIX ACLs, so the file systems of
` /var/lib/proxy-suite ` and ` /run ` must support them (the defaults do)\.

**Type:** attribute set of (submodule)\
**Default:** `{ }`\
**Example:**

```nix
{
  proxy-admins.scopes = [ ];
  proxy-users.scopes = [ "perApp" "routing" ];
}

```

<a id="services-proxy-suite-usercontrol-groups-name-scopes"></a>
## services\.proxy-suite\.userControl\.groups\.\<name>\.scopes

What this group may do, as in ` userControl.scopes `\. Empty allows everything\.

**Type:** list of (one of “services”, “perApp”, “routing”, “outbounds”, “secrets”, “autoProxy”, “zapret”, “stats”, “inbounds”, “whitelistBypass”, “amneziaWg”)\
**Default:** `[ ]`

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
 - “inbounds”: add, remove and bind runtime inbound users and listeners
   (` inbounds.runtime `), and read the secrets they are given\.
 - “whitelistBypass”: everything under ` proxy-ctl wl `\.
 - “amneziaWg”: add and remove global AmneziaWG profiles (` proxy-ctl awg add `, ` awg rm `)\.
   A global profile takes over the host’s routes and DNS\. Starting and stopping one is
   “services”; an AmneziaWG outbound is “outbounds”\.

**Type:** list of (one of “services”, “perApp”, “routing”, “outbounds”, “secrets”, “autoProxy”, “zapret”, “stats”, “inbounds”, “whitelistBypass”, “amneziaWg”)\
**Default:** `[ ]`\
**Example:** `[ "services" "routing" ]`
