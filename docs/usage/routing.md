# Choose what goes through the proxy

Decide per site whether traffic goes through the proxy, goes direct, or is blocked. This
applies to the local proxy, TUN, TProxy and per-app routing alike.

## How a destination is routed

The first match wins, checked in this order. Each step has a priority number, and the
rules you add at runtime (below) go in among them:

| Priority | What is checked |
|---|---|
| 100 | `proxy.routing.rules`, in order, after each outbound's own `routing`. A rule can name a specific outbound. |
| 200 | `proxy.domains` and `proxy.ips` |
| 300 | `block` |
| 400 | `direct`, then private addresses |
| 500 | `proxy.geosites`, `proxy.geoips` and `proxy.ruleSets` |
| after | what autoProxy and zapret2 learned |
| last | `proxy.routing.default`: `"proxy"` (the default) or `"direct"` |

A name in both a block and a direct list (an ad domain under `category-ru`, say) is blocked.
Apps run with `apps run --via` skip all of this.

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

## Add rules at runtime

`proxy-ctl proxy rules` adds rules without a rebuild. They are kept across reboots:

```sh
proxy-ctl proxy rules add direct bank.example 10.0.0.0/8   # these go direct
proxy-ctl proxy rules add proxy geosite:netflix            # this through the proxy
proxy-ctl proxy rules add us-vps hulu.com --name streaming # through one outbound or group
proxy-ctl proxy rules add block ads.example --priority 350 # after the config's block list
proxy-ctl proxy rules                                      # every rule, in the order checked
```

A rule matches domains (subdomains included), addresses and CIDRs, `geosite:NAME`,
`geoip:NAME` and `ruleset:NAME` (a rule set from `routing.ruleSets`). It sends them to
`proxy`, `direct`, `block`, or any outbound or group, ones added at runtime included.

Without `--name`, the rule is named after its target, so `rules add direct …` keeps adding to
the same rule. A new rule gets priority 50, ahead of everything in the config. Give it
another number with `--priority`, or move it later:

```sh
proxy-ctl proxy rules priority streaming 450    # after the direct lists
proxy-ctl proxy rules priority streaming up     # one row up, past a rule or a config step
proxy-ctl proxy rules matches direct rm 10.0.0.0/8
proxy-ctl proxy rules target streaming de-vps
proxy-ctl proxy rules disable streaming         # keep it, but stop applying it
proxy-ctl proxy rules rm streaming
```

On equal priority, a runtime rule goes first. Route modes treat runtime rules like the
config's: `all-proxy` drops the ones that go direct, and `all-bypass` keeps only blocks.

A change applies at once. On sing-box and hybrid, adding or removing a rule's domains and
addresses does not restart anything. Other changes, and every change on XRay, restart the
proxy, which drops open connections. A rule whose outbound is gone is left out until the
outbound is back, and `proxy rules` says why.

The Routing tab in the TUI and the app lists the same rules, the config's included. It adds
(`n`), edits (`a`, `x`, `t`), moves (`+`, `-`, `y`), disables (`e`) and removes (`d`) them. The
route mode is a selector above the table (`m`). Pasting a bare domain onto the tab sends it
through the proxy.

## Commands

```sh
proxy-ctl where youtube.com        # how a site is routed right now, and why
proxy-ctl proxy mode whitelist     # direct unless a rule says otherwise
proxy-ctl proxy mode blacklist     # proxy unless a rule says otherwise
proxy-ctl proxy mode all-proxy     # everything through the proxy, except blocks
proxy-ctl proxy mode all-bypass    # everything direct, except blocks
proxy-ctl proxy mode default       # back to routing.default
proxy-ctl proxy rules              # every routing rule, in the order checked
proxy-ctl proxy auto               # what autoProxy routed, and where
proxy-ctl proxy rulesets update    # refetch rule sets now
```

A route mode set with `proxy-ctl` lasts until the next reboot. Rules added with
`proxy rules` last until removed.

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
