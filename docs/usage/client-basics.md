# Connect through a proxy

Run a local proxy on `127.0.0.1:1080` that forwards traffic through your server or
subscription.

## Config

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    subscriptions = [ { tag = "provider"; urlFile = "/run/secrets/provider-sub-url"; } ];
    selection = "urltest";
  };
};
```

- `outbounds` takes proxy links (`vless://`, `hy2://`, `trojan://`, `ss://`, …), one per
  entry. Put each link in a file; see [Keep secrets out of the Nix store](./secrets.md).
- `subscriptions` fetches a list of links from a URL and refreshes it daily. Its entries are
  tagged with the subscription's tag as a prefix.
- `selection` picks which outbound to use: `"first"` (the default), `"urltest"` (the
  fastest) or `"selector"` (you pick).

You only need one outbound or subscription. With neither, the proxy waits until you add one
with `proxy-ctl proxy outbounds add`.

## Use it

Point apps at `127.0.0.1:1080`. The port speaks both SOCKS5 and HTTP. Many apps follow the
usual variables:

```sh
export all_proxy=socks5h://127.0.0.1:1080
export https_proxy=http://127.0.0.1:1080
```

To route apps without setting them up, see [Route the whole machine](./system-wide.md) or
[Route a single app](./per-app.md).

## Commands

```sh
proxy-ctl status                          # what is running
proxy-ctl proxy outbounds                 # outbounds, and which one is in use
proxy-ctl proxy outbounds test            # ping and delay of each one
proxy-ctl proxy pin my-vps                # always use this one
proxy-ctl proxy unpin                     # back to automatic selection
proxy-ctl proxy outbounds add 'vless://…' # add one at runtime, no rebuild
proxy-ctl proxy subs update               # refetch subscriptions now
```

## Good to know

- `proxy.backend` picks the engine: sing-box (the default), XRay, or `"hybrid"`, which runs
  sing-box and hands XHTTP and ECH links to XRay.
- `urltest` tests each outbound by fetching `proxy.urlTest.url`. Set it to a site that is
  blocked where you are, so an outbound only passes if it really gets around the block.
- Set `proxy.listener.auth` before exposing the port with `listener.address = "0.0.0.0"`.

## See also

- [`proxy.outbounds`](../options/proxy.md#services-proxy-suite-proxy-outbounds)
- [`proxy.subscriptions`](../options/proxy.md#services-proxy-suite-proxy-subscriptions)
- [`proxy.selection`](../options/proxy.md#services-proxy-suite-proxy-selection)
- [`proxy.backend`](../options/proxy.md#services-proxy-suite-proxy-backend)
