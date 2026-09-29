# Group outbounds and fail over

A group is one tag standing for several outbounds. Whatever names the group (a routing rule,
a chain, a pin, the top-level pick) uses whichever member the group picks. The usual reason
is failover: when one exit stops carrying traffic, move to the next within seconds instead of
waiting for someone to notice.

## A failover group

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [
      { tag = "de-vps"; urlFile = "/run/secrets/de-vps-url"; }
      { tag = "nl-vps"; urlFile = "/run/secrets/nl-vps-url"; }
    ];
    groups.eu.outbounds = [ "de-vps" "nl-vps" ]; # de-vps first, nl-vps when it fails
  };
};
```

The members leave the top level: the top level now picks between `eu` and whatever is in no
group. Members can be any outbound, including subscription entries, WARP, Tor and AmneziaWG,
and other groups.

Each group has a `strategy`:

| Strategy | Picks |
|---|---|
| `failover` (default) | The first member that works, in order. With `failback` (on by default) it goes back to an earlier member once that has worked three checks in a row. |
| `urltest` | The fastest member, switching only when another is faster by `proxy.urlTest.tolerance`. |
| `selector` | The first member, or the one you pick. |

Failover is driven by `proxy-suite-outbound-groups`, which tests the members every `interval`
(30 s by default) and switches through sing-box's Clash API. A member is down after two
failed tests in a row. Watchdogs that already watch a tunnel (the AmneziaWG watchdog, the
sing-box WARP tunnel) tell it at the first sign of trouble, so their outbounds are dropped
within seconds. Connections still open on the dropped member are cut, so clients reconnect
through the next one.

Groups need the sing-box or hybrid backend. The TUN instances of sing-box have no Clash API,
so there a failover group works as `urltest`.

## Members from subscriptions and patterns

```nix
services.proxy-suite.proxy = {
  enable = true;
  subscriptions = [ { tag = "provider"; urlFile = "/run/secrets/provider-sub"; } ];
  groups.fast = {
    subscriptions = [ "provider" ]; # every entry the subscription holds
    match = [ "de-*" ];             # and every outbound whose tag matches
    strategy = "urltest";
  };
};
```

Listed `outbounds` come first, in their order; members pulled in by `subscriptions` or `match`
follow, ordered by `proxy.priority`.

## Failover at the top level, and priority

`proxy.selection = "failover"` treats the top level like a failover group. Its order comes
from `proxy.priority`, lower first; anything not listed follows in its usual order:

```nix
services.proxy-suite.proxy = {
  enable = true;
  selection = "failover";
  priority = { eu = 10; warp = 20; };
};
```

## Several WARP devices

One WARP device is one key and one session. With several, `warp` becomes a failover group of
them, so rules and pins that name `warp` keep working and fail over:

```nix
services.proxy-suite = {
  enable = true;
  amneziaWg.enable = true;
  proxy.enable = true;
  warp = {
    enable = true;
    asOutbound = "interface";
    instances = 2; # warp-1 (keeps an existing registration) and warp-2
  };
};
```

Name them yourself, each with its own endpoint, through `warp.devices`:

```nix
services.proxy-suite.warp = {
  enable = true;
  asOutbound = "interface";
  devices = {
    warp-a = { };
    warp-b.endpoint = "162.159.193.10:500";
  };
  group.strategy = "failover";
};
```

Devices whose outages come at the same time (the path to Cloudflare, say) do not help each
other; a different endpoint for each, or a member that is not WARP, does.

## At runtime

```sh
proxy-ctl proxy outbounds                          # the tree: groups, members, what each uses
proxy-ctl proxy groups add eu de-vps nl-vps        # a failover group
proxy-ctl proxy groups add fast --sub provider --strategy urltest
proxy-ctl proxy groups members eu add pl-vps
proxy-ctl proxy pin nl-vps --in eu                 # hold eu on nl-vps
proxy-ctl proxy unpin --in eu
proxy-ctl proxy priority eu 5                      # or: eu up, eu down, eu --clear
proxy-ctl warp restart warp-2
```

Groups added at runtime can be changed and removed there; declared ones change in Nix. In
the TUI and the GUI, the Outbounds tab shows the same tree: `space` folds a group, `p` on a
member pins it inside its group, `g` adds a group, and `+` and `-` move a top-level entry.

## See also

- [`proxy.groups`](../options/proxy.md#services-proxy-suite-proxy-groups)
- [`proxy.priority`](../options/proxy.md#services-proxy-suite-proxy-priority)
- [`warp.devices`](../options/warp.md#services-proxy-suite-warp-devices)
- [Chain proxies and add exits](./chains.md)
