# Example: a workstation using your own server

The desktop side of the [relay server](./relay-server.md) and the
[private VPN](./private-vpn.md). Most apps go direct, with zapret for DPI. Blocked sites go
through the server. Some programs always use the proxy, and the private VPN is one
command away.

```nix
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
```

## Day to day

```sh
proxy-ctl status                 # what runs, and which outbound is picked
proxy-ctl proxy outbounds test   # which listeners get through right now
proxy-ctl where some-site.com    # direct, zapret or proxy, and why
proxy-ctl proxy tun on           # everything through the server for a while
proxy-ctl awg on home            # or through the private VPN (stops TUN)
```

The tray app shows the same, and switches with a click.

## Notes

- `wrapEnv` sets the proxy variables for one program only, so the rest of the system keeps
  its direct routing. `protocol = "all"` sets both kinds, for a program whose choice you
  do not know.
- The kill switch guards whichever global tunnel is on (TUN or the VPN), and does nothing
  while both are off.
- Per-app `tun` profiles refuse to start while global TUN is on. Everything already goes
  through the proxy then.
- See [Wrap programs with the proxy](../wrap-apps.md) for the helpers, and
  [Keep secrets out of the Nix store](../secrets.md) for the files under `/run/secrets`.
