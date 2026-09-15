# proxy-suite-flake

Declarative proxy stack for NixOS, built for dealing with Roskomnadzor and the usual Russian ISP nonsense. Configure it in Nix, rebuild, and it runs as systemd services.

Bundles [sing-box](https://github.com/SagerNet/sing-box), [XRay](https://github.com/XTLS/Xray-core), [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go), [zapret-discord-youtube](https://github.com/kartavkun/zapret-discord-youtube), [zapret2](https://github.com/bol-van/zapret2) and [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy).

## Features

- Local SOCKS5/HTTP proxy on `127.0.0.1:1080`, backed by sing-box, XRay, or both
- Global TProxy or TUN mode, on demand or at boot
- Per-app routing: `proxy-ctl apps run <profile> -- <cmd>` through proxychains, a per-app TUN/TProxy, or zapret
- Outbounds from URLs, raw JSON or subscriptions; manual or latency-based selection; per-outbound routing
- vless (REALITY, TLS), vmess, trojan, shadowsocks, hysteria2, socks, http; TUIC, AnyTLS and NaïveProxy on sing-box, XHTTP/ECH on XRay
- Proxy chains: any outbound or a whole subscription can connect through another (`detour`)
- autoProxy: finds which exit reaches a blocked site and routes it there
- zapret DPI bypass, including zapret2, which learns blocked sites at runtime
- AmneziaWG 1.x–3.x tunnels from `.conf`, `vpn://`, or Nix
- Telegram MTProto WebSocket proxy and SSH SOCKS5 tunnel
- Cloudflare WARP from a `wgcf` profile, as an outbound or an AWG VPN profile
- Server inbounds with share links, QR codes, per-user subscriptions and traffic stats
- Proxy Suite GUI (a desktop app with a tray icon), the `proxy-ctl` CLI, and the `proxy-tui` terminal UI

## Setup

```nix
inputs.proxy-suite.url = "github:FUFSoB/proxy-suite-flake";
```

```nix
modules = [ inputs.proxy-suite.nixosModules.default ];
```

Starter config:

```nix
services.proxy-suite = {
  enable = true;

  proxy = {
    enable = true;
    backend = "sing-box"; # or "xray", or "hybrid"

    # url ends up in the Nix store; use urlFile for real secrets.
    outbounds = [ { tag = "nl-vps"; url = "hy2://password@example.com:443?sni=example.com"; } ];
    subscriptions = [ { tag = "main-sub"; urlFile = "/run/secrets/sub-url"; } ];
    selection = "urltest"; # Default is "first", without any complex selector

    tproxy.enable = true;
    tun.enable = true;
  };

  perAppRouting = {
    enable = true;
    createDefaultProfiles = true;
    proxychains.enable = true;
    tun.enable = true;
    tproxy.enable = true;
    zapret.enable = true;
  };

  zapret.enable = true;

  sshProxy = {
    enable = true;
    server = {
      user = "root";
      host = "ssh.example.com";
    };
    identityFile = "/run/secrets/proxy-suite-ssh-key";
    hostKeyFile = "/run/secrets/proxy-suite-ssh-known-hosts";
  };

  # Only one AWG, TUN or TProxy global tunnel runs at a time.
  amneziaWg = {
    enable = true;
    profiles.home.configFile = "/run/secrets/home-amneziawg.conf";
    profiles.work.vpnFile = "/run/secrets/work-amnezia.vpn";
    # An outbound tagged "de" instead: the proxy binds to its interface, which gets no routes.
    profiles.de = {
      asOutbound = "interface"; # or "singBox": plain WireGuard inside sing-box
      configFile = "/run/secrets/de-amneziawg.conf";
    };
  };

  # Registers with wgcf on first start. The exit is Cloudflare, but geolocated to your own country.
  warp = {
    enable = true;
    asOutbound = "singBox"; # tag "warp"; "interface" runs it as an AmneziaWG profile
    # asAmneziaWg = true; # or a global profile instead: proxy-ctl awg on warp
  };

  tgWsProxy = {
    enable = true;
    secretFile = "/run/secrets/tg-ws-proxy-secret";
  };

  gui.enable = true;
};
```

---

## Options

See the [options reference](./docs/options/index.md), one page per option group. Regenerate it and the help below with `nix run .#update-docs`.

## `proxy-ctl help`

<!-- proxy-ctl-help:start -->
```text
Usage: proxy-ctl <group> [verb] [args]
A group without a verb shows its status or list.

  status [--json]                        services and routing mode (--tray: deprecated key=value lines)
  restart                                restart active services
  logs [unit]                            follow logs (default: every proxy-suite unit)
  where <domain>                         how this host is routed right now

  proxy [status|on|off]                  local proxy backend
  proxy outbounds [list]                 outbounds, where each came from, and the pick
  proxy outbounds add <tag> <url|json|-> [--detour <tag>]
                                         add an outbound at runtime: a URL, or sing-box/XRay JSON (-: stdin),
                                         chained through another outbound with --detour
  proxy outbounds rm <tag>               remove a runtime outbound
  proxy outbounds test [tag...] [--ping] [--delay] [--download]
                                         TCP ping, real delay, download speed (default: ping, delay)
  proxy outbounds link <tag> [--qr|--json|--config]
                                         its URL, QR code, backend JSON, or a client config for it (sudo)
  proxy pin [tag]                        always use this outbound (no tag: pick from a menu)
  proxy unpin                            let the configured selection pick again
  proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]
                                         show or override the routing mode
  proxy subs [list|update]               subscription caches; update refetches them
  proxy subs add <tag> <url>             add a subscription at runtime
  proxy subs rm <tag>                    remove a runtime subscription
  proxy subs link <tag> [--qr]           its URL (sudo)
  proxy config [--raw]                   client config to import elsewhere; --raw: as running (sudo)
  proxy tun [status|on|off]              global TUN mode
  proxy tproxy [status|on|off]           global TProxy mode
  proxy auto [list]                      what autoProxy routed, and via which exit (sudo, or userControl)
  proxy auto probe <domain>[/path] [--json] [--keep-going] [--exits a,b | --via tag]
                                         find an exit that reaches a domain
  proxy auto learn <domain>              probe now and route it if an exit works (sudo)
  proxy auto queue [count]               destinations waiting to be probed (sudo, or userControl)

  zapret [status|on|off]                 DPI bypass
  zapret auto [list]                     hosts zapret2 learned as blocked
  zapret auto add|forget|exclude <domain>
                                         pin, forget, or never learn a host (sudo)
  zapret auto unpin|include <domain>     undo add, or undo exclude (sudo)
  zapret auto clear                      forget learned hosts and strategies (sudo)
  zapret cutoff [status]                 networks this line cuts at 16 KB, and their names
  zapret cutoff probe                    probe this line again now (sudo)

  awg [list]                             AmneziaWG profiles and their state
  awg on <profile> | off [profile] | restart [profile]

  ssh [status|on|off]                    SSH SOCKS5 tunnel
  warp [status|on|off]                   WARP tunnel behind the warp outbound
  tg [status|on|off]                     Telegram WebSocket proxy

  apps [list]                            per-app routing profiles
  apps run <profile> -- <cmd> [args]     run a command through a profile

  inbounds [list]                        server inbounds
  inbounds link <tag> [user] [--qr|--json]
                                         client share link, or the client's outbound JSON
  inbounds link <tag> --server-json      the server's inbound JSON (sudo)
  inbounds sub [user] [--qr]             subscription users, or one user's URL
  inbounds stats [days] [--by user|inbound|outbound]
                                         traffic per user, listener or exit (sudo, or userControl)
  inbounds online                        who is connected now, and when the rest were last seen
```
<!-- proxy-ctl-help:end -->
