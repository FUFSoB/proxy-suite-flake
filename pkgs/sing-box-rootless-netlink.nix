# sing-box for hosts where an app may not join netlink's route groups (nix-on-droid).
#
# The network monitor subscribes to route, link and address changes, and Android's
# SELinux policy refuses an app that. sing-tun only checks for that on GOOS=android,
# so a linux build starts the monitor anyway and the whole service fails with
# "subscribe netlink groups: permission denied". Checking when the monitor is created
# instead makes that fail, and sing-box then goes on without one unless
# auto_detect_interface asks for it, which only TUN configs do.
{ sing-box }:

sing-box.overrideAttrs (old: {
  postConfigure = (old.postConfigure or "") + ''
        tun=vendor/github.com/sagernet/sing-tun
        chmod -R u+w "$tun"
        cp ${./patches/sing-tun-netlink-groups-probe.go} "$tun/monitor_linux_groups_probe.go"
        substituteInPlace "$tun/monitor_linux.go" --replace-fail \
          'func NewNetworkUpdateMonitor(logger logger.Logger) (NetworkUpdateMonitor, error) {' \
          'func NewNetworkUpdateMonitor(logger logger.Logger) (NetworkUpdateMonitor, error) {
    	if netlinkGroupsBanned() {
    		return nil, ErrNetlinkBanned
    	}'
  '';
  passthru = (old.passthru or { }) // {
    rootlessNetlink = true;
  };
})
