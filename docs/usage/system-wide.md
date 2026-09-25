# Route the whole machine

Send every app's traffic through the proxy, including apps with no proxy settings. There
are two global modes, and either can start at boot.

## Config

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    tun.enable = true;
    autostart = "tun"; # or null, to start it by hand
  };
  killSwitch.enable = true;
};
```

## TUN or TProxy

- **TUN** adds a virtual network interface and routes everything into it. It is the usual
  pick.
- **TProxy** intercepts TCP and UDP with nftables instead of adding an interface. Pick it if
  this host is a gateway for other devices: list their interfaces in
  `proxy.tproxy.lanInterfaces` (NixOS needs `networking.nftables.enable` for that).

You can enable both and switch between them. Starting one global mode stops the other, and
an AmneziaWG profile running as a global VPN counts as one too.

Your [routing rules](./routing.md) still apply in both modes. Sites that the rules send
direct skip the proxy.

## Commands

```sh
proxy-ctl proxy tun on        # or: off, toggle, restart
proxy-ctl proxy tproxy on
proxy-ctl status              # which mode is running
proxy-ctl killswitch          # kill switch state
proxy-ctl killswitch off      # lift the kill switch without stopping the tunnel
```

## Good to know

- The kill switch blocks outgoing traffic while the tunnel restarts or after it fails, so
  nothing leaks. LAN, DHCP and NTP stay open. Turning the tunnel off lifts it.
- If the uplink has no IPv6, set `proxy.dns.strategy = "ipv4_only"` (sing-box). Otherwise
  direct IPv6 connections hang instead of falling back to IPv4.
- `proxy.tproxy.localSubnets` lists networks that skip TProxy. Add your LAN and VM bridges if
  they are not in `192.168.0.0/16`.
- Per-app `tun`, `tproxy` and `zapret` profiles refuse to start while a global mode is on.

## See also

- [`proxy.tun`](../options/proxy.md#services-proxy-suite-proxy-tun-enable)
- [`proxy.tproxy`](../options/proxy.md#services-proxy-suite-proxy-tproxy-enable)
- [`proxy.autostart`](../options/proxy.md#services-proxy-suite-proxy-autostart)
- [`killSwitch.enable`](../options/killSwitch.md#services-proxy-suite-killswitch-enable)
- [`proxy.ipv6`](../options/proxy.md#services-proxy-suite-proxy-ipv6)
