# Read HTTPS requests with mitmproxy

See the requests inside TLS: which one fails, with what status, and what the server sent
back. [mitmproxy](https://mitmproxy.org) decrypts what you send to it. A program has to trust
its CA for that to work.

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  mitm = {
    enable = true;
    web.enable = true; # mitmweb; without it, a line per request in the log
  };
};
```

```sh
proxy-ctl mitm web                              # mitmweb's address, with its password
proxy-ctl mitm run -- curl -v https://example.com
proxy-ctl mitm run -- firefox                   # or chromium, brave, librewolf…
```

`mitm run` hands the program the CA. A browser starts in a profile of its own that already
trusts it; your usual profile is not touched.

## What goes through it

With the proxy on, mitmproxy is an outbound tagged "mitm". Nothing reaches it on its own:
it is never the outbound in use, and port 1080 stays the normal proxy.

| To read | Do |
|---|---|
| Some sites, from every program | `mitm.hosts = [ "example.com" ]`, or `proxy-ctl mitm hosts add example.com` |
| What no routing rule decides | `proxy-ctl mitm all on` |
| One program | `proxy-ctl mitm run -- <cmd>`, or `proxy-ctl apps run --via mitm -- <cmd>` |
| Whatever is pointed at a port | `mitm.listener`: `127.0.0.1:1088` is read, `1080` is not |
| A container, a virtual machine, LAN devices | `mitm.interfaces` |

Any routing rule may name it too: `proxy.routing.rules = [ { outbound = "mitm"; … } ]`.

Sites sent to it by name or by rule must be trusted by whatever opens them: export the
variables of `proxy-ctl mitm ca --env` in that shell, or use `mitm run`.

## Where it leaves

What mitmproxy has read comes back into the proxy and leaves by `mitm.upstream`:

- `"proxy"` (the default): through the outbound in use.
- `"direct"`: straight out.
- an outbound or group tag: through that one, to read a site that is blocked here.

```sh
proxy-ctl mitm upstream nl-vps   # now, without a restart
proxy-ctl mitm upstream          # where it leaves
```

It leaves by that one exit whatever your routing rules say about the site.

## Another device

Point a phone at this host and read what it sends:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  mitm = {
    enable = true;
    web.enable = true;
    listener = {
      address = "0.0.0.0";
      openFirewall = true;
      auth = {
        username = "phone";
        passwordFile = "/run/secrets/mitm-listener";
      };
    };
  };
};
```

On the device, set this host's address and port 1088 as the HTTP proxy, with that login,
then open `http://mitm.it` and install the CA it offers. `proxy-ctl mitm listener` shows
the address again.

## Containers and virtual machines

A proxy setting only catches programs that follow it. `mitm.interfaces` takes all the TCP
that arrives from an interface, with nothing to set in the guest but the CA:

```nix
networking.nftables.enable = true;
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  mitm = {
    enable = true;
    web.enable = true;
    interfaces = [ "waydroid0" ];
  };
};
```

For Waydroid, whose apps trust only the system's CAs:

```sh
sudo install -D -m 0644 "$(proxy-ctl mitm ca --android)" \
  -t /var/lib/waydroid/overlay/system/etc/security/cacerts/
waydroid session stop   # and start it again
```

The guests' own network, this host and `proxy.tproxy.localSubnets` are left alone. UDP to
port 443 is refused, so the guests fall back from QUIC; other UDP is forwarded as before.

## Trust the CA elsewhere

mitmproxy makes its CA when it first starts and keeps the key to itself. The certificate is
public:

```sh
proxy-ctl mitm ca            # the certificate
proxy-ctl mitm ca --path     # where it is
proxy-ctl mitm ca --env      # export lines for a shell
```

In Nix, `config.lib.proxy-suite.mitm` has the same: `caFile`, `caBundle` (the system's CAs
with it), `caEnv` (the variables) and `wrap`, which builds a package whose programs always
run through mitmproxy:

```nix
{ config, pkgs, ... }:
{
  services.proxy-suite = {
    enable = true;
    mitm.enable = true;
  };
  environment.systemPackages = [
    (config.lib.proxy-suite.mitm.wrap { } pkgs.httpie)
  ];
}
```

To have the whole system trust it, give mitmproxy a CA of your own, which you can list in
`security.pki.certificateFiles` because its certificate exists before the system is built:

```nix
services.proxy-suite = {
  enable = true;
  mitm = {
    enable = true;
    ca = {
      certFile = "/run/secrets/mitm-ca.crt";
      keyFile = "/run/secrets/mitm-ca.key";
    };
  };
};
```

