# Get past mobile whitelists

Some mobile networks let through only a whitelist of services, such as video calls, and
block everything else. [whitelist-bypass](https://github.com/kulikov0/whitelist-bypass)
tunnels your traffic through a video call on a whitelisted platform.

It takes two machines:

- a **creator** on a host with normal internet access, such as a VPS or a home machine. It
  logs in to the call platform, starts a call and relays traffic to the internet;
- a **joiner** on the censored side, such as a laptop on mobile internet. It joins that call
  and becomes an outbound for the proxy.

Supported platforms: `"wbstream"`, `"telemost"`, `"dion"` and `"bitrix"`. Each needs an
account for the creator.

## The creator

One creator per joiner device.

```nix
services.proxy-suite = {
  enable = true;
  whitelistBypass = {
    enable = true;
    creators.laptop = {
      platform = "wbstream";
      cookiesFile = "/run/secrets/wbstream-cookies.json";
    };
  };
};
```

The cookies come from the upstream desktop Creator app. They are read on first start, and
the login refreshes itself after that. `proxy-ctl wl auth laptop` replaces them at runtime,
and asks for an email and password instead on DION and Bitrix.

The creator starts a call and keeps reusing it. Get its link with:

```sh
proxy-ctl wl link laptop
```

## The joiner

The joiner is an outbound tagged with its name (`wl` here), so it needs the local proxy.

```nix
services.proxy-suite = {
  enable = true;
  proxy.enable = true;
  whitelistBypass = {
    enable = true;
    joiners.wl.platform = "wbstream";
  };
};
```

Give it the creator's link, then send traffic through it:

```sh
proxy-ctl wl join wl 'https://…'   # the link from `proxy-ctl wl link`
proxy-ctl proxy pin wl
```

The link can also come from a file, with `joiners.<name>.linkFile`.

## Commands

```sh
proxy-ctl wl                  # creators and joiners, and their state
proxy-ctl wl new laptop       # start a new call, if the platform closed the old one
proxy-ctl wl restart          # restart all of them; or name one
```

## Good to know

- By default, the creator's traffic exits straight from its host. With
  `creators.<name>.upstream = "proxy"`, it goes through that host's own proxy and routing.
- Use it when nothing else gets through, and `proxy-ctl proxy unpin` once other outbounds
  work again.
- Pair it with [Route the whole machine](./system-wide.md) on the joiner to cover every app.

## See also

- [`whitelistBypass.creators`](../options/whitelistBypass.md#services-proxy-suite-whitelistbypass-creators)
- [`whitelistBypass.joiners`](../options/whitelistBypass.md#services-proxy-suite-whitelistbypass-joiners)
