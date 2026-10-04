# Route a single app

Run one program through the proxy, or through zapret, and leave the rest of the system
alone.

## Config

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  perAppRouting = {
    enable = true;
    createDefaultProfiles = true; # a profile named after each method below
    proxychains.enable = true;
    tun.enable = true;
  };
};
```

## Run an app

```sh
proxy-ctl apps                              # list profiles
proxy-ctl apps run tun -- firefox
proxy-ctl apps run proxychains -- curl https://example.com
```

Run it as yourself, not with sudo.

## Which method

| Method | Covers | Notes |
|---|---|---|
| `proxychains` | TCP | Preloads a library into the app. Needs no privileges, but does not work with statically linked programs or most Go programs. |
| `tun` | TCP and UDP | Puts the app in its own cgroup and routes it into a separate TUN. Works with any program. |
| `tproxy` | TCP and UDP | Like `tun`, but intercepts with nftables. |
| `zapret` | What zapret handles | No proxy: runs a separate zapret for the app, to get past DPI. Needs `zapret.enable`; see [Unblock sites without a server](./zapret.md). |

`tun` works with any program. `proxychains` is handy for a quick command.

## Your own profiles

Name profiles after what they are for, to keep commands short:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  perAppRouting = {
    enable = true;
    tun.enable = true;
    profiles = [ { name = "browser"; route = "tun"; } ];
  };
};
```

Then run `proxy-ctl apps run browser -- chromium`.

## Through one outbound

Send an app through one outbound you pick, past the [routing rules](./routing.md):

```sh
proxy-ctl apps run --via nl -- firefox
proxy-ctl apps run --via nl --route tproxy -- curl https://example.com
```

Or name it in a profile:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "nl"; urlFile = "/run/secrets/nl-url"; } ];
  };
  perAppRouting = {
    enable = true;
    tun.enable = true;
    profiles = [ { name = "game"; route = "tun"; outbound = "nl"; } ];
  };
};
```

- An "interface" AmneziaWG outbound, or a global AmneziaWG profile (`--via home`), takes the
  app straight into its interface, with no proxy in between, and sends the app's DNS to the
  profile's DNS server. See [Use an AmneziaWG config](./amneziawg.md).
- Any other outbound goes through per-app TUN or TProxy (`--route`; TUN when both are
  enabled) and needs the sing-box or hybrid backend. Each outbound in use takes one of
  `perAppRouting.via.pinSlots`.
- When the outbound is down, the app's connections fail; they never leave another way.
- Add profiles without a rebuild: `proxy-ctl apps add game --via nl`, then
  `proxy-ctl apps rm game`. In `proxy-tui` and the desktop app, the Apps tab adds and removes
  them, and runs a command via an outbound.

## Good to know

- `tun`, `tproxy` and `zapret` profiles start a system service, so they ask for an admin
  password unless `userControl` grants the `perApp` scope (see
  [Control it day to day](./control.md)).
- While a global TUN or TProxy is running, these three run the app without their route:
  the global mode already carries its traffic. `proxy-ctl` prints a note when it does. So
  does `--via`, except that an "interface" AmneziaWG outbound still takes the app under a
  global TProxy or AmneziaWG profile.
- If `/etc/resolv.conf` points only at a local resolver (such as systemd-resolved on
  127.0.0.53), the app's DNS queries skip its route. `proxy-ctl` warns about this.
- The app follows your [routing rules](./routing.md) like any other proxied traffic.

## See also

- [Wrap programs with the proxy](./wrap-apps.md): a package that always starts through a profile
- [`perAppRouting.profiles`](../options/perAppRouting.md#services-proxy-suite-perapprouting-profiles)
- [`perAppRouting.createDefaultProfiles`](../options/perAppRouting.md#services-proxy-suite-perapprouting-createdefaultprofiles)
- [`perAppRouting.via`](../options/perAppRouting.md#services-proxy-suite-perapprouting-via-pinslots)
