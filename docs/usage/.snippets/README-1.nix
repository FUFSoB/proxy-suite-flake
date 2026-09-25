{ config, lib, pkgs, ... }:
{
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
    creators.phone = { platform = "wbstream"; cookiesFile = "/run/secrets/wb-cookies.json"; };
    # joiners.wl = { platform = "wbstream"; linkFile = "/run/secrets/wb-link"; };
  };

  gui.enable = true;
};
}
