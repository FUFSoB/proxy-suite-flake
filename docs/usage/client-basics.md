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

A Shadowsocks server behind ShadowTLS (a proxy-suite "shadowtls" listener, or any ShadowTLS
v3 server) has no link of its own: give the Shadowsocks link and the ShadowTLS part beside it.

```nix
services.proxy-suite.proxy.outbounds = [
  {
    tag = "shadowtls";
    urlFile = "/run/secrets/ss-url"; # ss://2022-blake3-aes-128-gcm:<server key>:<user key>@vpn.example.com:8445
    shadowTls = {
      serverName = "www.microsoft.com";
      passwordFile = "/run/secrets/shadowtls-password";
    };
  }
];
```

## Subscriptions from a panel

Panels (Marzban, 3x-ui, Remnawave and the like) say more than the links: traffic used and
left, when the subscription expires, a title, sometimes an announcement. `proxy-ctl proxy
subs` shows traffic and expiry, `proxy-ctl proxy subs show <tag>` the rest.

A subscription is refetched as often as its panel asks (its `profile-update-interval`, not more
often than hourly), else every `subscriptionUpdateInterval`; `updateInterval` sets its own.

Some panels serve only the clients they know, or limit devices by HWID:

```nix
services.proxy-suite.proxy.subscriptions = [
  {
    tag = "provider";
    urlFile = "/run/secrets/provider-sub-url";
    # Tried in order until one gets entries: a panel may serve some clients a stub.
    userAgent = [ "v2rayN/6.0" "Happ/1.0" ];
    # The HWID and system, as Happ sends them.
    sendDeviceInfo = true;
  }
];
```

Some panels serve JSON to the clients that ask for it (Happ's User-Agent, for one): whole XRay
configs, with what links cannot say, such as XHTTP's `extra` and a fragment. proxy-suite takes
the proxy out of each, leaving the panel's routing and DNS out; XRay's configs need the XRay
or hybrid backend. A sing-box config or a list of sing-box outbounds works the same way.

The HWID is derived from `/etc/machine-id` and stays the same across rebuilds and reinstalls
of the state; `proxy.subscriptionHwidFile` gives one of your own, such as the old machine's
from `proxy-ctl proxy subs show`, to keep its device slot. At runtime:

```sh
proxy-ctl proxy subs add provider - --ua Happ/1.0 --device-info < sub-url.txt
```

## Use it

Point apps at `127.0.0.1:1080`. The port speaks both SOCKS5 and HTTP. Many apps follow the
usual variables:

```sh
export all_proxy=socks5h://127.0.0.1:1080
export https_proxy=http://127.0.0.1:1080
```

To route apps without setting them up, see [Route the whole machine](./system-wide.md),
[Route a single app](./per-app.md) or [Wrap programs with the proxy](./wrap-apps.md).

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
- An outbound or a subscription can ask for what a link cannot say: `fragment = { };`
  splits the TLS ClientHello against DPI that reads the server name from it (XRay with
  its own numbers, through a freedom hop; sing-box its own way, and not for REALITY), and
  `multiplex = { };` carries connections over a few long-lived ones. Multiplexing needs a
  server of the same kind: sing-box's and XRay's are different protocols. At runtime:
  `proxy-ctl proxy outbounds add de 'vless://…' --fragment --mux smux`.
- `outbounds add` also takes one outbound as sing-box or XRay JSON. Such an outbound cannot
  name a local file or program (a `tor` outbound, `*_path`, `*File`, `masterKeyLog`): the
  backend would open or run it with its own privileges. Declare those in `proxy.outbounds`.

## See also

- [`proxy.outbounds`](../options/proxy.md#services-proxy-suite-proxy-outbounds)
- [`proxy.subscriptions`](../options/proxy.md#services-proxy-suite-proxy-subscriptions)
- [`proxy.selection`](../options/proxy.md#services-proxy-suite-proxy-selection)
- [`proxy.backend`](../options/proxy.md#services-proxy-suite-proxy-backend)
