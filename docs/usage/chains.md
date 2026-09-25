# Chain proxies and add exits

Two things are covered here: reaching a server through another one (a chain), and adding
built-in exits (WARP, Tor, an SSH tunnel) for your routing to use.

## Chains

Set `detour` to make an outbound connect through another one. This helps when your
network cannot reach a server directly but can reach a hop that can. It also hides the
final server's address from your ISP.

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [
      { tag = "hop"; urlFile = "/run/secrets/hop-url"; }
      { tag = "de-vps"; urlFile = "/run/secrets/de-vps-url"; detour = "hop"; }
    ];
    selectionExclude = [ "hop" ]; # never picked as the exit on its own
  };
};
```

Any outbound can be a hop, including subscription entries, WARP, the SSH tunnel and
AmneziaWG outbounds. A subscription's `detour` applies to every entry in it. On the hybrid
backend, an XRay outbound can only chain through another XRay outbound.

At runtime:

```sh
proxy-ctl proxy outbounds chain de-vps hop de-via-hop   # a chained copy of de-vps
proxy-ctl proxy outbounds add 'vless://…' --detour hop  # a new outbound behind hop
```

## Extra exits

Each of these adds an outbound with a fixed tag. Route sites to it with
[routing rules](./routing.md), or use it as a hop.

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    routing.rules = [
      { domains = [ "chatgpt.com" "openai.com" ]; outbound = "warp"; }
      { domains = [ "check.torproject.org" ]; outbound = "tor"; }
    ];
  };

  # Tagged "warp". Registers a free WARP device on first start.
  warp = {
    enable = true;
    asOutbound = "singBox";
  };

  # Tagged "tor". .onion names always go to it.
  tor = {
    enable = true;
    asOutbound = true;
  };

  # Tagged "ssh-proxy".
  sshProxy = {
    enable = true;
    asOutbound = true;
    server = { user = "me"; host = "ssh.example.com"; };
    identityFile = "/run/secrets/ssh-key";
    hostKeyFile = "/run/secrets/ssh-known-hosts"; # from ssh-keyscan
  };
};
```

| Exit | Good to know |
|---|---|
| WARP | Registering accepts Cloudflare's terms. If the Cloudflare API is blocked, set `warp.generatorUrl`, or `warp.configFile` with a profile made elsewhere. If the endpoint is blocked, try `warp.endpoint`. |
| Tor | Selection and autoProxy skip it unless it is the only outbound. Where Tor is blocked, add `tor.bridges.lines`, or reach Tor through the proxy with `tor.upstream = "proxy"`. |
| SSH | Needs the server's host keys on sing-box (`hostKeyFile` or `hostKey`). Any SSH server that allows TCP forwarding works, with nothing to install on it. |

## Good to know

- `proxy.selectionExclude` keeps hops and special exits out of automatic selection. You can
  still pin them.
- autoProxy tries your exits, WARP included, for each blocked site and keeps the first one
  that works.
- WARP can also run as a global VPN instead, through AmneziaWG: `warp.asAmneziaWg`.

## See also

- [`detour`](../options/proxy.md#services-proxy-suite-proxy-outbounds-detour)
- [`proxy.selectionExclude`](../options/proxy.md#services-proxy-suite-proxy-selectionexclude)
- [WARP](../options/warp.md), [Tor](../options/tor.md), [SSH](../options/sshProxy.md)
