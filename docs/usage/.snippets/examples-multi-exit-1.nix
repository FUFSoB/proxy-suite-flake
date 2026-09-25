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
        # Russian sites are routed by the last rule below instead.
        directRu = false;

        # Checked in order; the first match wins.
        rules = [
          {
            outbound = "ssh-proxy";
            geosites = [ "pixiv" "twitter" ];
          }
          {
            outbound = "warp";
            geosites = [ "youtube" ];
          }
          # To mask your IP from Russian services
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
}