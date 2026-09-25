# proxy-suite-flake

A declarative proxy stack for NixOS. Route this host's traffic through proxies, serve proxies to others, or both, all from one Nix config that runs as systemd services. Also runs on other Linux distributions (system-manager, home-manager) and on Android (Nix-on-Droid).

> [!IMPORTANT]
> For study and research only: learning how proxies, tunnels and traffic routing work. No warranty; the authors are not responsible for how it is used.

> [!NOTE]
> Much of the code and documentation was written with AI tools, then reviewed and tested on real setups.

Bundles [sing-box](https://github.com/SagerNet/sing-box), [XRay](https://github.com/XTLS/Xray-core), [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go), [zapret-discord-youtube](https://github.com/kartavkun/zapret-discord-youtube), [zapret2](https://github.com/bol-van/zapret2), [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) and [whitelist-bypass](https://github.com/kulikov0/whitelist-bypass); see their repositories for licenses and docs. Inspired by [Throne](https://github.com/throneproj/Throne) (formerly NekoRay), [3x-ui](https://github.com/MHSanaei/3x-ui) and similar projects.

## Features

- Local SOCKS5/HTTP proxy on `127.0.0.1:1080`, on sing-box, XRay, or both
- System-wide TUN or TProxy mode, on demand or at boot
- Kill switch: nothing leaks while a global tunnel restarts or after it fails
- Per-app routing: `proxy-ctl apps run <profile> -- <cmd>`, or packages wrapped to always use the proxy
- Outbounds from links, raw JSON or subscriptions, picked by hand or by latency
- vless (REALITY, TLS), vmess, trojan, shadowsocks, hysteria2, socks, http; TUIC, AnyTLS and NaïveProxy on sing-box; XHTTP and ECH on XRay
- Proxy chains: any outbound can connect through another
- autoProxy: finds an exit that reaches each blocked site and routes it there
- zapret DPI bypass, including zapret2, which learns blocked sites on its own
- AmneziaWG 1.x–3.x from `.conf`, `vpn://` or Nix
- Cloudflare WARP, Tor (with bridges and an onion service), an SSH tunnel and a Telegram proxy
- Tunnels through video-call servers, to get past mobile internet whitelists
- Server inbounds (XRay protocols, hysteria2, AmneziaWG) with share links, QR codes, subscriptions and traffic stats
- A desktop GUI with a tray icon, the `proxy-ctl` CLI and the `proxy-tui` terminal UI

## Setup

```nix
inputs.proxy-suite.url = "github:FUFSoB/proxy-suite-flake";
```

```nix
modules = [ inputs.proxy-suite.nixosModules.default ];
```

Other hosts take the same options through their own module:

| Module | For |
|---|---|
| `nixosModules.default` | NixOS |
| `nixosModules.server` | a single-user VPS: VLESS REALITY, TLS and WS inbounds, ACME and SSH |
| `systemManagerModules.default` | other distributions, via [system-manager](https://github.com/numtide/system-manager); firewall and kernel modules are left to the host |
| `homeManagerModules.default` | home-manager, without root: the local proxy, inbounds on ports from 1024, and anything else that needs no root |
| `nixOnDroidModules.default` | Android, via Nix-on-Droid: what home-manager gets, without the GUI |

A starter config:

```nix
services.proxy-suite = {
  enable = true;

  proxy = {
    enable = true;
    backend = "sing-box"; # or "xray", "hybrid"

    # `url` ends up in the Nix store; use `urlFile` for secrets.
    outbounds = [ { tag = "nl-vps"; url = "hy2://password@example.com:443?sni=example.com"; } ];
    subscriptions = [ { tag = "main-sub"; urlFile = "/run/secrets/sub-url"; } ];
    selection = "urltest"; # pick the fastest; default "first"

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

  # Only one global tunnel (AWG, TUN or TProxy) runs at a time.
  amneziaWg = {
    enable = true;
    profiles.home.configFile = "/run/secrets/home-amneziawg.conf";
    profiles.work.vpnFile = "/run/secrets/work-amnezia.vpn";
    # Or use a profile as an outbound, tagged "de":
    profiles.de = {
      asOutbound = "interface"; # or "userspace" (no root), "singBox" (plain WireGuard)
      configFile = "/run/secrets/de-amneziawg.conf";
    };
  };

  # Registers a WARP device on first start.
  warp = {
    enable = true;
    asOutbound = "singBox"; # outbound tagged "warp"
    # asAmneziaWg = true;   # or a global profile: proxy-ctl awg on warp
  };

  # Outbound tagged "tor"; .onion names always go there.
  tor = {
    enable = true;
    asOutbound = true;
    # bridges.file = "/run/secrets/tor-bridges";
    # upstream = "proxy"; # reach Tor through the proxy
  };

  tgWsProxy = {
    enable = true;
    secretFile = "/run/secrets/tg-ws-proxy-secret";
  };

  # Tunnel through a video call. A creator runs on a free server and logs the call link;
  # the joiner here is an outbound tagged "wl".
  whitelistBypass = {
    enable = true;
    joiners.wl = { platform = "wbstream"; linkFile = "/run/secrets/wb-link"; };
    # creators.phone = { platform = "wbstream"; cookiesFile = "/run/secrets/wb-cookies.json"; };
  };

  gui.enable = true;
};
```

---

## Docs

- [Usage guides](./docs/usage/index.md): common setups, step by step, and complete examples.
- [Options reference](./docs/options/index.md): every option. Regenerate it and the help below with `nix run .#update-docs`.

## `proxy-ctl help`

<!-- proxy-ctl-help:start -->
```text
Usage: proxy-ctl <group> [verb] [args]
A group alone shows its status or list.
Groups with on|off also take toggle and restart.
Changes and secrets need root or the userControl group.

  status [--json]                        services and routing mode (--tray: deprecated)
  restart                                restart running services
  logs [unit]                            follow logs (default: all proxy-suite units)
  where <domain>                         how a domain is routed right now

  proxy [status|on|off]                  local proxy
  proxy outbounds [list]                 outbounds, their source, and the current pick
  proxy outbounds add [tag] <url|json|-> [--detour <tag>]
                                         add an outbound from a link or JSON (-: stdin);
                                         --detour: connect through another outbound
  proxy outbounds chain <tag> <through-tag> [new tag]
                                         add a copy of an outbound that connects through another
  proxy outbounds rm <tag>               remove a runtime outbound
  proxy outbounds disable|enable <tag>   exclude from automatic use (selection, autoProxy), or undo
  proxy outbounds test [tag...] [--ping] [--delay] [--download]
                                         test ping, delay, download speed (default: ping, delay)
  proxy outbounds link <tag> [--qr|--json|--config]
                                         its link, QR code, JSON, or client config
  proxy pin [tag]                        always use this outbound (no tag: pick from a menu)
  proxy unpin                            go back to automatic selection
  proxy mode [default|whitelist|blacklist|all-proxy|all-bypass]
                                         show or override the routing mode
  proxy subs [list|update]               subscriptions; update refetches them
  proxy subs add [tag] <url>             add a subscription (no tag: named after its host)
  proxy subs rm <tag>                    remove a runtime subscription
  proxy subs link <tag> [--qr]           its URL
  proxy rulesets [list|update]           rule sets and when they were fetched; update refetches
  proxy config [--raw]                   client config to use elsewhere; --raw: as running
  proxy tun [status|on|off]              global TUN mode
  proxy tproxy [status|on|off]           global TProxy mode
  proxy auto [list]                      what autoProxy routed, and through which exit
  proxy auto probe <domain>[/path] [--json] [--keep-going] [--exits a,b | --via tag]
                                         find an exit that reaches a domain
  proxy auto learn <domain>              probe now, and route it if an exit works
  proxy auto forget <domain>             forget it (direct until learned again)
  proxy auto relearn <domain>            forget it and probe again now
  proxy auto clear                       forget everything learned
  proxy auto queue [count]               destinations waiting to be probed

  zapret [status|on|off]                 DPI bypass
  zapret auto [list]                     sites zapret2 learned as blocked
  zapret auto add|forget|exclude <domain>
                                         pin, forget, or never learn a site
  zapret auto unpin|include <domain>     undo add or exclude
  zapret auto clear                      forget learned sites and strategies
  zapret cutoff [status]                 networks cut off at 16 KB, and names that pass
  zapret cutoff probe                    probe again now

  awg [list]                             AmneziaWG profiles
  awg on <profile> | off [profile] | toggle [profile] | restart [profile]

  killswitch [status|on|off]             block traffic outside the global tunnel;
                                         stays on until turned off here or with the tunnel

  ssh [status|on|off]                    SSH tunnel
  warp [status|on|off]                   WARP tunnel
  tor [status|on|off]                    Tor
  tor newnym                             new circuits for new connections
  tg [status|on|off]                     Telegram proxy
  wl [list]                              whitelist-bypass creators and joiners
  wl link <creator> [--qr]               the call link for its joiner
  wl auth <creator> [file|-]             replace its login: cookies, or prompt (DION, Bitrix)
  wl join <joiner> <link|->              set the call to join
  wl new <creator>                       start a new call
  wl on|off|toggle|restart [name]        one creator or joiner, or all

  apps [list]                            per-app routing profiles
  apps run <profile> -- <cmd> [args]     run a command through a profile

  inbounds [list]                        server inbounds
  inbounds link <tag> [user] [--onion] [--qr|--json]
                                         share link or client JSON; --onion: via the onion service
  inbounds link <tag> [user] --config [--qr]
                                         AmneziaWG client .conf or its QR code
  inbounds link <tag> --server-json      the server's inbound JSON
  inbounds sub [user] [--qr]             subscription users, or one user's URL
  inbounds stats [days] [--by user|inbound|outbound]
                                         traffic by user, listener or exit
  inbounds online                        who is online, and when others were last seen
```
<!-- proxy-ctl-help:end -->
