# Choose what goes through the proxy

Decide per site whether traffic goes through the proxy, goes direct, or is blocked. This
applies to the local proxy, TUN, TProxy and per-app routing alike.

## How a destination is routed

1. `proxy.routing.rules`, in order. The first match wins, and a rule can name a specific
   outbound.
2. The `proxy`, `direct` and `block` lists.
3. Anything left goes to `proxy.routing.default`: `"proxy"` (the default) or `"direct"`.

Russian sites and IPs go direct unless you set `routing.directRu = false`.

Each list and rule matches by `domains` (subdomains included), `ips` (CIDR), `geosites`,
`geoips` and `ruleSets`.

## Only blocked sites through the proxy

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    routing = {
      default = "direct";
      proxy.domains = [ "youtube.com" "googlevideo.com" ];
      proxy.geosites = [ "instagram" ];
    };
    # Find blocked sites on its own, and route each one through an exit that reaches it.
    autoProxy.enable = true;
  };
};
```

`autoProxy` saves you from listing every blocked site. It probes new destinations in the
background and routes only those that fail directly. It needs the sing-box backend.

## Everything through the proxy, with exceptions

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [
      { tag = "nl-vps"; urlFile = "/run/secrets/nl-vps-url"; }
      { tag = "us-vps"; urlFile = "/run/secrets/us-vps-url"; }
    ];
    routing = {
      rules = [ { geosites = [ "netflix" ]; outbound = "us-vps"; } ];
      direct.domains = [ "bank.example" ];
      block.geosites = [ "category-ads-all" ];
    };
  };
};
```

## Rule sets

Rule sets are lists that sing-box downloads and refreshes on its own, so they stay current
without a rebuild. Name them in `routing.ruleSets` and use them in any `ruleSets` list:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    routing = {
      default = "direct";
      ruleSets.blocked.url = "https://example.com/blocked.srs";
      proxy.ruleSets = [ "blocked" ];
    };
  };
};
```

They need the sing-box or hybrid backend.

## Commands

```sh
proxy-ctl where youtube.com        # how a site is routed right now, and why
proxy-ctl proxy mode whitelist     # direct unless a rule says otherwise
proxy-ctl proxy mode blacklist     # proxy unless a rule says otherwise
proxy-ctl proxy mode all-proxy     # everything through the proxy, except blocks
proxy-ctl proxy mode all-bypass    # everything direct, except blocks
proxy-ctl proxy mode default       # back to routing.default
proxy-ctl proxy auto               # what autoProxy routed, and where
proxy-ctl proxy rulesets update    # refetch rule sets now
```

A route mode set with `proxy-ctl` lasts until the next reboot.

## Good to know

- Geosite and geoip names come from the [geodata](../options/geodata.md) databases.
- With `zapret`, sites that zapret handles are sent direct, so zapret can unblock them. See
  [Unblock sites without a server](./zapret.md).
- To send some sites to WARP, Tor or another exit, see [Chain proxies and add exits](./chains.md).

## See also

- [`proxy.routing.rules`](../options/proxy.md#services-proxy-suite-proxy-routing-rules)
- [`proxy.routing.default`](../options/proxy.md#services-proxy-suite-proxy-routing-default)
- [`proxy.routing.ruleSets`](../options/proxy.md#services-proxy-suite-proxy-routing-rulesets)
- [`proxy.autoProxy`](../options/proxy.md#services-proxy-suite-proxy-autoproxy-enable)
