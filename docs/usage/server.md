# Run your own server

Accept proxy clients on a VPS, and hand out share links, QR codes and subscriptions for
them. The listeners run on XRay, and AmneziaWG listeners run on AmneziaWG.

## A fresh VPS: the installer

If your provider lets you boot a custom ISO, build the installer:

```sh
nix build github:FUFSoB/proxy-suite-flake#installer-iso
```

Boot the VPS from it. The console installer asks for the public IP, users, an optional
domain and the disk to erase, then installs NixOS with `nixosModules.server`: VLESS
REALITY, TLS and WS listeners, ACME certificates and SSH. After the reboot, log in and run:

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
    listeners = {
      vless-reality = {
        type = "vless";
        port = 443;
        flow = "xtls-rprx-vision";
        users = [
          { name = "phone"; uuidFile = "/run/secrets/uuid-phone"; }
          { name = "laptop"; uuidFile = "/run/secrets/uuid-laptop"; }
        ];
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
        users = [ { name = "phone"; } ];
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
services.nginx.virtualHosts."vpn.example.com".locations."/sub/".alias =
  "/run/proxy-suite-inbounds/subscriptions/";
```

Then `proxy-ctl inbounds sub phone --qr` prints that user's subscription.

## Good to know

- Clients cannot reach this host's LAN or Russian sites by default
  (`inbounds.routing.blockPrivate`, `blockRu`).
- With `routing.via = "proxy"` (the default), client traffic goes through this host's own
  proxy instead, following its routing. That needs `proxy.enable`. A listener can also exit
  through one outbound with `via = "<tag>"`.
- For clients that cannot reach the server at all, `tor.onionService` serves the
  listeners over Tor too.

## See also

- [`inbounds.listeners`](../options/inbounds.md#services-proxy-suite-inbounds-listeners)
- [`inbounds.routing.via`](../options/inbounds.md#services-proxy-suite-inbounds-routing-via)
- [`inbounds.subscriptions`](../options/inbounds.md#services-proxy-suite-inbounds-subscriptions-enable)
- [`tor.onionService`](../options/tor.md#services-proxy-suite-tor-onionservice-enable)
