# Example: several exits, picked per site

A host in Russia with five ways out: direct (with zapret2 for DPI), a VPS, WARP, an SSH
server and Tor. Each site goes to whichever works best for it, and autoProxy covers the
sites nobody listed. On a [relay server](./relay-server.md), its clients get the same
choice, with a few differences shown below.

| Exit | Tag | Gets |
|---|---|---|
| This host, with zapret2 | `direct` | Everything not listed below |
| The VPS | `primary`, as the selected `proxy` | AI services, Telegram, Netflix, WARP's registration |
| The SSH server | `ssh-proxy` | pixiv, Twitter |
| WARP | `warp` | YouTube, Russian sites |
| Tor | `tor` | `.onion` names |
| Whichever reaches it first | set by autoProxy | Blocked sites no list names |

```nix
{ ... }:
let
  # Telegram apps dial their data centres by IP, so names alone do not catch them
  # (https://core.telegram.org/resources/cidr.txt).
  telegramIps = [
    "91.105.192.0/23"
    "91.108.4.0/22"
    "91.108.8.0/22"
    "91.108.12.0/22"
    "91.108.16.0/22"
    "91.108.20.0/22"
    "91.108.56.0/22"
    "149.154.160.0/20"
    "185.76.151.0/24"
    "2001:67c:4e8::/48"
    "2001:b28:f23c::/48"
    "2001:b28:f23d::/48"
    "2001:b28:f23f::/48"
    "2a0a:f280::/32"
  ];
in
{
  services.proxy-suite = {
    enable = true;

    proxy = {
      enable = true;
      outbounds = [ { tag = "primary"; urlFile = "/run/secrets/proxy-primary-url"; } ];

      routing = {
        # Unlisted sites leave directly, where zapret2 unblocks what DPI blocks.
        default = "direct";
        # Russian sites go to WARP by the last rule below instead.
        directRu = false;

        # Checked in order, before the lists; the first match wins.
        rules = [
          {
            outbound = "ssh-proxy";
            geosites = [ "pixiv" "twitter" ];
          }
          {
            outbound = "warp";
            geosites = [ "youtube" ];
          }
          # Russian services see WARP's address instead of this host's.
          {
            outbound = "warp";
            geosites = [ "category-ru" ];
            geoips = [ "ru" ];
          }
        ];

        # Through the selected outbound ("primary").
        proxy = {
          geosites = [ "openai" "anthropic" "telegram" "netflix" ];
          ips = telegramIps;
          # WARP registers through the proxy: its API is blocked directly in Russia.
          domains = [ "api.cloudflareclient.com" ];
        };
      };

      # For blocked sites no list names yet. YouTube already has its rule, so its video
      # hosts are not worth probing.
      autoProxy = {
        enable = true;
        exclude = [ "googlevideo.com" "gvt1.com" ];
      };
    };

    warp = {
      enable = true;
      asOutbound = "singBox";
    };

    sshProxy = {
      enable = true;
      asOutbound = true;
      server = {
        user = "me";
        host = "203.0.113.20";
        port = 2222;
      };
      identityFile = "/run/secrets/proxy-ssh-key";
      hostKeyFile = "/run/secrets/proxy-ssh-known-hosts";
    };

    # .onion names go to Tor without a rule. Tor is blocked here, so it connects
    # through the proxy.
    tor = {
      enable = true;
      asOutbound = true;
      upstream = "proxy";
    };

    zapret = {
      enable = true;
      engine = "zapret2";
    };
  };
}
```

## Checking the result

```sh
proxy-ctl where youtube.com     # -> warp, by the rule for youtube
proxy-ctl where pixiv.net       # -> ssh-proxy, by the first rule
proxy-ctl where chatgpt.com     # -> proxy -> primary, by geosite openai
proxy-ctl proxy auto            # what autoProxy routed, and through which exit
proxy-ctl zapret auto           # what zapret2 learned
```

## With relay clients

With `inbounds.routing.via = "proxy"`, relay clients go through the routing above. Two
checks come first by default: Russian sites are blocked for them (`blockRu`), and sites on
zapret's list leave directly, so this host's zapret handles them (`zapretDirect`). Sites in
`inbounds.routing.proxy` skip both and reach the rules above:

```nix no-check
services.proxy-suite.inbounds.routing = {
  via = "proxy";
  blockRu = false; # clients reach Russian sites too, through WARP by the rule above
  proxy = {
    # YouTube is on zapret's list, but WARP works better for it.
    geosites = [ "youtube" "category-ru" ];
    geoips = [ "ru" ];
  };
};
```

`inbounds.routing.proxy` covers listeners with their own `via` too, `"direct"` ones
included, so their YouTube and Russian sites also go through WARP.

## Notes

- Rules take effect in order. Put narrow ones (a single CDN) before broad ones (a whole
  country).
- Rules can name any outbound tag: yours, `warp`, `ssh-proxy`, `tor`, or an AmneziaWG
  outbound.
- Selection and autoProxy skip `tor`; it gets only `.onion` names and what rules send to it.
- See [Chain proxies and add exits](../chains.md) for each kind of exit on its own.
