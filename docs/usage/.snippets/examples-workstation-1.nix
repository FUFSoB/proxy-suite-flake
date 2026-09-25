{ config, pkgs, ... }:
let
  proxySuite = config.lib.proxy-suite;
in
{
  services.proxy-suite = {
    enable = true;

    proxy = {
      enable = true;
      # The server's subscription: every listener, each a separate outbound.
      subscriptions = [ { tag = "home"; urlFile = "/run/secrets/proxy-home-sub"; } ];
      # The fastest listener that gets through the current network.
      selection = "urltest";
      urlTest.url = "https://telegram.org"; # blocked here, so a pass means it works

      routing.default = "direct";
      autoProxy.enable = true;
      tun.enable = true; # when everything should go through: proxy-ctl proxy tun on
    };

    zapret = {
      enable = true;
      engine = "zapret2";
    };

    # The private VPN: `proxy-ctl awg on home`.
    amneziaWg = {
      enable = true;
      profiles.home.configFile = "/run/secrets/home-vpn.conf";
    };
    killSwitch.enable = true;

    perAppRouting = {
      enable = true;
      createDefaultProfiles = true;
      proxychains.enable = true;
      tun.enable = true;
    };

    gui.enable = true;
    userControl.enable = true;
  };

  users.users.me.extraGroups = [ "proxy-suite" ];

  environment.systemPackages = [
    # CLIs that only work through the proxy, whatever the routing says.
    (proxySuite.wrapEnv { protocol = "all"; } pkgs.codex)
    (proxySuite.wrapEnv { } pkgs.claude-code)
    # A browser for blocked sites, with its UDP (QUIC) too.
    (proxySuite.wrapPerApp { profile = "tun"; } pkgs.chromium)
  ];

  # Nix downloads through the proxy.
  systemd.services.nix-daemon.environment = proxySuite.envFor "http";
}