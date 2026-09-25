# Usage guides

Short guides for common setups. Each one has a minimal config, the commands you will use,
and links into the [options reference](../options/index.md) for the details.

| Guide | When to read it |
|---|---|
| [Connect through a proxy](./client-basics.md) | You have a proxy link or a subscription |
| [Route the whole machine](./system-wide.md) | Every app should use the proxy, not only those set to it |
| [Choose what goes through the proxy](./routing.md) | Only blocked sites through the proxy, or everything but some |
| [Route a single app](./per-app.md) | Only some apps should use the proxy |
| [Unblock sites without a server](./zapret.md) | YouTube, Discord or other sites are slowed or blocked by DPI |
| [Run your own server](./server.md) | You have a VPS and want to connect your devices to it |
| [Keep secrets out of the Nix store](./secrets.md) | Your config holds links, keys or passwords |
| [Control it day to day](./control.md) | Switching things without editing Nix or typing sudo |
| [Use an AmneziaWG config](./amneziawg.md) | You have an AmneziaWG `.conf` or an Amnezia `vpn://` export |
| [Chain proxies and add exits](./chains.md) | WARP, Tor, SSH, or reaching a server through another one |
| [Other Linux and Android](./other-hosts.md) | You are not on NixOS |
| [Get past mobile whitelists](./whitelist-bypass.md) | Mobile internet lets only whitelisted services through |