## A log for jq

`mitm.requestLog` writes a line of JSON for each request to `requests.jsonl`: the time,
client, method, URL, status or error, duration, sizes and content type. With `headers`
enabled, every header too, cookies and logins among them.

It is not kept: the file is in memory, under `/run/proxy-suite-mitm/requests/`, and goes when
mitmproxy stops or restarts (switching mitmweb, say). At `maxSizeMiB` (64) it becomes
`requests.jsonl.1`, replacing the one there. To keep a session, follow it into a file of
your own; `persist = true` keeps the log itself, in `/var/lib/proxy-suite/mitm-requests/`.

Who may open mitmweb may read it: the groups whose [`userControl`](./control.md) scopes hold
`mitm`. Others need `sudo`.

```nix
services.proxy-suite = {
  enable = true;
  mitm = {
    enable = true;
    requestLog.enable = true;
  };
};
```

```sh
proxy-ctl mitm requests on                     # or off; and where the file is
proxy-ctl mitm requests follow | jq .           # each request as it ends
proxy-ctl mitm requests follow > session.jsonl  # the lines alone, from now on
proxy-ctl mitm requests follow --all | jq -r --unbuffered \
  'select(.status >= 400 or .error) | "\(.status // .error) \(.url)"'
```

`follow` writes whole lines only, from now or with `--all` from the start, and keeps up when
the log is rotated, truncated or made anew. A line is written once the answer has ended or failed: a
long download shows when it is done, and WebSocket messages are not in it.

The same addon makes the lines from requests kept before (`mitm flows on`):

```sh
mitmdump -nr flows.mitm -s "$(proxy-ctl mitm requests --addon)" --set request_log_file=requests.jsonl
```

To empty it before then, use `truncate -s0`: mitmproxy keeps writing to a file that is
removed until it restarts. With the proxy on, every client is the backend on loopback.

## Your own addon, for one capture

An addon of your own, one that decodes an app's bodies say, runs in a `mitmdump` of yours,
as you, with the Python packages it needs, for as long as the capture lasts. mitmproxy's
service hands it the whole requests and runs nothing of yours:

```sh
proxy-ctl mitm requests bodies on   # or mitm.requestLog.bodies = true
proxy-ctl mitm requests follow --bodies \
  | mitmdump -nr - -s my_addon.py --set my_option=capture.jsonl
```

The requests reach it as they end, from now on (`--all`: from the start); Ctrl-C ends the
capture. They are in `requests.mitm` beside the log, as mitmproxy's flows, readable by the
same groups, rotated at the same size. Use a `mitmdump` no older than the service's, which
reads the flows of its own version.

Bodies take room: a large download is one flow of its size, in memory. Turn them off when
done. A consumer that falls behind by more than two files' worth misses the files rotated
away in between: raise `maxSizeMiB` for captures with large downloads.

## Without the proxy

With `proxy.enable` off, mitmproxy is a proxy of its own on `mitm.listener` and dials by
itself. `mitm run`, the listener and the CA work the same; `hosts`, `upstream` and
`interfaces` need the proxy.

## Without a rebuild

`proxy-ctl mitm` changes the upstream, the sites read, the sites passed on undecrypted
(`mitm ignore add`, for programs that pin their certificates), mitmweb, whether requests
are kept on disk (`mitm flows on`) and whether they are logged (`mitm requests on`). The same is
in the mitm tab of `proxy-tui` and the GUI.
Without root it takes the `mitm` scope of [`userControl`](./control.md); `mitm hosts` and
`mitm all` are routing rules and take `routing` too.

## Good to know

- mitmweb shows passwords and cookies as they are sent, and saved requests hold them.
  Turn both off when done.
- Programs that pin their certificates fail through it. Add their sites to
  `mitm.ignoreHosts`, or do not send them.
- It carries no UDP: QUIC to a site that is read is refused, and browsers take TCP.
- The site sees mitmproxy's TLS handshake, not the browser's. Bot protection may answer
  differently, and DPI problems cannot be studied this way.
- It needs the sing-box or hybrid backend, or no proxy at all.
- The internal port takes no login. On a host without root (home-manager, Nix-on-Droid)
  other local users can reach it.

## See also

- [`mitm`](../options/mitm.md): every option
- [Track down a problem](./debug.md): connection logs, when the request itself is not needed
- [Route a single app](./per-app.md): `apps run --via`
- [Wrap programs with the proxy](./wrap-apps.md): the other `config.lib.proxy-suite` helpers
