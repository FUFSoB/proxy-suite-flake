# Track down a problem

Turn on more logging, and record connections, for a problem that comes and goes. Each of
these logs to the journal; `proxy-ctl logs <unit>` follows it.

## Record connections

Pages that sometimes half load, or images left blank, are hard to catch on demand. Record
the backend's connections and look back at the time it happened:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  debug.connectionLog = {
    enable = true;
    hosts = [ "x.com" "twimg.com" ]; # leave empty for every site
    inbounds = [ "tproxy" ]; # global and per-app TProxy only
  };
};
```

```sh
journalctl -u 'proxy-suite-connection-log*' --since "10 min ago"
```

There is a recorder per backend: `proxy-suite-connection-log` for the local proxy and TProxy,
global or per-app, `proxy-suite-connection-log-tun` for the global TUN and
`proxy-suite-connection-log-per-app-tun` for per-app TUN. Each runs while its backend does.
TUN connections come in on `tun-in`: put that in `inbounds` too, or leave it empty.

Each connection gets a line as it opens, with its listener, site, rule and exit, and one as
it closes, with the bytes each way. One that sent and got nothing back for
`stallAfter` seconds is logged as `stalled`, and as `resumed` if the answer comes. A
connection is looked at every `interval` seconds, so one shorter than that can be missed,
and the byte counts are from the last look.

The same, live and without a rebuild:

```sh
proxy-ctl debug conns --host twimg.com --inbound tproxy
```

It needs root, or the `secrets` scope: connections show every site visited. `--backend tun`
or `--backend per-app-tun` shows a TUN backend's, as root and with `debug.connectionLog` on,
which gives those backends the API it reads.

## More from the backend

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  debug.logLevel = "info"; # every connection and the rule that routed it
};
```

"debug" and "trace" log more than that, including DNS. Follow it with
`proxy-ctl logs proxy-suite-socks`.

## DNS of per-app routes

Apps run through per-app TUN or TProxy have their lookups sent on into the route. To see
each lookup, its answer and how long it took, and the ones that got no answer:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
  };
  perAppRouting = {
    enable = true;
    tproxy.enable = true;
  };
  debug.perAppDns = true;
};
```

```sh
proxy-ctl logs proxy-suite-per-app-tproxy-dns
```

## Good to know

- All of these can log every site visited, for anyone who can read the journal. Turn them
  off when done.
- zapret2 has its own: `debug.zapret2.packets` logs every packet nfqws2 handles, and
  `debug.zapret2.autoHostlist` why sites are or are not learned.

## See also

- [`debug`](../options/debug.md): every option
- [Control it day to day](./control.md): `proxy-ctl logs` and the rest
