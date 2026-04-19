# proxy-suite-flake

Declarative proxy stack for NixOS.

Bundles [sing-box](https://github.com/SagerNet/sing-box), [zapret-discord-youtube](https://github.com/kartavkun/zapret-discord-youtube), and [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy). Built specifically for dealing with Roskomnadzor (RKN) and the usual Russian ISP nonsense.

The goal is to replace GUI clients like v2rayN and throne – you configure your proxies in Nix, rebuild, and they just work as systemd services.

---

## What it gives you

- **SOCKS5/HTTP proxy** on `127.0.0.1:1080` by default – always running, always available to apps
- **Transparent proxy (TProxy)** – redirect all system traffic through sing-box without configuring each app; start/stop on demand or autostart at boot
- **TUN mode** – full tunnel via a virtual network interface; useful when TProxy doesn't cover something, with optional boot-time autostart
- **Per-app wrapping** – run selected apps through the local proxy with `proxy-ctl wrap <profile> -- <command>`, without enabling global TProxy or TUN
- **Subscription URLs** – point at a v2rayN/Clash-format subscription endpoint; the module fetches, decodes, and imports all proxies automatically, with a periodic refresh timer
- **Multiple outbounds** with automatic latency-based switching or manual selection
- **Per-outbound routing** – route specific domains, IPs, or geo sets to specific servers
- **Protocol support**: vless (Reality, TLS), vmess, trojan, shadowsocks, hysteria2, TUIC v5, socks5, socks4, http/https proxy
- **`proxy-ctl`** – control script for managing services, switching outbounds, and following logs
- **DPI bypass** via zapret – handles YouTube, Discord, and other sites defined by the project
- **Telegram proxy** – running local MTProto WebSocket proxy using tg-ws-proxy

---

## Setup

Add to your flake inputs:

```nix
inputs.proxy-suite.url = "github:FUFSoB/proxy-suite-flake";
```

No need to add zapret separately – it comes along as a transitive input.

Add the module to your NixOS configuration:

```nix
modules = [ inputs.proxy-suite.nixosModules.default ];
```

Feature-complete starter config:

```nix
services.proxy-suite = {
  enable = true;

  singBox = {
    enable = true;
    port = 1080;

    # Individual proxy example
    outbounds = [
      {
        tag = "nl-vps";
        # Inline url is convenient for testing, but ends up in the Nix store.
        # For real use, prefer urlFile with a url file.
        url = "hy2://password@example.com:443?sni=example.com";
      }
    ];

    # Subscription example
    subscriptions = [
      {
        tag = "main-sub";
        # urlFile is also available to keep the URL out of the Nix store.
        url = "https://example.com/subscription-list.txt";
      }
    ];
    # Automatic switching of outbound based on latency.
    # Default is "first", which just uses the first one in the list.
    selection = "urltest";

    # Keep both available; autostart only one global tunnel.
    tproxy = {
      enable = true;
      autostart = false;
      perApp.enable = true;
    };
    tun = {
      enable = true;
      autostart = false;
      perApp.enable = true;
    };
  };

  zapret = {
    enable = true;
    perApp.enable = true;
  };

  perAppRouting = {
    enable = true;
    createDefaultProfiles = true;
    proxychains.enable = true;
  };

  tray = {
    enable = true;
    autostart = true;
  };

  tgWsProxy = {
    enable = true;
    port = 1443;
    # Inline secret is convenient for testing, but ends up in the Nix store.
    # For real use, prefer secretFile with a secret file.
    secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  };
};
```

---

## Options

To see options and documentation, check out the [options reference](./docs/options.md).

Options and generated README help are refreshed with `nix run .#update-docs`.

---

## `proxy-ctl help`

Generated from current `proxy-ctl help` output.

<!-- proxy-ctl-help:start -->
```text
Usage: proxy-ctl <command> [args]

Commands:
  help                      show this help message
  status [--tray]           show status of all proxy-suite services
  proxy on|off              enable/disable the sing-box proxy stack
  tproxy on|off             enable/disable TProxy transparent mode
  tun on|off                enable/disable TUN mode
  zapret on|off             enable/disable zapret-discord-youtube
  restart                   restart active global proxy-suite services
  logs [service]            follow service logs  (default: proxy-suite-socks)
  outbounds                 list outbounds and current selection
  select <tag>              switch to a specific outbound  (selector mode)
  apps                      list configured per-app routing profiles
  wrap <profile> -- <cmd>   run a command via a perAppRouting profile
  subscription list         show subscriptions, cache age, and proxy count
  subscription update       force-refresh all subscription caches and restart active sing-box services
```
<!-- proxy-ctl-help:end -->
