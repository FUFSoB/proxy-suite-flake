# Example: several exits, picked per site

One host with four ways out: direct (with zapret2 for DPI), a VPS, WARP and an SSH server.
Each site goes to whichever works best for it, and autoProxy covers the sites nobody
listed. Everything runs in global TUN mode, so every app on the host follows these rules.

```nix
{ ... }:
let
  # Geosite "youtube" can miss the video and API hosts.
  youtubeDomains = [
    "googlevideo.com"
    "gvt1.com"
    "ytimg.com"
    "ggpht.com"
    "youtubei.googleapis.com"
  ];
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
      tun.enable = true;
      autostart = "tun";

      routing = {
        # Unlisted sites leave directly, where zapret2 unblocks what DPI blocks.
        default = "direct";
        # Russian sites are routed by the last rule below instead.
        directRu = false;

        # Checked in order; the first match wins.
        rules = [
          # Sites that reject both this host's and the VPS's networks.
          {
            outbound = "ssh-proxy";
            geosites = [ "pixiv" "twitter" ];
          }
          # Video throttled per connection by destination IP, which zapret cannot fix.
          # One exit for the whole session: video URLs are bound to the IP that asked.
          {
            outbound = "warp";
            domains = youtubeDomains;
            geosites = [ "youtube" ];
          }
          # A CDN that stalls through WARP but runs at full speed directly.
          {
            outbound = "direct";
            domains = [ "video-cdn.example" ];
          }
          # Russian services that refuse the VPS's foreign IP.
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
          # WARP registers through the proxy: its API is blocked directly.
          domains = [ "api.cloudflareclient.com" ];
        };
      };

      # For blocked sites no list names yet. YouTube is pinned to WARP above, so it
      # is kept out of the probes.
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

    # Tor through the proxy, since this network blocks Tor.
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

  # autoProxy probes in bursts (seconds of CPU, a few hundred MB). On a busy host, keep
  # it from competing with real work.
  systemd.services.proxy-suite-autoproxy.serviceConfig = {
    CPUWeight = 10;
    IOWeight = 10;
    Nice = 19;
    MemoryHigh = "200M";
  };
}
```

## Checking the result

```sh
proxy-ctl where youtube.com     # -> warp, by the rule for youtube
proxy-ctl where chatgpt.com     # -> proxy -> primary, by geosite openai
proxy-ctl proxy auto            # what autoProxy routed, and through which exit
proxy-ctl zapret auto           # what zapret2 learned
```

## With relay clients

On a [relay server](./relay-server.md) with `inbounds.routing.via = "proxy"`, clients follow
these rules too, with two exceptions. Russian sites are blocked for them (`blockRu`), and
sites on zapret's list go straight out, so this host's zapret handles them (`zapretDirect`).
Sites listed in `inbounds.routing.proxy` skip both exceptions and go to the rules above:

```nix no-check
services.proxy-suite.inbounds.routing = {
  via = "proxy";
  blockRu = false; # clients may reach Russian sites, through WARP by the rule above
  proxy = {
    domains = youtubeDomains; # on zapret's list, but WARP works better here
    geosites = [ "youtube" "category-ru" ];
    geoips = [ "ru" ];
  };
};
```

The same list applies to listeners with their own `via`, including `"direct"` ones.

## Notes

- Rules take effect in order. Put narrow ones (a single CDN) before broad ones (a whole
  country).
- Rules can name any outbound tag: yours, `warp`, `ssh-proxy`, `tor`, or an AmneziaWG
  outbound.
- `.onion` names go to Tor without a rule.
