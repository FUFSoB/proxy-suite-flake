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
| `zapret` | What zapret handles | No proxy: runs a separate zapret for the app, to get past DPI. |

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

## Good to know

- `tun`, `tproxy` and `zapret` profiles start a system service, so they ask for an admin
  password unless `userControl` grants the `perApp` scope (see
  [Control it day to day](./control.md)).
- These three refuse to start while a global TUN or TProxy is running.
- If `/etc/resolv.conf` points only at a local resolver (such as systemd-resolved on
  127.0.0.53), the app's DNS queries skip its route. `proxy-ctl` warns about this.
- The app follows your [routing rules](./routing.md) like any other proxied traffic.

## See also

- [`perAppRouting.profiles`](../options/perAppRouting.md#services-proxy-suite-perapprouting-profiles)
- [`perAppRouting.createDefaultProfiles`](../options/perAppRouting.md#services-proxy-suite-perapprouting-createdefaultprofiles)
