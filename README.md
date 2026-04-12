# proxy-suite-flake

Declarative proxy stack for NixOS. One flake, one module, done.

Bundles [sing-box](https://github.com/SagerNet/sing-box), [zapret-discord-youtube](https://github.com/kartavkun/zapret-discord-youtube), and [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy). Built specifically for dealing with Roskomnadzor (RKN) and the usual Russian ISP nonsense.

The goal is to replace GUI clients like v2rayN and their ilk – you configure your proxies in Nix, rebuild, and they just work as systemd services.

---

## What it gives you

- **SOCKS5/HTTP proxy** on `127.0.0.1:1080` by default – always running, always available to apps
- **Transparent proxy (TProxy)** – redirect all system traffic through sing-box without configuring each app; start/stop on demand
- **TUN mode** – full tunnel via a virtual network interface; useful when TProxy doesn't cover something
- **Multiple outbounds** with automatic latency-based switching or manual selection
- **Per-outbound routing** – route specific domains, IPs, or geo sets to specific servers
- **Protocol support**: vless (Reality, TLS), vmess, trojan, shadowsocks, hysteria2, TUIC v5, socks5, socks4, http/https proxy
- **`proxy-ctl`** – control script for managing services, switching outbounds, and following logs
- **DPI bypass** via zapret – handles YouTube, Discord, and other sites that are blocked by packet inspection rather than IP
- **Telegram proxy** – MTProto WebSocket relay for sharing with others or for clients that don't support SOCKS

---

## Setup

Add to your flake inputs:

```nix
inputs.proxy-suite.url = "github:FUFSoB/proxy-suite-flake";
```

No need to add zapret separately – it comes along as a transitive input.

Add the module to your NixOS configuration:

```nix
imports = [ inputs.proxy-suite.nixosModules.default ];
```

---

## Basic configuration

```nix
services.proxy-suite = {
  enable = true;

  singBox = {
    outbounds = [
      {
        tag = "vps";
        # Runtime secret – not in the nix store.
        # Works with sops-nix, agenix, or anything that gives you a file path.
        urlFile = config.sops.secrets.proxy_url.path;
      }
    ];

    routing = {
      # Default: send RU geosite/geoip traffic direct.
      enableRuDirect = true;
      direct.domains = [ "reddit.com" ];
    };
    routing.proxy.geosites = [ "google" ];
  };

  zapret = {
    enable = true;
    # Default: mirror zapret domain lists into sing-box direct routing.
    syncDirectRouting = true;
    # Upstream zapret IP ranges are much broader, so keep them opt-in.
    syncDirectRoutingUpstreamIps = false;
    # User-defined ipsetAll/ipsetExclude still map into sing-box by default.
    syncDirectRoutingUserIps = true;
  };
};
```

After `nixos-rebuild switch`, you have a SOCKS proxy at `localhost:1080`.

If you intentionally want to expose it on another interface, set:

```nix
services.proxy-suite.singBox.listenAddress = "0.0.0.0";
```

To also start transparent proxying:

```bash
systemctl start proxy-suite-tproxy
```

TProxy installs its own nftables interception rules and can coexist with the NixOS firewall.

---

## Outbound formats

Each outbound needs exactly one of `urlFile`, `url`, or `json`.

### urlFile (recommended for real credentials)

```nix
outbounds = [{
  tag = "vps";
  urlFile = config.sops.secrets.my_vps_url.path;
}];
```

The URL is read at service start time. Never touches the nix store.

### url (convenient, not secret)

```nix
outbounds = [{
  tag = "vps";
  url = "hy2://yourpassword@your-server.com:443?sni=your-server.com";
}];
```

The URL string ends up in `/nix/store`. Fine for non-sensitive configs or testing.

### json (full sing-box outbound attrset)

```nix
outbounds = [{
  tag = "vps";
  json = {
    type = "vless";
    server = "your-server.com";
    server_port = 443;
    uuid = "your-uuid";
    tls = {
      enabled = true;
      server_name = "your-server.com";
      reality = {
        enabled = true;
        public_key = "your-public-key";
        short_id = "abc123";
      };
    };
  };
}];
```

Embedded at build time. Good when you generate the config programmatically.

---

## Multiple outbounds

```nix
singBox = {
  outbounds = [
    { tag = "de"; urlFile = config.sops.secrets.vps_de.path; }
    { tag = "nl"; urlFile = config.sops.secrets.vps_nl.path; }
  ];

  # Auto-select the fastest (checks every 3 minutes)
  selection = "urltest";

  # Or expose a Clash-compatible API for manual switching:
  # selection = "selector";
  # clashApiPort = 9090;  # then use a Clash controller UI
};
```

---

## Per-outbound routing

By default all proxied traffic goes to whatever the active outbound is (the selector, urltest winner, or single "first" outbound). You can override this per-outbound or with explicit rules to send specific traffic to a specific server.

Global direct routing also has two built-in behaviors:

- `singBox.routing.enableRuDirect = true` sends `geosite-category-ru` and `geoip-ru` direct by default.
- If `zapret.enable = true`, then `zapret.syncDirectRouting = true` mirrors zapret's upstream domain hostlists into sing-box direct rules. `zapret.syncDirectRoutingUpstreamIps = false` by default, so upstream zapret IP ranges are not mirrored unless you opt in, while `zapret.syncDirectRoutingUserIps = true` keeps user `ipsetAll`/`ipsetExclude` mirrored by default.

**Attached to an outbound:**

```nix
outbounds = [
  {
    tag = "de";
    urlFile = config.sops.secrets.vps_de.path;
    # Only meaningful with selection = "selector" or "urltest"
    routing.geosites = [ "netflix" ];
    routing.geoips   = [ "us" ];
    routing.domains  = [ "hulu.com" "peacocktv.com" ];
  }
  {
    tag = "nl";
    urlFile = config.sops.secrets.vps_nl.path;
    routing.domains = [ "discord.com" "discordapp.com" ];
  }
];
```

**Explicit rules list** – also works for `direct` and `block`, in any selection mode:

```nix
singBox.routing.rules = [
  # Block ad networks before anything else
  { outbound = "block";  geosites = [ "category-ads-all" ]; }
  # Internal traffic goes direct
  { outbound = "direct"; domains  = [ "corp.internal" ]; ips = [ "10.0.0.0/8" ]; }
  # Route US ips and Netflix to a specific server
  { outbound = "de";     geoips   = [ "us" ]; geosites = [ "netflix" ]; }
];
```

Rules from `outbound.routing` and `routing.rules` are evaluated **before** the global `routing.proxy` / `routing.direct` / `routing.block` lists, so they always take priority.

Within a single rule, `domains`, `ips`, `geosites`, and `geoips` are treated as independent matches. In practice that means one rule with multiple fields behaves like OR, not AND.

In `first` selection mode, per-outbound tags are resolved to `"proxy"` automatically (there's only one proxy outbound in that mode, so routing to a specific tag doesn't make sense).

---

## proxy-ctl

A control script is installed into your system packages automatically. Run it as root or with the right polkit permissions.

```
proxy-ctl status              show status of all proxy-suite services
proxy-ctl tproxy on|off       enable/disable TProxy transparent mode
proxy-ctl tun on|off          enable/disable TUN mode
proxy-ctl restart             restart proxy-suite-socks, and proxy-suite-tun if it is active
proxy-ctl logs [service]      follow logs (default: proxy-suite-socks)
proxy-ctl outbounds           list outbounds and current selection (needs Clash API)
proxy-ctl select <tag>        switch to a specific outbound (selector mode)
```

`outbounds` works with `selection = "selector"` or `"urltest"`. `select` requires `selection = "selector"` and talks to the Clash-compatible REST API embedded in sing-box.

---

## Protocol URL formats

| Protocol        | Example URL                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------ |
| VLESS + Reality | `vless://uuid@host:443?security=reality&pbk=KEY&fp=chrome&sni=SNI&sid=abc&flow=xtls-rprx-vision` |
| VLESS + TLS     | `vless://uuid@host:443?security=tls&sni=SNI&type=ws&path=/path`                                  |
| VMess           | `vmess://BASE64_JSON` (standard V2 link format)                                                  |
| Trojan          | `trojan://password@host:443?sni=SNI&fp=chrome`                                                   |
| Shadowsocks     | `ss://BASE64(method:password)@host:port` or `ss://method:password@host:port`                     |
| Hysteria2       | `hy2://password@host:443?sni=SNI`                                                                |
| TUIC v5         | `tuic://uuid:password@host:443?sni=SNI&congestion_control=bbr`                                   |
| SOCKS5          | `socks5://user:pass@host:1080` or `socks5://host:1080`                                           |
| SOCKS4          | `socks4://host:1080`                                                                             |
| HTTP proxy      | `http://user:pass@host:8080`                                                                     |
| HTTPS proxy     | `https://host:8080` (HTTP CONNECT over TLS)                                                      |

---

## Zapret

zapret handles DPI-based blocking by mangling packets at the netfilter level. It's separate from the proxy, but by default this module also mirrors zapret-covered domains into sing-box direct routing so the proxy does not fight zapret for the same traffic.

```nix
zapret = {
  enable = true;
  configName = "general(ALT)";
  syncDirectRouting = true;      # default: sync upstream domain lists
  syncDirectRoutingUpstreamIps = false;  # default: do not sync upstream IP ranges
  syncDirectRoutingUserIps = true; # default: do sync user ipsetAll/ipsetExclude

  # Extra domains beyond zapret's built-in list
  listGeneral = [ "pixiv.net" "pximg.net" ];
};
```

When `syncDirectRouting = true`, the module always reuses zapret's upstream `hostlists/list-general.txt` and `list-google.txt`, adds your `listGeneral`, and subtracts both upstream and user domain exclusions before generating sing-box direct rules. If `zapret.includeExtraUpstreamLists = true` (default), it also includes upstream `list-instagram.txt`, `list-soundcloud.txt`, and `list-twitter.txt` in both zapret handling and sing-box direct sync.

Custom `zapret.hostlistRules` domains also join this direct-domain sync by default. Set `enableDirectSync = false` on a custom hostlist if you want zapret to handle it but do not want sing-box direct-routing rules generated from it.

The generated zapret config also auto-activates upstream `list-instagram.txt`, `list-soundcloud.txt`, and `list-twitter.txt` when the selected upstream preset does not already reference them. They are attached using the active config's `general` rule family so those hostlists are actually handled by zapret instead of just existing on disk. Set `zapret.includeExtraUpstreamLists = false;` to opt out.

When `syncDirectRoutingUpstreamIps = true`, the module also mirrors zapret's upstream `ipset-all.txt`. This is disabled by default because the upstream IP set is intentionally broad.

When `syncDirectRoutingUserIps = true`, the module mirrors your `ipsetAll` and `ipsetExclude` values into sing-box direct routing even if upstream IP sync stays disabled. This is enabled by default.

If zapret corrupts traffic for some subnet (e.g. a VM behind a libvirt bridge):

```nix
zapret.cidrExemption = {
  enable = true;
  cidrs = [ "192.168.123.0/24" ];  # your VM's bridge network(s)
};
```

You can also define custom zapret hostlists with per-list rules:

```nix
zapret.hostlistRules = [
  {
    name = "googlevideo";
    domains = [ "googlevideo.com" "ggpht.com" ];
    preset = "google";
  }
  {
    name = "example";
    domains = [ "example.com" "example.de" ];
    nfqwsArgs = [
      "--filter-tcp=443 --dpi-desync=fake,multisplit"
    ];
  }
  {
    name = "social-extra";
    domains = [ "x.example" ];
    preset = "twitter";
    nfqwsArgs = [
      "--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6"
    ];
  }
];
```

Each entry generates `hostlists/list-<name>.txt`. `preset` clones the active zapret config's matching family rules for that hostlist, while `nfqwsArgs` appends custom NFQWS rule fragments. The module injects the generated `--hostlist=...`, standard zapret exclude files, and trailing `--new` automatically.

---

## Telegram proxy

Runs a WebSocket MTProto relay. Useful for sharing with others on mobile or for clients that need a dedicated Telegram proxy.

```nix
tgWsProxy = {
  enable = true;
  # Generate a secret: openssl rand -hex 16
  secretFile = config.sops.secrets.tg_ws_proxy_secret.path;
  port = 1076;
  host = "0.0.0.0"; # configurable bind address
};
```

`secretFile` is the recommended form because it keeps the secret out of the nix store. The legacy inline `secret = "...";` form still works for testing.

---

## Services

| Service                        | Auto-starts      | Description                                      |
| ------------------------------ | ---------------- | ------------------------------------------------ |
| `proxy-suite-socks`            | yes              | SOCKS5/HTTP proxy, always running                |
| `proxy-suite-tproxy`           | no               | TProxy transparent mode (start manually)         |
| `proxy-suite-tun`              | no               | TUN mode (start manually, conflicts with tproxy) |
| `proxy-suite-tg-ws-proxy`      | yes (if enabled) | Telegram proxy                                   |
| `proxy-suite-zapret-vm-exempt` | yes (if enabled) | VM subnet exemption                              |

TProxy and TUN are mutually exclusive. Start one, the other refuses to start.

---

## Secret management

This module doesn't care how you manage secrets. Anything that gives you a file path works:

**sops-nix:**

```nix
sops.secrets.proxy_url.sopsFile = ./secrets/proxy.yaml;

services.proxy-suite.singBox.outbounds = [{
  tag = "vps";
  urlFile = config.sops.secrets.proxy_url.path;
}];
```

**agenix:**

```nix
age.secrets.proxy_url.file = ./secrets/proxy_url.age;

services.proxy-suite.singBox.outbounds = [{
  tag = "vps";
  urlFile = config.age.secrets.proxy_url.path;
}];
```

**Plain file (not recommended but works):**

```nix
# Create /run/proxy-url with your URL, ensure it's readable by root
urlFile = "/run/proxy-url";
```

---

## System tray

Optional tray indicator for desktop environments. Shows proxy status and provides quick toggles.

```nix
services.proxy-suite = {
  tray = {
    enable = true;
    autostart = true;   # Install XDG autostart for all graphical users (default)
    pollInterval = 5;   # Status refresh interval in seconds
  };
};
```

Features:

- **Status icon**: `network-vpn` (active), `network-vpn-acquiring` (partial), `network-vpn-disconnected` (stopped)
- **Quick controls window**: Opens on secondary activation and on hosts that emit StatusNotifier `Activate` on left-click (including niri)
- **Enable/Disable Proxy**: Toggles `proxy-suite-socks`; disabling proxy also stops active TProxy/TUN first
- **Toggle TProxy/TUN**: Only shown if the service is enabled in your config
- **Close window**: Hides the floating controls window without exiting the tray
- **Restart services**: Restarts `proxy-suite-socks`, and `proxy-suite-tun` if it is active
- **Polkit authentication**: Prompts for password when toggling services

When enabled, the tray app is installed system-wide and autostarts for all graphical users via XDG autostart unless you set `tray.autostart = false;`.

The tray uses libayatana-appindicator and requires StatusNotifier/AppIndicator support. KDE generally works out of the box; GNOME may need shell support or an extension that exposes AppIndicators.

To enable TProxy/TUN toggles in the tray, you need to enable the services in your config:

```nix
services.proxy-suite.singBox = {
  tproxy.enable = true;  # Show TProxy toggle
  tun.enable = true;     # Show TUN toggle
};
```
