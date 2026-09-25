# Wrap programs with the proxy

Build the proxy into a package, so a program uses it wherever and however it is started,
with no setup in the program. On NixOS and home-manager, the module provides the pieces as
`config.lib.proxy-suite`, built from your listener and per-app routing settings.

| Helper | How the program is routed | Covers |
|---|---|---|
| `wrapEnv` | Proxy variables (`https_proxy`, `all_proxy`, …) | Programs that read them: most CLIs, Go, Python, curl, git |
| `wrapProxychains` | proxychains, for programs that ignore the variables | TCP; not static or Go programs |
| `wrapPerApp` | A [per-app routing](./per-app.md) profile, via `proxy-ctl apps run` | Everything, TCP and UDP (`tun` profile) |
| `env`, `envFor` | Just the variables, for services and shells | Whatever reads them |

## On NixOS

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
    (proxySuite.wrapProxychains { } pkgs.telegram-desktop)
    (proxySuite.wrapPerApp { profile = "tun"; } pkgs.firefox)
  ];

  # A service: here nix-daemon, so downloads go through the proxy.
  systemd.services.nix-daemon.environment = proxySuite.envFor "http";
}
```

The wrapped programs keep their names, and the package's `.desktop` files start them.

## From home-manager

A home-manager config inside NixOS reads the system's helpers through `osConfig`:

```nix no-check
{ osConfig, pkgs, ... }:
let
  proxySuite = osConfig.lib.proxy-suite;
in
{
  home.packages = [
    (proxySuite.wrapEnv { protocol = "all"; } pkgs.codex)
    (proxySuite.wrapEnv { } pkgs.claude-code)
  ];
}
```

When proxy-suite itself runs under home-manager, use `config.lib.proxy-suite`.

## Other hosts, or another host's proxy

system-manager and Nix-on-Droid have no `config.lib`. There, or for a proxy that this config
does not run, the flake builds the URLs, the variables and `wrapEnv` from an address:

```nix no-check
proxySuite = inputs.proxy-suite.lib.proxyHelpers {
  inherit pkgs;
  address = "192.168.1.10"; # default "127.0.0.1"
  port = 1080;              # default 1080
  # username and password, if the proxy asks for them
};
```

## Reference

- `urls.http`, `urls.socks`: the proxy's URLs. A listener on `0.0.0.0` or `::` is reached on
  loopback.
- `env`: every proxy variable (`http_proxy`, `https_proxy`, `all_proxy`, their upper-case
  forms, and `no_proxy`). `envFor "http"` or `envFor "socks"` gives one kind only.
- `wrapEnv { protocol ? "http"; programs ? null; } package`: the package, with its programs
  run with the variables of `protocol`.
- `wrapProxychains { programs ? null; } package`: its programs run under proxychains. Needs
  `perAppRouting.proxychains.enable`.
- `wrapPerApp { profile; programs ? null; } package`: its programs run with
  `proxy-ctl apps run <profile>`. Needs the profile in `perAppRouting`.

`programs = [ "…" ]` wraps only the named programs of the package; the rest stay as they
are. By default, every program in its `bin/` is wrapped.

## Which variables

`wrapEnv` sets one kind and unsets the other, so proxy variables in your shell cannot
send the program somewhere else:

- `protocol = "http"` (the default): `http_proxy` and `https_proxy`, which nearly
  everything reads.
- `protocol = "socks"`: `all_proxy` with `socks5h://`, so the proxy resolves names. For
  programs that read only that one, or handle SOCKS better.
- `protocol = "all"`: both, when you are not sure which one a program reads.

Local addresses (`localhost`, `127.0.0.0/8`, `::1`) always stay direct, through `no_proxy`.

## Good to know

- The variables need `proxy.enable`. They cannot hold a password from
  `listener.auth.passwordFile`. Use `wrapProxychains` then, since it reads the password
  at run time.
- `wrapPerApp` with a `tun`, `tproxy` or `zapret` profile has the same needs as
  `proxy-ctl apps run`: an admin password, or the `perApp` scope in `userControl`.
- A helper that cannot work stops the build and says why, for example when a profile does
  not exist.
- A wrapper does not inherit the package's license, so wrapping an unfree package needs
  nothing beyond what the package itself needs.
- For every program on the machine, see [Route the whole machine](./system-wide.md)
  instead.

## See also

- [Route a single app](./per-app.md): the profiles `wrapPerApp` uses
- [`perAppRouting.profiles`](../options/perAppRouting.md#services-proxy-suite-perapprouting-profiles)
