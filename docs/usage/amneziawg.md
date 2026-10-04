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

Connections made to this machine from elsewhere (SSH, a web server, inbound listeners) are
still answered the way they came in, not through the tunnel. For UDP that takes knowing the
port: the inbound listeners and, on NixOS, the firewall's open ports are known; add others to
`amneziaWg.serverUdpPorts`.

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

## Run single apps through it

With [per-app routing](./per-app.md) on, `--via` sends one app through an outbound:

```sh
proxy-ctl apps run --via de -- steam
```

An `"interface"` outbound takes the app's packets into its interface directly: no proxy in
between, and UDP as it is. The app's DNS goes to the profile's `DNS` servers (or to
`proxy.dns.remote` when it names none), through the tunnel, even when `/etc/resolv.conf`
points at a local resolver. While the interface is down, the app's connections fail instead of
leaving another way. A `"userspace"` or `"singBox"` outbound works like any other outbound
here: through per-app TUN or TProxy.

A global profile works too, declared or added with `awg add`: `--via home` brings up a copy
of it for the apps alone, the same way, and takes it down after the last one exits. The
rest of the system is untouched. A profile cannot be up globally and for apps at once: while
`awg on home` holds it, `--via home` runs the app as it is, and `awg on home` stops the copy.
When a name is both a global profile and an outbound, say which: `--via awg:home` or
`--via outbound:home`.

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
  perAppRouting = {
    enable = true;
    profiles = [ { name = "games"; outbound = "de"; } ];
  };
};
```

## Add one without rebuilding

`amneziaWg.enable` alone is enough: profiles and outbounds can come from `proxy-ctl` instead
of the config.

```nix
services.proxy-suite = {
  enable = true;
  amneziaWg.enable = true; # no profiles needed
  userControl = {
    enable = true;
    scopes = [ "services" "amneziaWg" "outbounds" ]; # optional: no sudo for these
  };
};
```

```sh
proxy-ctl awg add vpn://AAAA…               # named after the export, or the server's host
proxy-ctl awg add home ~/home.conf          # a name first; a link, a file, or - for stdin
proxy-ctl awg on home
proxy-ctl awg rm home
proxy-ctl proxy outbounds add de ~/de.conf  # an outbound instead (needs proxy.enable)
proxy-ctl proxy outbounds add nl ~/nl.conf --interface  # on an interface of its own
```

- A global profile works like a declared one: `awg on`, the tray menu, the kill switch. The
  ones added this way share one interface, `amneziaWg.runtime.interfaceName`.
- An outbound runs in wireproxy (like `asOutbound = "userspace"`), so the obfuscation stays.
  With `--interface` it gets an AmneziaWG interface of its own instead (like
  `asOutbound = "interface"`; root hosts only), which apps can run through directly (see
  above).
  `amneziaWg.runtime.outboundKind` sets which one an outbound gets when the command does not
  say. Either way, it cannot chain through another outbound.
- In `proxy-tui` and the desktop app, paste a `vpn://` link or a whole `.conf` onto a tab: on
  the Outbounds tab it becomes an outbound, anywhere else a global profile. The Outbounds tab
  also adds one on an interface of its own, and the AmneziaWG tab adds a global profile from a
  prompt and removes what was added.
- Hooks (`PostUp` and the like) are always refused, whoever adds the config.
  `--container <name>` picks one from a `vpn://` export that holds several.
- Adding and removing takes root, or a `userControl` scope: `amneziaWg` for global profiles,
  `outbounds` for outbounds. Turning a profile on and off is `services`.
- They are kept across reboots. `amneziaWg.runtime.enable = false` turns all of this off.

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
- [`amneziaWg.runtime`](../options/amneziaWg.md#services-proxy-suite-amneziawg-runtime-enable)
- [`asOutbound`](../options/amneziaWg.md#services-proxy-suite-amneziawg-profiles-name-asoutbound)
- [Route a single app](./per-app.md)
- [`settings`](../options/amneziaWg.md#services-proxy-suite-amneziawg-profiles-name-settings)
