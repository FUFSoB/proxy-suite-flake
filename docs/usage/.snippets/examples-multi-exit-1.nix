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