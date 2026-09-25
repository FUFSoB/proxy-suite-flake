# Unblock sites without a server

zapret gets around DPI blocking by changing how the first packets of a connection look. It
needs no proxy server: the traffic still goes straight to the site. It only helps with
blocks that DPI enforces, and not with sites whose IPs are blocked outright.

## Ready-made presets: zapret-discord-youtube

The default engine. It covers YouTube and Discord out of the box.

```nix
services.proxy-suite = {
  enable = true;
  zapret = {
    enable = true;
    zapret-discord-youtube = {
      configName = "general(ALT)";      # the default; try others if it does not work
      domains = [ "rutracker.org" ];    # more sites to unblock
    };
  };
};
```

Which preset works depends on your ISP. If sites still do not load, try other presets from
the [zapret-discord-youtube](https://github.com/kartavkun/zapret-discord-youtube) list, such
as `"general (ALT9)"`.

## Blocked sites found automatically: zapret2

zapret2 notices failing connections, marks the site as blocked, and finds a strategy that
works for it. Each site's strategy is remembered.

```nix
services.proxy-suite = {
  enable = true;
  zapret = {
    enable = true;
    engine = "zapret2";
    zapret2.domains = [ "rutracker.org" ]; # always treated as blocked
  };
};
```

`zapret2.strategySource = "z2k"` switches to z2k's strategies and site lists, which include
the full RKN list and use more memory. It also turns on a workaround for ISPs that cut
TLS to some hosting networks after about 16 KB.

## Commands

```sh
proxy-ctl zapret                          # status
proxy-ctl zapret off                      # or: on, toggle, restart
proxy-ctl zapret auto                     # sites zapret2 learned
proxy-ctl zapret auto add example.com     # treat a site as blocked
proxy-ctl zapret auto exclude example.com # never touch or learn a site
proxy-ctl zapret auto forget example.com  # forget it and its strategy
proxy-ctl zapret cutoff                   # networks cut off at 16 KB (z2k)
```

## With a proxy

zapret and the proxy work side by side. By default (`zapret.directSync`), the sites zapret
handles are sent direct, so they skip the proxy and reach zapret. Everything else follows
your [routing rules](./routing.md).

To use zapret for a single app only, see [Route a single app](./per-app.md).

## Good to know

- zapret needs root, so it is not available with home-manager or Nix-on-Droid.
- If it breaks VMs or containers behind NAT, list their subnets in `zapret.cidrExemption`.
- For games, set `zapret-discord-youtube.gameFilter`.

## See also

- [`zapret.engine`](../options/zapret.md#services-proxy-suite-zapret-engine)
- [`zapret-discord-youtube.configName`](../options/zapret.md#services-proxy-suite-zapret-zapret-discord-youtube-configname)
- [`zapret2.strategySource`](../options/zapret.md#services-proxy-suite-zapret-zapret2-strategysource)
- [`zapret.directSync`](../options/zapret.md#services-proxy-suite-zapret-directsync-enable)
