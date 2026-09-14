# proxy-suite-flake

Declarative proxy stack for NixOS, built for dealing with Roskomnadzor and the usual Russian ISP nonsense. Configure it in Nix, rebuild, and it runs as systemd services.

Bundles [sing-box](https://github.com/SagerNet/sing-box), [XRay](https://github.com/XTLS/Xray-core), [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go), [zapret-discord-youtube](https://github.com/kartavkun/zapret-discord-youtube), [zapret2](https://github.com/bol-van/zapret2) and [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy).

## Features

- Local SOCKS5/HTTP proxy on `127.0.0.1:1080`, backed by sing-box, XRay, or both
- Global TProxy or TUN mode, on demand or at boot
- Per-app routing: `proxy-ctl apps run <profile> -- <cmd>` through proxychains, a per-app TUN/TProxy, or zapret
- Outbounds from URLs, raw JSON or subscriptions; manual or latency-based selection; per-outbound routing
- vless (REALITY, TLS), vmess, trojan, shadowsocks, hysteria2, socks, http; TUIC on sing-box, XHTTP/ECH on XRay
- autoProxy: finds which exit reaches a blocked site and routes it there
- zapret DPI bypass, including zapret2, which learns blocked sites at runtime
- AmneziaWG 1.x–3.x tunnels from `.conf`, `vpn://`, or Nix
- Telegram MTProto WebSocket proxy and SSH SOCKS5 tunnel
- Cloudflare WARP from a `wgcf` profile, as an outbound or an AWG VPN profile
- Server inbounds with share links, QR codes, per-user subscriptions and traffic stats
- A tray indicator and the `proxy-ctl` CLI

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
  };

  # Registers with wgcf on first start. The exit is Cloudflare, but geolocated to your own country.
  warp = {
    enable = true;
    asOutbound = true; # tag "warp"
    asAmneziaWg = true; # proxy-ctl awg on warp
  };

  tgWsProxy = {
    enable = true;
    secretFile = "/run/secrets/tg-ws-proxy-secret";
  };

  tray.enable = true;
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

  status [--tray]                        services and routing mode
  restart                                restart active services
  logs [unit]                            follow logs (default: every proxy-suite unit)
  where <domain>                         how this host is routed right now

  proxy [status|on|off]                  local proxy backend
  proxy outbounds [list]                 outbounds, where each came from, and the pick
  proxy outbounds add <tag> <url>        add an outbound at runtime
  proxy outbounds rm <tag>               remove a runtime outbound
  proxy select [<tag>|auto]              pin the priority outbound (no tag: pick from a menu)
  proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]
                                         show or override the routing mode
  proxy subs [list|update]               subscription caches; update refetches them
  proxy subs add <tag> <url>             add a subscription at runtime
  proxy subs rm <tag>                    remove a runtime subscription
  proxy tun [status|on|off]              global TUN mode
  proxy tproxy [status|on|off]           global TProxy mode
  proxy auto [list]                      what autoProxy routed, and via which exit (sudo, or userControl)
  proxy auto probe <domain>[/path] [--json] [--exits a,b | --via tag]
                                         find an exit that reaches a domain
  proxy auto learn <domain>              probe now and route it if an exit works (sudo)
  proxy auto queue [count]               destinations waiting to be probed (sudo, or userControl)

  zapret [status|on|off]                 DPI bypass
  zapret auto [list]                     hosts zapret2 learned as blocked
  zapret auto add|forget|exclude <domain>
                                         pin, forget, or never learn a host (sudo)
  zapret auto clear                      forget learned hosts and strategies (sudo)
  zapret cutoff [status]                 networks this line cuts at 16 KB, and their names
  zapret cutoff probe                    probe this line again now (sudo)

  awg [list]                             AmneziaWG profiles and their state
  awg on <profile> | off [profile] | restart [profile]

  ssh [status|on|off]                    SSH SOCKS5 tunnel

  apps [list]                            per-app routing profiles
  apps run <profile> -- <cmd> [args]     run a command through a profile

  inbounds [list]                        server inbounds
  inbounds link <tag> [user] [--qr]      client share link
  inbounds sub [user] [--qr]             subscription users, or one user's URL
  inbounds stats [days]                  traffic per user (sudo, or userControl)
```
<!-- proxy-ctl-help:end -->
