# proxy-suite-flake

Declarative proxy stack for NixOS, on either side of the connection: as a client that routes this host's traffic through outbounds, as a server that accepts clients on its own inbounds, or both at once. Configure it in Nix, rebuild, and it runs as systemd services. It also runs on other Linux distributions (through system-manager or home-manager) and on Android (through Nix-on-Droid).

> [!IMPORTANT]
> This project is for study and research purposes only: learning how proxies, tunnels and traffic routing work. It comes with no warranty, and the authors are not responsible for how it is used.

> [!NOTE]
> This project is developed with AI assistance: much of the code and documentation was written with AI tools, then reviewed and tested on real-world setups.

Bundles [sing-box](https://github.com/SagerNet/sing-box), [XRay](https://github.com/XTLS/Xray-core), [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go), [zapret-discord-youtube](https://github.com/kartavkun/zapret-discord-youtube), [zapret2](https://github.com/bol-van/zapret2) and [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy); see their repositories for their own licenses and documentation.

Inspired by [Throne](https://github.com/throneproj/Throne) (formerly NekoRay), [3x-ui](https://github.com/MHSanaei/3x-ui) and other similar projects.

## Features

- Local SOCKS5/HTTP proxy on `127.0.0.1:1080`, backed by sing-box, XRay, or both
- Global TProxy or TUN mode, on demand or at boot
- A kill switch for the global tunnels (TUN, TProxy, AmneziaWG): nothing leaves outside them while they restart or after they fail
- Per-app routing: `proxy-ctl apps run <profile> -- <cmd>` through proxychains, a per-app TUN/TProxy, or zapret
- Outbounds from URLs, raw JSON or subscriptions; manual or latency-based selection; per-outbound routing
- vless (REALITY, TLS), vmess, trojan, shadowsocks, hysteria2, socks, http; TUIC, AnyTLS and NaïveProxy on sing-box, XHTTP/ECH on XRay
- Proxy chains: any outbound or a whole subscription can connect through another (`detour`)
- autoProxy: finds which exit reaches a blocked site and routes it there
- zapret DPI bypass, including zapret2, which learns blocked sites at runtime
- AmneziaWG 1.x–3.x tunnels from `.conf`, `vpn://`, or Nix
- Telegram MTProto WebSocket proxy and SSH SOCKS5 tunnel
- Cloudflare WARP from a `wgcf` profile, as an outbound or an AWG VPN profile
- Tor as an outbound, with `.onion` names routed to it automatically, bridges (obfs4, webtunnel, meek, snowflake), and an onion service in front of the server inbounds
- Server inbounds (XRay protocols, hysteria2, and multi-user AmneziaWG) with share links, QR codes, per-user subscriptions and traffic stats
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

  zapret.enable = true; # default is zapret-discord-youtube

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
      asOutbound = "interface"; # or "userspace" (no root), or "singBox" (plain WireGuard)
      configFile = "/run/secrets/de-amneziawg.conf";
    };
  };

  # Registers with wgcf on first start. The exit is Cloudflare, but geolocated to your own country.
  warp = {
    enable = true;
    asOutbound = "singBox"; # tag is "warp"; asOutbound = "interface" runs it as an AmneziaWG profile
    # asAmneziaWg = true; # or a global profile instead: proxy-ctl awg on warp
  };

  # An outbound tagged "tor" for routing.rules; .onion names always go to it.
  tor = {
    enable = true;
    asOutbound = true;
    # bridges.file = "/run/secrets/tor-bridges"; # one obfs4/webtunnel/snowflake line each
    # upstream = "proxy"; # reach Tor through the local proxy
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
Every group with on|off also takes toggle (on if stopped, off if running) and restart.
Secrets and changes need root, or the userControl group.

  status [--json]                        services and routing mode (--tray: deprecated key=value lines)
  restart                                restart active services
  logs [unit]                            follow logs (default: every proxy-suite unit)
  where <domain>                         how this host is routed right now

  proxy [status|on|off]                  local proxy backend
  proxy outbounds [list]                 outbounds, where each came from, and the pick
  proxy outbounds add [tag] <url|json|-> [--detour <tag>]
                                         add an outbound at runtime: a URL, or sing-box/XRay JSON (-: stdin),
                                         chained through another outbound with --detour; the tag first,
                                         or left out to name it after the link
  proxy outbounds chain <tag> <through-tag> [new tag]
                                         add a copy of an existing outbound that dials through
                                         another one; the original keeps dialing the way it did
  proxy outbounds rm <tag>               remove a runtime outbound
  proxy outbounds disable|enable <tag>   keep an outbound out of automatic use (selection, autoProxy, pins),
                                         or let it back in; declared ones too
  proxy outbounds test [tag...] [--ping] [--delay] [--download]
                                         TCP ping, real delay, download speed (default: ping, delay)
  proxy outbounds link <tag> [--qr|--json|--config]
                                         its URL, QR code, backend JSON, or a client config for it
  proxy pin [tag]                        always use this outbound (no tag: pick from a menu)
  proxy unpin                            let the configured selection pick again
  proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]
                                         show or override the routing mode
  proxy subs [list|update]               subscription caches; update refetches them
  proxy subs add [tag] <url>             add a subscription at runtime; no tag: named after its host
  proxy subs rm <tag>                    remove a runtime subscription
  proxy subs link <tag> [--qr]           its URL
  proxy rulesets [list|update]           routing rule sets: when each was fetched; update fetches them now
  proxy config [--raw]                   client config to import elsewhere; --raw: as running
  proxy tun [status|on|off]              global TUN mode
  proxy tproxy [status|on|off]           global TProxy mode
  proxy auto [list]                      what autoProxy routed, and via which exit
  proxy auto probe <domain>[/path] [--json] [--keep-going] [--exits a,b | --via tag]
                                         find an exit that reaches a domain
  proxy auto learn <domain>              probe now and route it if an exit works
  proxy auto forget <domain>             drop what was learned about it: direct until learned again
  proxy auto relearn <domain>            forget it, then probe the host it was learned from now
  proxy auto clear                       forget every learned route and verdict
  proxy auto queue [count]               destinations waiting to be probed

  zapret [status|on|off]                 DPI bypass
  zapret auto [list]                     hosts zapret2 learned as blocked
  zapret auto add|forget|exclude <domain>
                                         pin, forget, or never learn a host
  zapret auto unpin|include <domain>     undo add, or undo exclude
  zapret auto clear                      forget learned hosts and strategies
  zapret cutoff [status]                 networks this line cuts at 16 KB, and their names
  zapret cutoff probe                    probe this line again now

  awg [list]                             AmneziaWG profiles and their state
  awg on <profile> | off [profile] | toggle [profile] | restart [profile]

  killswitch [status|on|off]             reject traffic outside the global tunnel; up with
                                         TUN, TProxy or AWG, lifted only by off here or on them

  ssh [status|on|off]                    SSH SOCKS5 tunnel
  warp [status|on|off]                   WARP tunnel behind the warp outbound
  tor [status|on|off]                    Tor, behind the tor outbound and the onion service
  tor newnym                             new circuits for new connections
  tg [status|on|off]                     Telegram WebSocket proxy

  apps [list]                            per-app routing profiles
  apps run <profile> -- <cmd> [args]     run a command through a profile

  inbounds [list]                        server inbounds
  inbounds link <tag> [user] [--onion] [--qr|--json]
                                         client share link, or the client's outbound JSON;
                                         --onion: the one through the onion service
  inbounds link <tag> [user] --config [--qr]
                                         an AmneziaWG client's .conf, or its QR code
  inbounds link <tag> --server-json      the server's inbound JSON
  inbounds sub [user] [--qr]             subscription users, or one user's URL
  inbounds stats [days] [--by user|inbound|outbound]
                                         traffic per user, listener or exit
  inbounds online                        who is connected now, and when the rest were last seen
```
<!-- proxy-ctl-help:end -->
