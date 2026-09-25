# Use an AmneziaWG config

Bring the AmneziaWG config from your provider or your own server, either as a `.conf` file or
as an Amnezia app `vpn://` export. AmneziaWG 1.x to 3.x are supported. Each profile can run
in one of two ways:

- **as a global VPN**: all traffic goes through it, like `wg-quick up`;
- **as an outbound**: the proxy sends only what your routing picks through it.

## As a global VPN

```nix
services.proxy-suite = {
  enable = true;
  amneziaWg = {
    enable = true;
    profiles.home.configFile = "/run/secrets/home-awg.conf";
    profiles.work = {
      vpnFile = "/run/secrets/work-amnezia.vpn";
      autostart = true; # at most one profile
    };
  };
  killSwitch.enable = true; # optional: no leaks while the tunnel is down
};
```

```sh
proxy-ctl awg                # profiles and which one is up
proxy-ctl awg on home        # switches from any other global tunnel
proxy-ctl awg off
```

Only one global tunnel runs at a time: an AmneziaWG profile, TUN or TProxy. Starting one
stops the others.

## As an outbound

```nix
services.proxy-suite = {
  enable = true;
  proxy.enable = true;
  amneziaWg = {
    enable = true;
    profiles.de = {
      configFile = "/run/secrets/de-awg.conf";
      asOutbound = "interface";
    };
  };
};
```

The outbound is tagged with the profile's name (`de` here). It always runs, and leaves the
host's routes and DNS alone. Use it like any other outbound: for selection, in
[routing rules](./routing.md), or as a hop in a [chain](./chains.md).

| `asOutbound` | Obfuscation | Needs root | Notes |
|---|---|---|---|
| `"interface"` | yes | yes | A real AmneziaWG interface with no routes. |
| `"userspace"` | yes | no | Runs in wireproxy. The only mode on home-manager and Nix-on-Droid. |
| `"singBox"` | no | no | Plain WireGuard inside sing-box. For servers without obfuscation, such as WARP. |

## Good to know

- A profile that stops getting handshake replies moves to a new source port on its own.
  `settings.listenPort` pins the port and turns this off.
- If the server's address is blocked, `profiles.<name>.endpoint` replaces it without
  editing the file.
- Imported configs cannot run `PostUp` and other hooks unless you set `allowConfigHooks`.
- The profile can also be written in Nix instead of a file, with `profiles.<name>.settings`.
- To host an AmneziaWG server, see [Run your own server](./server.md).

## See also

- [`amneziaWg.profiles`](../options/amneziaWg.md#services-proxy-suite-amneziawg-profiles)
- [`asOutbound`](../options/amneziaWg.md#services-proxy-suite-amneziawg-profiles-name-asoutbound)
- [`settings`](../options/amneziaWg.md#services-proxy-suite-amneziawg-profiles-name-settings)
