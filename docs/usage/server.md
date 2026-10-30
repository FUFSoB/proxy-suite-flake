# Run your own server

Accept proxy clients on a VPS, and hand out share links, QR codes and subscriptions for
them. The listeners run on XRay, and AmneziaWG listeners run on AmneziaWG.

## A fresh VPS: the installer

If your provider lets you boot a custom ISO, build the installer:

```sh
nix build github:FUFSoB/proxy-suite-flake#installer-iso
```

The image is `result/iso/proxy-suite-installer-<build time>-<commit>-<system>.iso`. Boot
the VPS from it. The console installer asks for the public IP, users, an optional
domain, whether to run the QEMU guest agent (so the VPS panel sees the server's state)
and the disk to erase, then installs NixOS with `nixosModules.server`: VLESS
REALITY, TLS and WS listeners, ACME certificates and SSH, with fish as the login shell
and vim (nano stays the default editor), git, htop, tmux, jq, mtr, iftop, dig, ncdu,
iperf3, tcpdump, bandwhich, nload, lsof and nvd (`services.proxy-suite-server.tools`).
It also collects Nix garbage weekly (generations older than 14 days, 10 boot entries at
most), caps the journal at 200M, bans addresses that keep failing SSH logins (fail2ban),
and counts traffic per day and month (`vnstat -m`); each is a NixOS default to override.
It installs the proxy-suite source the ISO carries: `/etc/nixos` follows this repository
on GitHub when the ISO's commit is there, and holds a copy otherwise. The disk is laid out by disko
(`services.proxy-suite-server.disko`): btrfs with `compress=zstd:3`, subvolumes `@` on `/`,
`@nix`, `@varlog` on `/var/log` and `@home`, and a 2G swap file in `@swap`. After the reboot, log in
and run:

```sh
proxy-ctl inbounds link vless-reality --qr
```

## An existing NixOS host

```nix
services.proxy-suite = {
  enable = true;
  inbounds = {
    enable = true;
    serverAddress = "vpn.example.com"; # null: this host's public IPv4
    routing.via = "direct";            # clients exit straight from this host
    # Each user once; listeners name the ones they accept, and take the secret they need.
    users = {
      phone.uuidFile = "/run/secrets/uuid-phone";
      laptop.uuidFile = "/run/secrets/uuid-laptop";
    };
    listeners = {
      vless-reality = {
        type = "vless";
        port = 443;
        flow = "xtls-rprx-vision";
        users = [ "phone" "laptop" ];
        reality = {
          enable = true;
          serverNames = [ "www.microsoft.com" ];
          privateKeyFile = "/run/secrets/reality-private-key";
          publicKey = "jNXH…"; # both keys from `xray x25519`
          shortIds = [ "0123abcd" ];
        };
      };
      # Keys for the server and each user are generated on first start.
      awg = {
        type = "amneziawg";
        port = 51820;
        users = [ "phone" ];
      };
    };
  };
};
```

Store the secrets with your secrets tool (see [Keep secrets out of the Nix store](./secrets.md)).
To make them:

```sh
uuidgen                           # one UUID per user
nix run nixpkgs#xray -- x25519    # the private key for the file, the public key for the config
```

The firewall opens the listener ports on its own. Other protocols (trojan, shadowsocks,
hysteria2, vmess, …) and transports (ws, grpc, xhttp) are set per listener; see
[`inbounds.listeners`](../options/inbounds.md#services-proxy-suite-inbounds-listeners).

## Share access

```sh
proxy-ctl inbounds                               # listeners
proxy-ctl inbounds link vless-reality phone --qr # link as a QR code for the phone
proxy-ctl inbounds link awg phone --config       # AmneziaWG .conf
proxy-ctl inbounds users                         # users: order, address, listeners
proxy-ctl inbounds stats                         # traffic per user
proxy-ctl inbounds online                        # who is connected
```

Subscriptions give each user one URL with their links from every listener, so clients pick
up changes on their own. Enable them and serve the directory with a web server:

```nix
services.proxy-suite.inbounds.subscriptions = {
  enable = true;
  baseUrl = "https://vpn.example.com/sub";
};
services.nginx.virtualHosts."vpn.example.com".locations."/sub/" = {
  alias = "/run/proxy-suite-inbounds/subscriptions/";
  extraConfig = "access_log off;";   # the token is the URL's secret
};
```

Then `proxy-ctl inbounds sub phone --qr` prints that user's subscription.

The token at the end of the URL is all that guards a subscription. It is an HMAC under a key
generated on first start (/var/lib/proxy-suite/inbounds/subscription-key, carried by
`proxy-ctl inbounds export`), or under `subscriptions.keyFile` when you keep your own. A
server that handed out URLs before there was a key keeps them with
`subscriptions.keyFile = false`: its tokens stay a hash of the user's name and
credentials, which anyone who has one of the user's links can work out, and with it the rest
of their links. Turning the key on later changes every user's URL.

## Add users and listeners at runtime

With `inbounds.runtime`, users and listeners can be added with `proxy-ctl`, the TUI or the app,
without a rebuild. The config says what they may use: ports, exits and certificates.

```nix
services.proxy-suite.inbounds.runtime = {
  enable = true;
  ports = [ "20000-20099" ];   # runtime listeners bind only here; opened in the firewall
  vias = [ "direct" ];         # exits besides routing.via and "block"
  tlsCertificates.main = {     # named, so a runtime listener never points at a file
    certificateFile = "/var/lib/acme/vpn.example.com/fullchain.pem";
    keyFile = "/var/lib/acme/vpn.example.com/key.pem";
  };
};
```

```sh
proxy-ctl inbounds users add alice --listener vless-reality   # secrets are generated
proxy-ctl inbounds add friends vless --port 20001 --reality www.microsoft.com --user alice
proxy-ctl inbounds bind phone friends                          # a declared user on it too
proxy-ctl inbounds users                                       # order, address, listeners
proxy-ctl inbounds link friends alice --qr
```

A runtime user can join any listener; a declared user only a runtime one (bind two declared
ones in the config). Each user's `order` is its `routing.serverSource` number, as in the
config: given with `--order` or the lowest free one, and kept. A listener takes JSON too,
shaped like an [`inbounds.listeners`](../options/inbounds.md#services-proxy-suite-inbounds-listeners)
entry: `proxy-ctl inbounds add friends listener.json`. It cannot name files, raw XRay JSON,
AmneziaWG or port hopping; REALITY keys and Shadowsocks 2022 server keys are generated.

Every change restarts the inbounds, which drops the connections once. One that does not hold
up is refused, and anything that stops working later (a certificate removed from the config,
say) is left out with a warning in `proxy-ctl logs proxy-suite-inbounds` while the rest runs.
Without root, members of `userControl.group` need the `inbounds` scope.

## Policies: expiry, traffic, devices, speed

`inbounds.manager` runs a daemon that keeps each user's policy and applies it to the running
inbounds without a restart: users switched off, out of time or out of traffic leave XRay
through its API (their open connections are cut), the others keep theirs.

```nix
services.proxy-suite.inbounds = {
  manager = {
    enable = true;
    speedLimits.enable = true;   # nftables, and proxy-suite's XRay patch
  };
  # Declared users take a policy in the config; runtime ones get theirs from proxy-ctl or the API.
  users.phone.policy = {
    expiresAt = "2026-12-31";
    trafficLimit = "100G";
    trafficPeriod = "monthly";
    ipLimit = 2;
    speedLimit = "50M/10M";      # down/up, bits per second
  };
};
```

```sh
proxy-ctl inbounds users add alice --listener vless-reality --expires +30d --traffic 50G --period monthly --ips 2
proxy-ctl inbounds users                     # status, traffic used of the allowance, expiry
proxy-ctl inbounds users show alice
proxy-ctl inbounds users set alice --speed 20M/5M
proxy-ctl inbounds users extend alice 30d    # from the expiry, or from now if it passed
proxy-ctl inbounds users extend alice 30d --reset   # a renewal: the traffic starts over too
proxy-ctl inbounds users add bob --listener vless-reality --on-hold 30d --traffic 50G
proxy-ctl inbounds users reset alice         # start the traffic over
proxy-ctl inbounds users rotate-sub alice    # a new subscription URL; the old one stops answering
proxy-ctl inbounds users disable alice
proxy-ctl inbounds bans                      # addresses past an ipLimit, banned for a while
```

What a policy holds:

- `expiresAt`: past it the user is switched off, and their subscription still says when.
- `expiresAfter` (`--on-hold`): a term that starts with the first connection, for access sold
  ahead. Until the user connects they are on hold; then `expiresAt` is set that much later
  (event user.activated). `extend` lengthens the term while on hold. An `expiresAt` given wins.
- `trafficLimit`, `trafficPeriod`: up and down together, counted from the day the user came
  or was reset; a period renews at local midnight, monthly on that day of the month.
- `ipLimit`: past it, the addresses that came last are banned from the user's ports for
  `manager.ipLimit.banTime`. Not on AmneziaWG (a peer has one address anyway), nor behind
  a PROXY-protocol front.
- `speedLimit`: XRay marks the sockets its exits dial for the user with their slot, and
  nftables polices that mark both ways; AmneziaWG peers by their tunnel address.
- `meta`: strings for a bot of yours, such as a Telegram ID.

Runtime users expired long ago can go by themselves: `manager.deleteExpiredAfter = "30d"`
deletes each that long after its expiry (event user.deleted, with the reason). Declared users
stay.

Subscriptions served by the manager carry the traffic, the allowance and the expiry
(`subscription-userinfo`), which v2rayN, Hiddify, Happ and Streisand show, plus a title and
an update interval. The same URL answers each client in what it reads:

- Clash and mihomo apps (Clash Meta, Clash Verge, FlClash, Stash): a mihomo config, the
  user's servers in a group that picks the fastest and one to choose by hand.
- The sing-box apps (SFA, SFI, SFM): a sing-box config with TUN.
- A browser: a page with the state, traffic and expiry, a QR code, buttons that add the
  subscription to an app, and each link to copy. In Russian when the browser asks for it.
  The buttons for the browser's system come first (Android, iOS, macOS, Windows, Linux), the
  rest under "Other apps": Happ, Hiddify, v2rayNG, Streisand, Karing, sing-box, Clash (Clash
  Meta, FlClash, Clash Verge Rev, Clash Party, Stash) and, on Linux, proxy-suite's own desktop
  app (`gui.enable`), which asks before it adds the subscription.
- Everything else, Hiddify included: base64 of the links, as before.

`?format=base64|links|clash|sing-box|html` picks one by hand. Listeners only XRay dials
(XHTTP, ECH) are left out of the Clash and sing-box configs, and AmneziaWG out of all of them.
The page's QR code, drawn by the browser, is of `inbounds.subscriptions.baseUrl`; without it,
of the address the browser asked for, as the web server passes it on in `Host` and
`X-Forwarded-Proto`. Set `baseUrl`: then no header decides what the page offers. The page
runs nothing but its own script and stylesheet (a CSP with their hashes), and no answer is
cached, sent on as a referrer or indexed.

Point the web server at the manager's socket instead of the static files; the tokens and so
the URLs stay the same. Keep the tokens out of its access log, and slow down whoever guesses:

```nix
services.nginx.appendHttpConfig = "limit_req_zone $binary_remote_addr zone=sub:1m rate=30r/m;";
services.nginx.virtualHosts."vpn.example.com".locations."/sub/" = {
  proxyPass = "http://unix:/run/proxy-suite-inbounds-manager/sub.sock:";
  recommendedProxySettings = true;   # Host, X-Forwarded-Proto, X-Real-IP
  extraConfig = ''
    access_log off;
    limit_req zone=sub burst=20 nodelay;
  '';
};
```

A token that is not there gets a 404 and a line in the manager's journal, at most one a minute
per address (X-Real-IP from the web server), with how many came since:
`subscription: unknown token from 203.0.113.7 (12 more since the last line)`. A fail2ban
filter on it bans whoever keeps guessing.

`proxy-ctl inbounds users rotate-sub <name>` gives a user a new URL with their credentials
left as they are, for a URL that got out; their clients need the new one. It stays with the
user through an export and import.

Worth knowing:

- A user switched off by the manager loses their open connections too: TCP ones are closed
  (`ss -K`), UDP ones (Hysteria2, XHTTP over HTTP/3) dropped for a while. Others behind the
  same address reconnect once. Without the manager, removing a runtime user cuts its TCP
  connections only.
- Giving a user a speed limit, or taking it away, changes their XRay level: their
  connections drop once.
- An exit whose own JSON or URL sets `sockopt.mark` keeps it, and its users are not
  speed-limited there. Socks and http listeners take no speed limit either.

### The API

The manager answers HTTP+JSON on `/run/proxy-suite-inbounds-manager/api.sock` (root, and
`userControl.group` with the "inbounds" scope, or `manager.api.group`), and with
`manager.api.listen` and bearer tokens over TCP, for a bot elsewhere (behind TLS):

```sh
curl --unix-socket /run/proxy-suite-inbounds-manager/api.sock http://x/api/v1/users
curl --unix-socket /run/proxy-suite-inbounds-manager/api.sock http://x/api/v1/users \
  -d '{"name": "bob", "listeners": ["vless-reality"], "policy": {"expiresAt": "+30d", "trafficLimit": "50G"}}'
```

| Call | What |
| --- | --- |
| `GET /api/v1/users`, `GET /api/v1/users/<name>` | users: policy, status and why, traffic, online addresses, subscription |
| `POST /api/v1/users` | `{name, listeners, order?, policy?}`: a runtime user, secrets generated |
| `PATCH /api/v1/users/<name>` | policy fields, and `unset: [fields]` to drop runtime ones |
| `DELETE /api/v1/users/<name>` | a runtime user, and their policy |
| `POST /api/v1/users/<name>/enable`, `/disable`, `/reset-traffic` | |
| `POST /api/v1/users/<name>/extend` | `{by: "30d"}` or `{until: "2027-01-31"}`, and `resetTraffic: true` to start the traffic over |
| `POST /api/v1/users/<name>/rotate-subscription` | a new subscription URL; the old one stops answering |
| `PUT /api/v1/users/<name>/listeners` | `{listeners: [...]}` |
| `GET /api/v1/users/<name>/links` | share links and client configs |
| `GET /api/v1/listeners`, `/online`, `/bans`; `DELETE /api/v1/bans/<address>` | |
| `GET /api/v1/export`, `POST /api/v1/import` | see below |
| `GET /api/v1/events` | the latest events |

Sizes take K, M, G, T (binary), speeds k, M, G bits per second, times a date, an ISO time,
a Unix time or `+30d`. Errors come as `{"error": "..."}` with a 4xx status.

`manager.webhooks` POST each event as JSON (`{event, user, at, data}`), signed with
`X-Proxy-Suite-Signature: sha256=<HMAC>` when given a secret: user.created, user.deleted,
user.updated, user.enabled, user.disabled (with the reasons), user.reset, user.activated
(a term on hold started), user.traffic (80 % and 100 % of the allowance), user.expiring
(3 days and 1 day before) and user.ip-limit.

### Moving to another server

```sh
proxy-ctl inbounds export users.json          # on the old one: 0600, it holds every secret
proxy-ctl inbounds import users.json          # on the new one, with the same listeners
```

The export holds the runtime users and listeners (their UUIDs, passwords and REALITY keys),
the policies and what they are measured against, the AmneziaWG listeners' keys and
addresses, the Salamander passwords, VLESS Encryption keys and shadowtls server keys
proxy-suite generated, and the traffic counted. Secrets
the config names by file (sops and the like) are not in it. Runtime users and listeners
already on the new server are refused and policies already there kept, unless `--replace`;
an AmneziaWG listener that has a key already keeps it unless `--replace`, which its existing
clients need.

## Good to know

- Clients cannot reach this host's LAN or Russian sites by default
  (`inbounds.routing.blockPrivate`, `blockRu`).
- Nor, by default, BitTorrent or port 25 (`routing.blockTorrent`, `routing.blockPorts`):
  copyright notices and spam are what hosters close servers over. XRay's sniffing catches
  the peers' handshake, not trackers, DHT or encrypted connections: torrents get slow, not
  impossible. Should a complaint come anyway, `inbounds.accessLog` logs who went where.
- Through "direct", clients reach this host itself only on the listeners' ports and
  `inbounds.serverPorts` (80/443 with subscriptions), whatever it listens on. Its addresses
  are read when the inbounds start: restart them after the address changes.
- With `routing.via = "proxy"` (the default), client traffic goes through this host's own
  proxy instead, following its routing. That needs `proxy.enable`. A listener can also exit
  through one outbound with `via = "<tag>"`.
- For clients that cannot reach the server at all, `tor.onionService` serves the
  listeners over Tor too.

## See also

- [`inbounds.listeners`](../options/inbounds.md#services-proxy-suite-inbounds-listeners)
- [`inbounds.routing.via`](../options/inbounds.md#services-proxy-suite-inbounds-routing-via)
- [`inbounds.runtime`](../options/inbounds.md#services-proxy-suite-inbounds-runtime-enable)
- [`inbounds.subscriptions`](../options/inbounds.md#services-proxy-suite-inbounds-subscriptions-enable)
- [`tor.onionService`](../options/tor.md#services-proxy-suite-tor-onionservice-enable)
