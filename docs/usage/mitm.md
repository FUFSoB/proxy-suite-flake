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

All of these send it TCP. With `mitm.udp` their UDP goes to it too (UDP, below).

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
port 443 is refused, so the guests fall back from QUIC. Their other UDP is forwarded as
before, or read too with `mitm.udp`.

`waydroid0` is a bridge. Where Docker runs, bridge netfilter (`br_netfilter`) is on, and the
guests get no network at all: it diverts their packets before the IP stack, which loses the
divert. `proxy-ctl mitm` says so. Turn it off, at boot and each time Docker starts:

```nix
services.proxy-suite.proxy.tproxy.bridgeNetfilter = "off";
```

Docker then no longer filters traffic between containers on one of its bridges with iptables.
`proxy.tproxy.lanInterfaces` on a bridge (`br0`) needs the same.

## UDP

A game or a call sends UDP. mitmproxy reads it too with `mitm.udp.enable`: each datagram is
a message of a UDP flow, in mitmweb, the request log and the programs attached to it (both
below).

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
    interfaces = [ "waydroid0" ];
    udp.enable = true;
  };
};
```

The UDP that goes to "mitm" reaches mitmproxy through a WireGuard tunnel on loopback, whose
keys the host draws once: from `interfaces`, the listener's SOCKS5, `hosts`, routing rules,
and programs run with `proxy-ctl mitm run` or `apps run --via mitm` (on either route; `mitm
run` without pin slots sets `ALL_PROXY` to the listener's SOCKS5 too, for programs that send
UDP through it). The TUN backends hand theirs to the local proxy's end of the tunnel through
a SOCKS5 relay on loopback (`mitm.udp.relayPort`). What mitmproxy sends on is marked by its
user and comes back into the proxy, so it leaves by `mitm.upstream` as TCP does: `proxy-ctl
mitm upstream` switches both.

- QUIC (UDP to port 443) is still refused: browsers and apps take TCP, which is read.
- A datagram's content can be changed, by an addon or an attached program, but not dropped.
- When mitmproxy restarts (switching mitmweb, the log or an addon loaded), its flows break
  off and the tunnel takes some seconds to come back: a game may drop out. Switch things
  between sessions.
- sing-box pauses the tunnel while the host has no default route, as it does its other
  WireGuard endpoints.
- It needs root and, on NixOS, the nftables firewall.

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
enabled, every header too, cookies and logins among them. Each line has a `kind`: `http`, or
`websocket`, `tcp` and `udp` for flows of messages, whose line comes as the flow ends (a UDP
one after 20 idle seconds) with the messages and bytes each way and the server.

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
long download shows when it is done. For each request or message as it comes, attach.

The same addon makes the lines from requests kept before (`mitm flows on`):

```sh
mitmdump -nr flows.mitm -s "$(proxy-ctl mitm requests --addon)" --set request_log_file=requests.jsonl
```

To empty it before then, use `truncate -s0`: mitmproxy keeps writing to a file that is
removed until it restarts. With the proxy on, every client is the backend on loopback.

## Your own addon, live

An addon of your own, one that decodes an app's messages say, runs in a `mitmdump` of yours,
as you, with the Python packages it needs. `mitm attach` attaches it to mitmproxy: its
hooks see each request, answer and WebSocket, TCP or UDP message as it comes, TCP and UDP in
the one program.

```sh
proxy-ctl mitm attach -- mitmdump -s my_addon.py --set my_option=capture.jsonl
proxy-ctl mitm attach -- mitmproxy                    # its console, or mitmweb, on the live flows
```

It reads copies and holds nothing up. With `--modify`, what its addons change is what is sent
on: put your own data in an answer, make one in `request` (`flow.response = …`), change a
datagram, kill a flow, or intercept one in mitmproxy's console or mitmweb and edit it there.
Each hook then waits for it; one that has not answered in `mitm.attach.timeout` seconds
(5) is detached, and the flow goes on unchanged.

```sh
proxy-ctl mitm attach --modify -- mitmdump -s inject.py
proxy-ctl mitm attach --modify -- mitmproxy --set attach_timeout=300 --set attach_filter='~d example.com'
```

| Option (`--set`) | |
|---|---|
| `attach_filter` | only the flows a [filter expression](https://docs.mitmproxy.org/stable/concepts/filters/) matches: `~udp`, `~d example.com` |
| `attach_timeout` | seconds the service waits for each answer, for an intercepted flow edited by hand |
| `attach_keep_messages` | keep at most this many messages on each flow, for long UDP sessions |
| `attach_reconnect` | `false`: stop when mitmproxy restarts, rather than attach again |

A flow is the same object from its first hook to its last, so what an addon keeps in
`flow.metadata` in `request` is there in `response`. The attached mitmdump is mitmproxy's own
kind: `-w capture.mitm` keeps what it saw. Use one no older than the service's mitmproxy, and
the same version to change traffic. Who may read the request log may attach: the groups
whose [`userControl`](./control.md) scopes hold `mitm`, and root.

## Your own addon, after the fact

The same addon over what the request log kept whole, bodies included, with nothing attached:

```sh
proxy-ctl mitm requests bodies on   # or mitm.requestLog.bodies = true
proxy-ctl mitm requests follow --bodies \
  | mitmdump -nr - -s my_addon.py --set my_option=capture.jsonl
