{ config, pkgs, ... }:
let
  proxySuite = config.lib.proxy-suite;
in
{
  services.proxy-suite = {
    enable = true;
    proxy = {
      enable = true;
      outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    };
    perAppRouting = {
      enable = true;
      createDefaultProfiles = true;
      proxychains.enable = true;
      tun.enable = true;
    };
  };

  environment.systemPackages = [
    (proxySuite.wrapEnv { } pkgs.yt-dlp)
    (proxySuite.wrapProxychains { } pkgs.curl)
    (proxySuite.wrapPerApp { profile = "tun"; } pkgs.firefox)
  ];

  # A service: here nix-daemon, so downloads go through the proxy.
  systemd.services.nix-daemon.environment = proxySuite.envFor "http";
}