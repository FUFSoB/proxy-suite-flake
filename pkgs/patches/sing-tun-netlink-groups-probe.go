//go:build linux

package tun

import "golang.org/x/sys/unix"

// netlinkGroupsBanned reports whether this process may not join NETLINK_ROUTE's
// multicast groups, which the monitor subscribes to. Android's SELinux policy lets an
// app open the socket but not join them; sing-tun only checks on GOOS=android, and
// nix-on-droid runs linux binaries.
func netlinkGroupsBanned() bool {
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_ROUTE)
	if err != nil {
		return true
	}
	defer unix.Close(fd)
	return unix.Bind(fd, &unix.SockaddrNetlink{
		Family: unix.AF_NETLINK,
		Groups: unix.RTMGRP_LINK | unix.RTMGRP_IPV4_IFADDR | unix.RTMGRP_IPV6_IFADDR | unix.RTMGRP_IPV4_ROUTE | unix.RTMGRP_IPV6_ROUTE,
	}) != nil
}
