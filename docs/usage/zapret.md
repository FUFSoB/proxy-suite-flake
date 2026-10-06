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
works for it. Each site's strategy is remembered. It also learns sites blocked only some of
the time, downloads that stall partway, and requests that never get an answer.

What zapret2 cannot fix goes through your proxy, when you have one: a site none of its
strategies get through for (only its QUIC, when that alone fails), and an address that
never answers at all, as Telegram's are blocked. That works for traffic the proxy sees
(TUN, TProxy, per-app routing). `proxy-ctl zapret auto` names such an address by the sites
looked up to it, when systemd-resolved still had them cached as it was blocked.

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

`zapret2.strategySource = "z2k"` switches to z2k's strategies and site lists, which includes
the full RKN list and uses more memory. It also turns on a workaround for ISPs that cut
TLS to some hosting networks after about 16 KB.

Each failure zapret2 counts and each strategy switch is logged, per site:
`proxy-ctl logs proxy-suite-zapret`. A site stays on its first strategy as long as that one
works.

Other ports, such as a game's, take the same strategies with `zapret2.ports.extraUdp` or
`extraTcp`:

```nix
services.proxy-suite.zapret.zapret2.ports.extraUdp = [ "27015-27030" ];
```

## Commands

```sh
proxy-ctl zapret                          # status
proxy-ctl zapret off                      # or: on, toggle, restart
proxy-ctl zapret auto                     # sites zapret2 learned, and what goes to the proxy
proxy-ctl zapret auto add example.com     # treat a site as blocked
proxy-ctl zapret auto retry example.com   # give zapret2 another try at what it sent the proxy
proxy-ctl zapret auto exclude example.com # never touch or learn a site
proxy-ctl zapret auto forget example.com  # forget it and its strategy
proxy-ctl zapret cutoff                   # networks cut off at 16 KB (z2k)
```

## With a proxy

zapret and the proxy work side by side. By default (`zapret.directSync`), the sites zapret
handles are sent direct, so they skip the proxy and reach zapret. With zapret2 that includes
the ones you pin with `proxy-ctl zapret auto add`, and the sites it learns once one of its
strategies is seen getting through; your own rules and autoProxy still come first.
Everything else follows your [routing rules](./routing.md).

## Only for some apps

To leave the rest of the system alone, turn the system-wide zapret off and run apps through
it one by one:

```nix
services.proxy-suite = {
  enable = true;
  zapret = {
    enable = true;
    global.enable = false; # no system-wide zapret
  };
  perAppRouting = {
    enable = true;
    createDefaultProfiles = true; # adds a profile named "zapret"
    zapret.enable = true;
  };
};
```

Then run `proxy-ctl apps run zapret -- firefox`. The app gets zapret's strategy for every
site, not only the listed ones. `directSync`, `cidrExemption` and the sites zapret2 learns
belong to the system-wide zapret, so they do nothing here. See
[Route a single app](./per-app.md) for more.

## Good to know

- zapret needs root, so it is not available with home-manager or Nix-on-Droid.
- If it breaks VMs or containers behind NAT, list their subnets in `zapret.cidrExemption`.
- For games, set `zapret-discord-youtube.gameFilter`.

## See also

- [`zapret.engine`](../options/zapret.md#services-proxy-suite-zapret-engine)
- [`zapret.global.enable`](../options/zapret.md#services-proxy-suite-zapret-global-enable)
- [`zapret-discord-youtube.configName`](../options/zapret.md#services-proxy-suite-zapret-zapret-discord-youtube-configname)
- [`zapret2.strategySource`](../options/zapret.md#services-proxy-suite-zapret-zapret2-strategysource)
- [`zapret2.ports.extraUdp`](../options/zapret.md#services-proxy-suite-zapret-zapret2-ports-extraudp)
- [`zapret.directSync`](../options/zapret.md#services-proxy-suite-zapret-directsync-enable)