```

The requests reach it as they end, from now on (`--all`: from the start); Ctrl-C ends the
capture. They are in `requests.mitm` beside the log, as mitmproxy's flows, readable by the
same groups, rotated at the same size. Use a `mitmdump` no older than the service's, which
reads the flows of its own version.

A WebSocket, TCP or UDP flow is written in parts as it goes, one each MiB or ten seconds: each
with the messages since the last, the flow's id, and its number in `flow.metadata["proxy-suite-part"]`.
The addon sees each part's start, messages and end.

Bodies take room: a large download is one flow of its size, in memory. Turn them off when
done. A consumer that falls behind by more than two files' worth misses the files rotated
away in between: raise `maxSizeMiB` for captures with large downloads.

## Addons inside mitmproxy

`mitm attach` is for a session. An addon mitmproxy itself is to run, every time it runs,
goes in `mitm.extraOptions.scripts`, or without a rebuild:

```sh
sudo proxy-ctl mitm addon load my_addon.py --set my_option=on   # restarts mitmproxy
proxy-ctl mitm addon                                            # those loaded, with their options
sudo proxy-ctl mitm addon unload my_addon
```

It runs as mitmproxy's own user, which reads the CA's key: so loading one takes root, unless
`mitm.addons.userControl` gives it to the `mitm` scope. It has mitmproxy's Python packages
and those of `mitm.pythonPackages`, and writes what it finds to `$PROXY_SUITE_MITM_OUTPUT`,
beside the request log and read as it is.

```nix
services.proxy-suite.mitm.pythonPackages = ps: [ ps.msgpack ps.pycryptodome ];
```

mitmproxy's own addons run first, then the attached programs, then the request log, which
keeps what was sent on.

## Without the proxy

With `proxy.enable` off, mitmproxy is a proxy of its own on `mitm.listener` and dials by
itself. `mitm run`, the listener and the CA work the same; `hosts`, `upstream` and
`interfaces` need the proxy.

## Without a rebuild

`proxy-ctl mitm` changes the upstream, the sites read, the sites passed on undecrypted
(`mitm ignore add`, for programs that pin their certificates), mitmweb, whether requests
are kept on disk (`mitm flows on`), whether they are logged (`mitm requests on`) and the
addons it runs (`mitm addon load`). The same, but the addons, is in the mitm tab of `proxy-tui`
and the GUI.
Without root it takes the `mitm` scope of [`userControl`](./control.md); `mitm hosts` and
`mitm all` are routing rules and take `routing` too.

## Good to know

- mitmweb shows passwords and cookies as they are sent, and saved requests hold them.
  Turn both off when done.
- Programs that pin their certificates fail through it. Add their sites to
  `mitm.ignoreHosts`, or do not send them.
- QUIC to a site that is read is refused, and browsers take TCP; other UDP is read only with
  `mitm.udp`.
- mitmweb shows the UDP tunnel's client settings, its key among them, to whoever opens it:
  they could send UDP out through mitmproxy, as they can through `mitm.listener`.
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
