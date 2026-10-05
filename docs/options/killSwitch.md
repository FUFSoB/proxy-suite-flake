# services.proxy-suite.killSwitch

Block traffic outside the global tunnel.

Part of the [proxy-suite options reference](./index.md).

## Options

- killSwitch
  - [enable](#services-proxy-suite-killswitch-enable)
  - [allowedSubnets](#services-proxy-suite-killswitch-allowedsubnets)
  - [directFallbacks](#services-proxy-suite-killswitch-directfallbacks)
  - [timeSyncUsers](#services-proxy-suite-killswitch-timesyncusers)

<a id="services-proxy-suite-killswitch-enable"></a>
## services\.proxy-suite\.killSwitch\.enable

Block outgoing traffic that bypasses the active global tunnel (TUN, TProxy or a global
AmneziaWG profile) from boot until the tunnel is up, while it restarts and after it
fails\. LAN, DHCP and the time daemons’ NTP stay open\. Forwarded traffic TProxy does not
divert reaches the LAN only from ` proxy.tproxy.lanInterfaces `\. With TUN or a global
AmneziaWG profile configured, containers’ and VMs’ traffic is held to the LAN too while
neither that tunnel nor TProxy is up\. Only turning the tunnel off with ` proxy-ctl `, or
` proxy-ctl killswitch off `, lifts it, until the next boot or tunnel start\.

**Type:** boolean\
**Default:** `false`

<a id="services-proxy-suite-killswitch-allowedsubnets"></a>
## services\.proxy-suite\.killSwitch\.allowedSubnets

Networks the kill switch leaves open besides the private and reserved ranges, such as
a routed IPv6 prefix on a VM bridge, whichever global mode is on\. The default keeps
what TProxy leaves out reachable; set it to open a network without also taking it out
of TProxy\.

**Type:** list of IPv4 or IPv6 address or CIDR\
**Default:** `config.services.proxy-suite.proxy.tproxy.localSubnets`\
**Example:** `[ "192.168.0.0/16" "2001:db8:1::/64" ]`

<a id="services-proxy-suite-killswitch-directfallbacks"></a>
## services\.proxy-suite\.killSwitch\.directFallbacks

Whether, with the kill switch on, a subscription that cannot be fetched through the
tunnel is fetched once more directly, and WARP registers directly when the local proxy
cannot carry it\. Either shows that server this host’s own address\. Off, both go through
the tunnel or not at all: a cold start with nothing cached then has no outbounds from
that subscription, and a WARP device that is itself the tunnel cannot register\.

**Type:** boolean\
**Default:** `true`

<a id="services-proxy-suite-killswitch-timesyncusers"></a>
## services\.proxy-suite\.killSwitch\.timeSyncUsers

Users that may send NTP (UDP port 123) past the kill switch\. Users that do not exist
are skipped when it starts\. A daemon sending from port 123 itself, as ntpd does, needs
no entry\.

**Type:** list of string\
**Default:** the users of the enabled timesyncd, chrony, ntp and openntpd on NixOS; elsewhere ` [ "systemd-timesync" "chrony" "_chrony" "ntp" "ntpsec" ] `\
**Example:** `[ "chrony" ]`
