{ ... }:
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
          # Telegram apps dial their data centres by IP, so names alone do not catch them.
          geoips = [ "telegram" ];
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